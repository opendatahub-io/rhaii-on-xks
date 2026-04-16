#!/usr/bin/env bash
#
# patch-images.sh - Patch all image references for mirrored/disconnected registries
#
# This script patches all deployed resources to use images from a customer's
# mirror registry instead of the default registries (registry.redhat.io, ghcr.io).
#
# Usage:
#   ./scripts/patch-images.sh <TARGET_REGISTRY> [--pull-secret <SECRET_NAME>]
#
# Examples:
#   ./scripts/patch-images.sh jfrog.customer.com/redhat-mirror
#   ./scripts/patch-images.sh jfrog.customer.com --pull-secret jfrog-pull-secret
#
# Prerequisites:
#   - kubectl configured and authenticated to the cluster
#   - All components deployed via 'make deploy-all'
#   - Images already mirrored via './scripts/mirror-images.sh'
#   - jq installed
#
# What gets patched:
#   1. cert-manager-operator: deployment image + RELATED_IMAGE_* env vars
#   2. sail-operator: deployment image + version annotations
#   3. lws-operator: deployment image + RELATED_IMAGE_OPERAND_IMAGE env var
#   4. KServe: kserve-parameters ConfigMap + inferenceservice-config ConfigMap + deployments
#   5. Pull secrets: patches ServiceAccounts to use customer's pull secret

set -euo pipefail

TARGET_REGISTRY="${1:?Usage: $0 <TARGET_REGISTRY> [--pull-secret <SECRET_NAME>]}"
shift

# Parse optional flags
PULL_SECRET_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull-secret)
      PULL_SECRET_NAME="${2:?--pull-secret requires a value}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Source registries to replace
SOURCE_REGISTRIES=(
  "registry.redhat.io"
  "ghcr.io/opendatahub-io/rhaii-on-xks"
  "ghcr.io/opendatahub-io"
)

# Namespaces
NS_CERT_MANAGER_OPERATOR="cert-manager-operator"
NS_CERT_MANAGER="cert-manager"
NS_ISTIO="istio-system"
NS_LWS="openshift-lws-operator"
NS_KSERVE="opendatahub"

echo "============================================"
echo "  RHOAI-on-xKS Image Patching"
echo "============================================"
echo "Target registry: ${TARGET_REGISTRY}"
if [[ -n "${PULL_SECRET_NAME}" ]]; then
  echo "Pull secret:     ${PULL_SECRET_NAME}"
fi
echo ""

# =============================================================================
# Helper: replace all source registries in a string
# =============================================================================
replace_registries() {
  local input="$1"
  local result="${input}"
  for src in "${SOURCE_REGISTRIES[@]}"; do
    result="${result//${src}/${TARGET_REGISTRY}}"
  done
  echo "${result}"
}

# =============================================================================
# Helper: patch deployment container image
# =============================================================================
patch_deployment_image() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"

  local current_image
  if ! kubectl get deployment "${deployment}" -n "${namespace}" --ignore-not-found -o name >/dev/null; then
    echo "  [SKIP] ${namespace}/${deployment}: not found"
    return 0
  fi

  current_image=$(kubectl get deployment "${deployment}" -n "${namespace}" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name==\"${container}\")].image}")

  if [[ -z "${current_image}" ]]; then
    echo "  [SKIP] ${namespace}/${deployment}/${container}: container not found"
    return 0
  fi

  local new_image
  new_image=$(replace_registries "${current_image}")

  if [[ "${current_image}" != "${new_image}" ]]; then
    kubectl set image "deployment/${deployment}" "${container}=${new_image}" -n "${namespace}"
    echo "  [OK] ${namespace}/${deployment}/${container}"
  else
    echo "  [SKIP] ${namespace}/${deployment}/${container}: already using target registry"
  fi
}

# =============================================================================
# Helper: patch deployment env var
# =============================================================================
patch_deployment_env() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local env_name="$4"

  local current_value
  if ! kubectl get deployment "${deployment}" -n "${namespace}" --ignore-not-found -o name >/dev/null; then
    return 0
  fi

  current_value=$(kubectl get deployment "${deployment}" -n "${namespace}" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name==\"${container}\")].env[?(@.name==\"${env_name}\")].value}")

  if [[ -z "${current_value}" ]]; then
    return 0
  fi

  local new_value
  new_value=$(replace_registries "${current_value}")

  if [[ "${current_value}" != "${new_value}" ]]; then
    kubectl set env "deployment/${deployment}" -n "${namespace}" -c "${container}" "${env_name}=${new_value}"
    echo "  [OK] ${namespace}/${deployment} env ${env_name}"
  fi
}

# =============================================================================
# Helper: patch deployment annotations
# =============================================================================
patch_deployment_annotations() {
  local namespace="$1"
  local deployment="$2"

  local deploy_json
  if ! kubectl get deployment "${deployment}" -n "${namespace}" --ignore-not-found -o name >/dev/null; then
    return 0
  fi
  deploy_json=$(kubectl get deployment "${deployment}" -n "${namespace}" -o json)

  local annotations
  annotations=$(echo "${deploy_json}" | jq '.spec.template.metadata.annotations // {}')

  if [[ -z "${annotations}" || "${annotations}" == "{}" || "${annotations}" == "null" ]]; then
    return 0
  fi

  # Get all annotation keys that contain image references
  local keys
  keys=$(echo "${annotations}" | jq -r 'to_entries[] | select(.key | startswith("images.")) | .key')

  for key in ${keys}; do
    local current_value
    current_value=$(echo "${annotations}" | jq -r --arg k "${key}" '.[$k]')
    local new_value
    new_value=$(replace_registries "${current_value}")

    if [[ "${current_value}" != "${new_value}" ]]; then
      # RFC 6901 JSON Pointer escaping: ~ → ~0 first, then / → ~1
      local escaped_key="${key//\~/~0}"
      escaped_key="${escaped_key//\//~1}"

      kubectl patch deployment "${deployment}" -n "${namespace}" \
        --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/${escaped_key}\",\"value\":\"${new_value}\"}]" 2>/dev/null
      echo "  [OK] ${namespace}/${deployment} annotation ${key}"
    fi
  done
}

# =============================================================================
# Helper: patch ConfigMap values
# =============================================================================
patch_configmap() {
  local namespace="$1"
  local configmap="$2"

  local cm_data
  if ! kubectl get configmap "${configmap}" -n "${namespace}" --ignore-not-found -o name | grep -q .; then
    echo "  [SKIP] ${namespace}/${configmap}: not found"
    return 0
  fi
  cm_data=$(kubectl get configmap "${configmap}" -n "${namespace}" -o json)

  local patched=false
  local new_data="${cm_data}"

  for src in "${SOURCE_REGISTRIES[@]}"; do
    if echo "${new_data}" | grep -F -q "${src}"; then
      # Escape regex metacharacters for jq gsub (which uses regex)
      local escaped_src
      escaped_src=$(printf '%s' "${src}" | sed 's/[.[\]*+?^${}()|\\]/\\&/g')
      new_data=$(echo "${new_data}" | jq --arg src "${escaped_src}" --arg tgt "${TARGET_REGISTRY}" '
        .data |= with_entries(.value |= gsub($src; $tgt))
      ')
      patched=true
    fi
  done

  if ${patched}; then
    echo "${new_data}" | kubectl apply -f - 2>/dev/null
    echo "  [OK] ${namespace}/${configmap}"
  else
    echo "  [SKIP] ${namespace}/${configmap}: no matching registries"
  fi
}

# =============================================================================
# Helper: patch ServiceAccount pull secrets
# =============================================================================
patch_pull_secret() {
  local namespace="$1"
  local sa="$2"

  if [[ -z "${PULL_SECRET_NAME}" ]]; then
    return 0
  fi

  kubectl patch serviceaccount "${sa}" -n "${namespace}" \
    -p "{\"imagePullSecrets\": [{\"name\": \"${PULL_SECRET_NAME}\"}]}" 2>/dev/null && \
    echo "  [OK] ${namespace}/sa/${sa} pull secret → ${PULL_SECRET_NAME}" || \
    echo "  [SKIP] ${namespace}/sa/${sa}: not found"
}

# =============================================================================
# 1. CERT-MANAGER-OPERATOR
# =============================================================================
echo "[1/5] Patching cert-manager-operator..."

patch_deployment_image "${NS_CERT_MANAGER_OPERATOR}" "cert-manager-operator-controller-manager" "cert-manager-operator"

for env_name in RELATED_IMAGE_CERT_MANAGER_WEBHOOK RELATED_IMAGE_CERT_MANAGER_CA_INJECTOR \
  RELATED_IMAGE_CERT_MANAGER_CONTROLLER RELATED_IMAGE_CERT_MANAGER_ACMESOLVER RELATED_IMAGE_CERT_MANAGER_ISTIOCSR; do
  patch_deployment_env "${NS_CERT_MANAGER_OPERATOR}" "cert-manager-operator-controller-manager" "cert-manager-operator" "${env_name}"
done

patch_pull_secret "${NS_CERT_MANAGER_OPERATOR}" "cert-manager-operator-controller-manager"
patch_pull_secret "${NS_CERT_MANAGER}" "cert-manager"
patch_pull_secret "${NS_CERT_MANAGER}" "cert-manager-cainjector"
patch_pull_secret "${NS_CERT_MANAGER}" "cert-manager-webhook"

echo ""

# =============================================================================
# 2. SAIL-OPERATOR
# =============================================================================
echo "[2/5] Patching sail-operator..."

patch_deployment_image "${NS_ISTIO}" "servicemesh-operator3" "sail-operator"
patch_deployment_annotations "${NS_ISTIO}" "servicemesh-operator3"

patch_pull_secret "${NS_ISTIO}" "servicemesh-operator3"
patch_pull_secret "${NS_ISTIO}" "istiod"

echo ""

# =============================================================================
# 3. LWS-OPERATOR
# =============================================================================
echo "[3/5] Patching lws-operator..."

patch_deployment_image "${NS_LWS}" "openshift-lws-operator" "openshift-lws-operator"
patch_deployment_env "${NS_LWS}" "openshift-lws-operator" "openshift-lws-operator" "RELATED_IMAGE_OPERAND_IMAGE"

# Also patch the lws-controller-manager deployment (operand)
patch_deployment_image "${NS_LWS}" "lws-controller-manager" "manager"

patch_pull_secret "${NS_LWS}" "openshift-lws-operator"
patch_pull_secret "${NS_LWS}" "lws-controller-manager"

echo ""

# =============================================================================
# 4. KSERVE
# =============================================================================
echo "[4/5] Patching KServe..."

# Patch ConfigMaps
patch_configmap "${NS_KSERVE}" "kserve-parameters"
patch_configmap "${NS_KSERVE}" "inferenceservice-config"

# Patch KServe controller deployment
patch_deployment_image "${NS_KSERVE}" "kserve-controller-manager" "manager"

patch_pull_secret "${NS_KSERVE}" "kserve-controller-manager"
patch_pull_secret "${NS_KSERVE}" "default"

echo ""

# =============================================================================
# 5. INFERENCE GATEWAY
# =============================================================================
echo "[5/5] Patching inference gateway..."

# Patch gateway pod image (istio proxy)
GATEWAY_DEPLOY=$(kubectl get deployment -n "${NS_KSERVE}" -l gateway.networking.k8s.io/gateway-name=inference-gateway --ignore-not-found -o jsonpath='{.items[0].metadata.name}')

if [[ -n "${GATEWAY_DEPLOY}" ]]; then
  patch_deployment_image "${NS_KSERVE}" "${GATEWAY_DEPLOY}" "istio-proxy"
  patch_pull_secret "${NS_KSERVE}" "inference-gateway-istio"
else
  echo "  [SKIP] No inference gateway found"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo "============================================"
echo "  Image patching complete!"
echo "============================================"
echo ""
echo "Deployments will restart automatically with new images."
echo ""
echo "Monitor rollouts:"
echo "  kubectl get pods -n ${NS_CERT_MANAGER_OPERATOR}"
echo "  kubectl get pods -n ${NS_ISTIO}"
echo "  kubectl get pods -n ${NS_LWS}"
echo "  kubectl get pods -n ${NS_KSERVE}"
echo ""
if [[ -n "${PULL_SECRET_NAME}" ]]; then
  echo "Pull secret '${PULL_SECRET_NAME}' must exist in each namespace."
  echo "Create it with:"
  echo "  kubectl create secret docker-registry ${PULL_SECRET_NAME} \\"
  echo "    --docker-server=${TARGET_REGISTRY%%/*} \\"
  echo "    --docker-username=<username> \\"
  echo "    --docker-password=<password> \\"
  echo "    -n <namespace>"
fi
