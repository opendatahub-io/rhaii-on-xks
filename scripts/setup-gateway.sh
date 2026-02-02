#!/usr/bin/env bash
#
# Gateway Setup Script for KServe Integration
#
# This script creates the inference Gateway with CA bundle mounting for mTLS
# between LLMInferenceService components (router, scheduler, vLLM).
#
# KServe's LLMInferenceService uses mTLS between components (router ↔ scheduler ↔ vLLM),
# which requires the CA bundle mounted at /var/run/secrets/opendatahub/ca.crt.
# The Gateway needs this CA to trust the backend services it routes traffic to.
#
# Usage:
#   ./scripts/setup-gateway.sh
#
# Environment variables (with defaults):
#   KSERVE_NAMESPACE=opendatahub
#   CERT_MANAGER_NAMESPACE=cert-manager
#   CA_SECRET_NAME=opendatahub-ca
#   GATEWAY_NAME=inference-gateway
#
# Prerequisites:
#   - llm-d-infra-xks deployed (make deploy)
#   - cert-manager CA certificate issued
#   - GatewayClass 'istio' available

set -euo pipefail

# Configuration Variables
KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-opendatahub}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CA_SECRET_NAME="${CA_SECRET_NAME:-opendatahub-ca}"
GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"
CA_BUNDLE_CONFIGMAP="${CA_BUNDLE_CONFIGMAP:-odh-ca-bundle}"
CA_MOUNT_PATH="${CA_MOUNT_PATH:-/var/run/secrets/opendatahub}"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info() {
  echo "ℹ️  $*"
}

log_success() {
  echo "✅ $*"
}

log_error() {
  echo "❌ $*" >&2
}

log_wait() {
  echo "⏳ $*"
}

# -----------------------------------------------------------------------------
# setup_ca_bundle
# Extract CA certificate from cert-manager and create ConfigMap in KServe namespace
# -----------------------------------------------------------------------------
setup_ca_bundle() {
  log_info "Setting up CA bundle ConfigMap..."

  # Extract CA certificate from the secret (try ca.crt first, then tls.crt)
  local ca_cert
  ca_cert=$(kubectl get secret "${CA_SECRET_NAME}" -n "${CERT_MANAGER_NAMESPACE}" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)

  if [[ -z "$ca_cert" ]]; then
    ca_cert=$(kubectl get secret "${CA_SECRET_NAME}" -n "${CERT_MANAGER_NAMESPACE}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
  fi

  if [[ -z "$ca_cert" ]]; then
    log_error "Could not extract CA certificate from ${CA_SECRET_NAME} secret in ${CERT_MANAGER_NAMESPACE}"
    log_error "Make sure cert-manager is installed and the CA certificate has been issued."
    log_error "Run 'make deploy' first to deploy llm-d-infra-xks."
    return 1
  fi

  # Create CA bundle ConfigMap in KServe namespace
  log_wait "Creating ${CA_BUNDLE_CONFIGMAP} ConfigMap in ${KSERVE_NAMESPACE}..."
  kubectl create configmap "${CA_BUNDLE_CONFIGMAP}" \
    --from-literal=ca.crt="$(echo "$ca_cert" | base64 -d)" \
    -n "${KSERVE_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_success "CA bundle ConfigMap created: ${CA_BUNDLE_CONFIGMAP}"
}

# -----------------------------------------------------------------------------
# create_gateway_config
# Create Gateway deployment configuration ConfigMap for Istio
# This configures the Gateway pod to mount the CA bundle
# -----------------------------------------------------------------------------
create_gateway_config() {
  log_info "Creating Gateway deployment configuration..."

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${GATEWAY_NAME}-config
  namespace: ${KSERVE_NAMESPACE}
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
EOF

  log_success "Gateway config ConfigMap created: ${GATEWAY_NAME}-config"
}

# -----------------------------------------------------------------------------
# create_gateway
# Create Gateway resource with parametersRef to mount CA bundle
# -----------------------------------------------------------------------------
create_gateway() {
  log_info "Creating Gateway resource..."

  # Check if GatewayClass 'istio' exists
  if ! kubectl get gatewayclass istio &>/dev/null; then
    log_error "GatewayClass 'istio' not found. Make sure Istio/Sail Operator is installed."
    log_error "Run 'make deploy' first to deploy llm-d-infra-xks."
    return 1
  fi

  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${KSERVE_NAMESPACE}
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
    parametersRef:
      group: ""
      kind: ConfigMap
      name: ${GATEWAY_NAME}-config
EOF

  # Wait for Gateway to be programmed
  log_wait "Waiting for Gateway to be programmed..."
  if kubectl wait --for=condition=Programmed gateway/"${GATEWAY_NAME}" -n "${KSERVE_NAMESPACE}" --timeout=120s; then
    log_success "Gateway created and programmed: ${GATEWAY_NAME}"
  else
    log_error "Gateway failed to become programmed within timeout"
    kubectl get gateway "${GATEWAY_NAME}" -n "${KSERVE_NAMESPACE}" -o yaml
    return 1
  fi
}

# -----------------------------------------------------------------------------
# verify_setup
# Verify the Gateway setup is complete
# -----------------------------------------------------------------------------
verify_setup() {
  log_info "Verifying Gateway setup..."

  echo ""
  echo "ConfigMaps:"
  kubectl get configmap -n "${KSERVE_NAMESPACE}" | grep -E "${CA_BUNDLE_CONFIGMAP}|${GATEWAY_NAME}-config" || true

  echo ""
  echo "Gateway:"
  kubectl get gateway -n "${KSERVE_NAMESPACE}" "${GATEWAY_NAME}"

  echo ""
  echo "Gateway Pod (should have CA bundle mounted):"
  kubectl get pods -n "${KSERVE_NAMESPACE}" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" -o wide 2>/dev/null || true

  log_success "Gateway setup complete!"
  echo ""
  echo "The Gateway is ready at: ${KSERVE_NAMESPACE}/${GATEWAY_NAME}"
  echo "LLMInferenceService resources will use this gateway for ingress traffic."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log_info "Setting up Gateway for KServe with CA bundle mounting"
  log_info "Namespace: ${KSERVE_NAMESPACE}"
  log_info "CA Secret: ${CERT_MANAGER_NAMESPACE}/${CA_SECRET_NAME}"
  echo ""

  # Ensure namespace exists
  if ! kubectl get namespace "${KSERVE_NAMESPACE}" &>/dev/null; then
    log_wait "Creating namespace ${KSERVE_NAMESPACE}..."
    kubectl create namespace "${KSERVE_NAMESPACE}"
  fi

  setup_ca_bundle
  create_gateway_config
  create_gateway
  verify_setup
}

main "$@"
