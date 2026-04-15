#!/usr/bin/env bash
#
# MaaS TLS Setup Script
#
# Patches the Authorino instance to trust the opendatahub internal CA so that
# Authorino can make HTTPS callbacks to maas-api for API key validation.
#
# The maas-controller generates AuthPolicies with HTTP metadata callbacks to:
#   https://maas-api.<ns>.svc.cluster.local:8443/internal/v1/api-keys/validate
#   https://maas-api.<ns>.svc.cluster.local:8443/internal/v1/subscriptions/select
#
# maas-api serves HTTPS using a cert signed by opendatahub-ca-issuer (cert-manager).
# Authorino's default trust store only has public CAs, so it rejects the connection.
# This script adds the opendatahub CA to Authorino's trust store.
#
# Prerequisites:
#   - cert-manager deployed with opendatahub-ca-issuer
#   - RHCL/Kuadrant deployed with Authorino instance
#   - MaaS chart deployed (creates the maas-api-serving-cert Certificate)
#
# Usage:
#   ./scripts/setup-maas-tls.sh
#
# Environment variables (with defaults):
#   MAAS_NAMESPACE=opendatahub
#   CERT_MANAGER_NAMESPACE=cert-manager
#   KUADRANT_NAMESPACE=kuadrant-system
#   CA_SECRET_NAME=opendatahub-ca

set -euo pipefail

MAAS_NAMESPACE="${MAAS_NAMESPACE:-opendatahub}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
KUADRANT_NAMESPACE="${KUADRANT_NAMESPACE:-kuadrant-system}"
CA_SECRET_NAME="${CA_SECRET_NAME:-opendatahub-ca}"
COMBINED_CM_NAME="${COMBINED_CM_NAME:-authorino-ca-bundle}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-istio-system}"
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
CA_BUNDLE_CONFIGMAP="${CA_BUNDLE_CONFIGMAP:-odh-ca-bundle}"
CA_MOUNT_PATH="${CA_MOUNT_PATH:-/var/run/secrets/opendatahub}"

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[OK]   $*"; }
log_error()   { echo "[ERROR] $*" >&2; }
log_wait()    { echo "[WAIT] $*"; }

# ---------------------------------------------------------------------------
# Step 1: Wait for maas-api-serving-cert to be issued by cert-manager
# ---------------------------------------------------------------------------
wait_for_cert() {
  log_wait "Waiting for maas-api-serving-cert to be issued..."
  local retries=0
  while [ $retries -lt 30 ]; do
    local ready
    ready=$(kubectl get certificate maas-api-serving-cert -n "$MAAS_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$ready" = "True" ]; then
      log_success "maas-api-serving-cert is Ready"
      return 0
    fi
    retries=$((retries + 1))
    sleep 5
  done
  log_error "Timeout waiting for maas-api-serving-cert (150s)"
  kubectl get certificate maas-api-serving-cert -n "$MAAS_NAMESPACE" -o yaml 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
# Step 2: Extract the opendatahub CA certificate
# ---------------------------------------------------------------------------
extract_ca() {
  log_info "Extracting opendatahub CA from ${CERT_MANAGER_NAMESPACE}/${CA_SECRET_NAME}..."

  local ca_cert
  ca_cert=$(kubectl get secret "$CA_SECRET_NAME" -n "$CERT_MANAGER_NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)

  if [ -z "$ca_cert" ]; then
    ca_cert=$(kubectl get secret "$CA_SECRET_NAME" -n "$CERT_MANAGER_NAMESPACE" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
  fi

  if [ -z "$ca_cert" ]; then
    log_error "Cannot extract CA cert from secret ${CA_SECRET_NAME}"
    return 1
  fi

  ODH_CA_PEM=$(echo "$ca_cert" | base64 -d)
  log_success "Extracted opendatahub CA certificate"
}

# ---------------------------------------------------------------------------
# Step 3: Read the system CA bundle from a running Authorino pod
# ---------------------------------------------------------------------------
read_system_ca_bundle() {
  log_info "Reading system CA bundle from Authorino pod..."

  local authorino_pod
  authorino_pod=$(kubectl get pods -n "$KUADRANT_NAMESPACE" \
    -l authorino-resource=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "$authorino_pod" ]; then
    authorino_pod=$(kubectl get pods -n "$KUADRANT_NAMESPACE" \
      -l app=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [ -z "$authorino_pod" ]; then
    log_error "No Authorino pod found in ${KUADRANT_NAMESPACE}"
    log_info "Available pods:"
    kubectl get pods -n "$KUADRANT_NAMESPACE" --show-labels 2>/dev/null || true
    return 1
  fi

  log_info "Using Authorino pod: ${authorino_pod}"
  SYSTEM_CA_BUNDLE=$(kubectl exec "$authorino_pod" -n "$KUADRANT_NAMESPACE" \
    -- cat /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null || \
    kubectl exec "$authorino_pod" -n "$KUADRANT_NAMESPACE" \
    -- cat /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true)

  if [ -z "$SYSTEM_CA_BUNDLE" ]; then
    log_error "Could not read system CA bundle from Authorino pod"
    return 1
  fi

  log_success "Read system CA bundle ($(echo "$SYSTEM_CA_BUNDLE" | wc -l | tr -d ' ') lines)"
}

# ---------------------------------------------------------------------------
# Step 4: Create combined CA bundle ConfigMap
# ---------------------------------------------------------------------------
create_combined_bundle() {
  log_info "Creating combined CA bundle ConfigMap: ${COMBINED_CM_NAME}..."

  local combined
  combined="${SYSTEM_CA_BUNDLE}
# ---- opendatahub internal CA ----
${ODH_CA_PEM}"

  kubectl create configmap "$COMBINED_CM_NAME" \
    --from-literal=ca-bundle.crt="$combined" \
    -n "$KUADRANT_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_success "ConfigMap ${COMBINED_CM_NAME} created in ${KUADRANT_NAMESPACE}"
}

# ---------------------------------------------------------------------------
# Step 5: Patch the Authorino CR to mount the combined CA bundle
# ---------------------------------------------------------------------------
patch_authorino() {
  log_info "Patching Authorino CR to mount combined CA bundle..."

  local authorino_name
  authorino_name=$(kubectl get authorino -n "$KUADRANT_NAMESPACE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "$authorino_name" ]; then
    log_error "No Authorino CR found in ${KUADRANT_NAMESPACE}"
    return 1
  fi

  log_info "Patching Authorino CR: ${authorino_name}"

  kubectl patch authorino "$authorino_name" -n "$KUADRANT_NAMESPACE" --type=merge -p '{
    "spec": {
      "volumes": {
        "items": [
          {
            "name": "custom-ca-bundle",
            "mountPath": "/etc/pki/tls/certs",
            "configMaps": ["'"$COMBINED_CM_NAME"'"],
            "items": [
              {
                "key": "ca-bundle.crt",
                "path": "ca-bundle.crt"
              }
            ]
          }
        ]
      }
    }
  }'

  log_success "Authorino CR patched"
}

# ---------------------------------------------------------------------------
# Step 6: Wait for Authorino to restart with new trust store
# ---------------------------------------------------------------------------
wait_for_authorino() {
  log_wait "Waiting for Authorino rollout..."
  sleep 5

  kubectl rollout status deployment -n "$KUADRANT_NAMESPACE" \
    -l authorino-resource=authorino --timeout=120s 2>/dev/null || \
  kubectl rollout status deployment -n "$KUADRANT_NAMESPACE" \
    -l app=authorino --timeout=120s 2>/dev/null || true

  log_wait "Verifying Authorino pod has the CA mount..."
  local authorino_pod
  authorino_pod=$(kubectl get pods -n "$KUADRANT_NAMESPACE" \
    -l authorino-resource=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    kubectl get pods -n "$KUADRANT_NAMESPACE" \
    -l app=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -n "$authorino_pod" ]; then
    if kubectl exec "$authorino_pod" -n "$KUADRANT_NAMESPACE" \
      -- grep -q "opendatahub" /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null; then
      log_success "Authorino pod has opendatahub CA in trust store"
    else
      log_error "opendatahub CA not found in Authorino trust store -- check volume mount"
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 7: Verify maas-api is serving HTTPS
# ---------------------------------------------------------------------------
verify_maas_api() {
  log_info "Verifying maas-api is serving HTTPS on port 8443..."

  local maas_pod
  maas_pod=$(kubectl get pods -n "$MAAS_NAMESPACE" \
    -l app.kubernetes.io/name=maas-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "$maas_pod" ]; then
    log_error "No maas-api pod found"
    return 1
  fi

  local health
  health=$(kubectl exec "$maas_pod" -n "$MAAS_NAMESPACE" -- \
    wget -q --no-check-certificate -O - https://localhost:8443/health 2>/dev/null || true)

  if echo "$health" | grep -qi "ok\|healthy\|alive"; then
    log_success "maas-api is healthy on HTTPS:8443"
  else
    log_info "maas-api health check returned: ${health:-empty}"
    log_info "This may be normal if maas-api uses a different health response format"
  fi
}

# ---------------------------------------------------------------------------
# Step 8: Create CA bundle ConfigMap in gateway namespace
# (follows mpaul's setup-gateway.sh pattern)
# ---------------------------------------------------------------------------
setup_gateway_ca_bundle() {
  log_info "Creating CA bundle ConfigMap in ${GATEWAY_NAMESPACE}..."

  kubectl create configmap "$CA_BUNDLE_CONFIGMAP" \
    --from-literal=ca.crt="$ODH_CA_PEM" \
    -n "$GATEWAY_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_success "ConfigMap ${CA_BUNDLE_CONFIGMAP} created in ${GATEWAY_NAMESPACE}"
}

# ---------------------------------------------------------------------------
# Step 9: Create gateway deployment config for CA volume mount
# ---------------------------------------------------------------------------
create_gateway_config() {
  log_info "Creating gateway deployment config for CA mount..."

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${GATEWAY_NAME}-config
  namespace: ${GATEWAY_NAMESPACE}
data:
  deployment: |
    spec:
      template:
        spec:
          volumes:
          - name: odh-ca-bundle
            configMap:
              name: ${CA_BUNDLE_CONFIGMAP}
          containers:
          - name: istio-proxy
            volumeMounts:
            - name: odh-ca-bundle
              mountPath: ${CA_MOUNT_PATH}
              readOnly: true
  service: |
    metadata:
      annotations:
        service.beta.kubernetes.io/port_80_health-probe_protocol: tcp
EOF

  log_success "Gateway config ConfigMap created: ${GATEWAY_NAME}-config"
}

# ---------------------------------------------------------------------------
# Step 10: Patch Gateway with infrastructure.parametersRef
# ---------------------------------------------------------------------------
patch_gateway() {
  log_info "Patching Gateway ${GATEWAY_NAME} with parametersRef..."

  kubectl patch gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" --type=merge -p '{
    "spec": {
      "infrastructure": {
        "parametersRef": {
          "group": "",
          "kind": "ConfigMap",
          "name": "'"${GATEWAY_NAME}-config"'"
        }
      }
    }
  }'

  log_success "Gateway patched with parametersRef"

  log_wait "Waiting for Gateway pod to restart with CA mount..."
  sleep 10

  kubectl wait --for=condition=Programmed gateway/"$GATEWAY_NAME" \
    -n "$GATEWAY_NAMESPACE" --timeout=120s

  log_success "Gateway is programmed with CA bundle"
}

# ---------------------------------------------------------------------------
# Step 11: Verify gateway pod has CA mounted
# ---------------------------------------------------------------------------
verify_gateway_ca() {
  log_info "Verifying gateway pod has CA mounted..."

  local gw_pod
  gw_pod=$(kubectl get pods -n "$GATEWAY_NAMESPACE" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "$gw_pod" ]; then
    log_error "No gateway pod found for ${GATEWAY_NAME}"
    return 1
  fi

  if kubectl exec "$gw_pod" -n "$GATEWAY_NAMESPACE" -- \
    ls "${CA_MOUNT_PATH}/ca.crt" &>/dev/null; then
    log_success "Gateway pod has CA mounted at ${CA_MOUNT_PATH}/ca.crt"
  else
    log_error "CA not found at ${CA_MOUNT_PATH}/ca.crt in gateway pod"
    log_info "The gateway pod may need to be restarted manually"
    kubectl delete pod "$gw_pod" -n "$GATEWAY_NAMESPACE" --ignore-not-found
    sleep 10
    kubectl wait --for=condition=Ready pod \
      -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
      -n "$GATEWAY_NAMESPACE" --timeout=120s
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "=== MaaS TLS Setup ==="
  log_info "MaaS namespace:      ${MAAS_NAMESPACE}"
  log_info "cert-manager ns:     ${CERT_MANAGER_NAMESPACE}"
  log_info "Kuadrant namespace:  ${KUADRANT_NAMESPACE}"
  log_info "Gateway:             ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}"
  log_info "CA secret:           ${CA_SECRET_NAME}"
  echo ""

  # Part 1: Authorino trust store (for HTTPS callbacks to maas-api)
  log_info "--- Part 1: Authorino trust store ---"
  wait_for_cert
  extract_ca
  read_system_ca_bundle
  create_combined_bundle
  patch_authorino
  wait_for_authorino
  verify_maas_api

  # Part 2: Gateway CA mount (for routing to maas-api:8443)
  log_info ""
  log_info "--- Part 2: Gateway CA bundle ---"
  setup_gateway_ca_bundle
  create_gateway_config
  patch_gateway
  verify_gateway_ca

  echo ""
  log_success "=== MaaS TLS setup complete ==="
  log_info "Authorino trusts opendatahub CA (HTTPS callbacks work)."
  log_info "Gateway has CA mounted at ${CA_MOUNT_PATH}/ca.crt (TLS routing works)."
}

main "$@"
