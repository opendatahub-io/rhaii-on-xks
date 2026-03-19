#!/usr/bin/env bash
#
# Pre-deployment checks for RHCL on OpenShift (ARO on Azure / xKS)
# Validates all prerequisites before helmfile apply
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass()  { echo -e "  ${GREEN}OK${NC}    $1"; }
fail()  { echo -e "  ${RED}ERROR${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn()  { echo -e "  ${YELLOW}WARN${NC}  $1"; WARNINGS=$((WARNINGS + 1)); }
header(){ echo -e "\n${CYAN}--- $1 ---${NC}"; }

echo -e "${CYAN}=== RHCL Pre-Deploy Checks ===${NC}"

# ---------------------------------------------------------------------------
# 1. Cluster connectivity
# ---------------------------------------------------------------------------
header "Cluster Connectivity"

if kubectl cluster-info >/dev/null 2>&1; then
  CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
  SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
  pass "Connected to cluster"
  echo "        Context: $CONTEXT"
  echo "        Server:  $SERVER"
else
  fail "Cannot connect to cluster — check kubeconfig"
fi

# Check kubectl version
KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
echo "        kubectl: $KUBECTL_VERSION"

# Check if OpenShift
if kubectl api-resources | grep -q "routes.route.openshift.io" 2>/dev/null; then
  OC_VERSION=$(oc version 2>/dev/null | head -1 || echo "unknown")
  pass "OpenShift cluster detected ($OC_VERSION)"
else
  warn "Not an OpenShift cluster — some features may not work (e.g., ISTIO_GATEWAY_CONTROLLER_NAMES)"
fi

# ---------------------------------------------------------------------------
# 2. Node check
# ---------------------------------------------------------------------------
header "Nodes"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$NODE_COUNT" -gt 0 ]; then
  pass "$NODE_COUNT node(s) available"
else
  fail "No nodes found"
fi

GPU_COUNT=$(kubectl get nodes -l sku=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
NON_GPU_COUNT=$((NODE_COUNT - GPU_COUNT))
echo "        GPU nodes: $GPU_COUNT"
echo "        Non-GPU nodes: $NON_GPU_COUNT (RHCL operators schedule here)"

if [ "$NON_GPU_COUNT" -eq 0 ] && [ "$NODE_COUNT" -gt 0 ]; then
  warn "All nodes are GPU nodes — RHCL operators have affinity to avoid GPU nodes. Remove affinity or add non-GPU nodes."
fi

# ---------------------------------------------------------------------------
# 3. cert-manager
# ---------------------------------------------------------------------------
header "cert-manager"

# Check CRDs
CERT_CRDS=("certificates.cert-manager.io" "issuers.cert-manager.io" "clusterissuers.cert-manager.io")
CERT_CRD_OK=true
for crd in "${CERT_CRDS[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "$crd"
  else
    fail "$crd not found"
    CERT_CRD_OK=false
  fi
done

# Check operator pod
if [ "$CERT_CRD_OK" = true ]; then
  CERT_PODS=$(kubectl get pods --all-namespaces -l app=cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$CERT_PODS" -eq 0 ]; then
    CERT_PODS=$(kubectl get pods --all-namespaces -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "$CERT_PODS" -gt 0 ]; then
    pass "cert-manager controller running ($CERT_PODS pod(s))"
  else
    warn "cert-manager CRDs exist but no controller pods found — TLSPolicy may not work"
  fi
fi

# Check ClusterIssuer exists
if kubectl get clusterissuer >/dev/null 2>&1; then
  ISSUER_COUNT=$(kubectl get clusterissuer --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ISSUER_COUNT" -gt 0 ]; then
    pass "$ISSUER_COUNT ClusterIssuer(s) found"
  else
    warn "No ClusterIssuer found — create one before using TLSPolicy"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Gateway API CRDs
# ---------------------------------------------------------------------------
header "Gateway API CRDs"

GATEWAY_CRDS=("gatewayclasses.gateway.networking.k8s.io" "gateways.gateway.networking.k8s.io" "httproutes.gateway.networking.k8s.io" "referencegrants.gateway.networking.k8s.io")
for crd in "${GATEWAY_CRDS[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    # Check version
    VERSIONS=$(kubectl get crd "$crd" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || echo "")
    if echo "$VERSIONS" | grep -q "v1"; then
      pass "$crd (versions: $VERSIONS)"
    else
      warn "$crd exists but no v1 version found (versions: $VERSIONS) — Gateway API v1.0.0+ recommended"
    fi
  else
    fail "$crd not found — install Gateway API CRDs first"
    echo "        Run: oc kustomize 'github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0' | oc apply -f -"
  fi
done

# ---------------------------------------------------------------------------
# 5. Istio / Service Mesh
# ---------------------------------------------------------------------------
header "Istio / Service Mesh"

if kubectl get crd istios.sailoperator.io >/dev/null 2>&1; then
  pass "Sail operator CRD found (istios.sailoperator.io)"

  # Check for running Istio instance
  ISTIO_READY=$(kubectl get istio --all-namespaces -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "$ISTIO_READY" = "True" ]; then
    pass "Istio instance is Ready"
  elif [ -n "$ISTIO_READY" ]; then
    warn "Istio instance exists but not Ready (status: $ISTIO_READY)"
  else
    warn "No Istio instance found — create one before deploying Gateways"
  fi
else
  # Check for istiod directly
  ISTIOD_PODS=$(kubectl get pods --all-namespaces -l app=istiod --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ISTIOD_PODS" -gt 0 ]; then
    pass "istiod running ($ISTIOD_PODS pod(s))"
  else
    warn "Istio not detected — Gateway resources will not be reconciled without a Gateway API provider"
  fi
fi

# Check GatewayClass
if kubectl get gatewayclass istio >/dev/null 2>&1; then
  pass "GatewayClass 'istio' exists"
else
  warn "GatewayClass 'istio' not found — Gateways with gatewayClassName: istio will not work"
fi

# ---------------------------------------------------------------------------
# 6. Namespace availability
# ---------------------------------------------------------------------------
header "Namespace Availability"

for ns in kuadrant-operators kuadrant-system; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    RESOURCE_COUNT=$(kubectl get all -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$RESOURCE_COUNT" -gt 0 ]; then
      warn "$ns exists with $RESOURCE_COUNT resource(s) — may conflict with fresh install"
    else
      pass "$ns exists (empty — safe for install)"
    fi
  else
    pass "$ns available (does not exist yet)"
  fi
done

# ---------------------------------------------------------------------------
# 7. Registry credentials
# ---------------------------------------------------------------------------
header "Red Hat Registry Auth"

AUTH_FOUND=false

# Check podman auth
PODMAN_AUTH="$HOME/.config/containers/auth.json"
if [ -f "$PODMAN_AUTH" ]; then
  if grep -q "registry.redhat.io" "$PODMAN_AUTH" 2>/dev/null; then
    pass "Podman auth: $PODMAN_AUTH (contains registry.redhat.io)"
    AUTH_FOUND=true
  else
    warn "Podman auth: $PODMAN_AUTH exists but no registry.redhat.io entry"
  fi
fi

# Check docker auth
DOCKER_AUTH="$HOME/.docker/config.json"
if [ -f "$DOCKER_AUTH" ]; then
  if grep -q "registry.redhat.io" "$DOCKER_AUTH" 2>/dev/null; then
    pass "Docker auth: $DOCKER_AUTH (contains registry.redhat.io)"
    AUTH_FOUND=true
  else
    warn "Docker auth: $DOCKER_AUTH exists but no registry.redhat.io entry"
  fi
fi

if [ "$AUTH_FOUND" = false ]; then
  warn "No registry credentials found — provide via pullSecretFile or useSystemPodmanAuth"
  echo "        Download from: https://console.redhat.com/openshift/downloads#tool-pull-secret"
  echo "        Save to: $PODMAN_AUTH"
fi

# Also check registry.access.redhat.com (used by WASM shim)
if [ "$AUTH_FOUND" = true ]; then
  if grep -q "registry.access.redhat.com" "$PODMAN_AUTH" 2>/dev/null || \
     grep -q "registry.access.redhat.com" "$DOCKER_AUTH" 2>/dev/null; then
    pass "registry.access.redhat.com credentials found (for WASM shim)"
  else
    warn "No registry.access.redhat.com credentials — WASM shim pull may fail"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Existing RHCL CRDs (conflict check)
# ---------------------------------------------------------------------------
header "Existing RHCL CRDs"

EXISTING_CRDS=$(kubectl get crd -o name 2>/dev/null | grep "kuadrant\\.io" | wc -l | tr -d ' ')
if [ "$EXISTING_CRDS" -gt 0 ]; then
  warn "$EXISTING_CRDS Kuadrant CRD(s) already exist — Helm will use Server-Side Apply (should be OK)"
else
  pass "No existing Kuadrant CRDs (clean install)"
fi

# ---------------------------------------------------------------------------
# 9. Chart CRDs
# ---------------------------------------------------------------------------
header "Chart CRDs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="$SCRIPT_DIR/../crds"
if [ -d "$CRD_DIR" ]; then
  CRD_COUNT=$(ls -1 "$CRD_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
  if [ "$CRD_COUNT" -eq 14 ]; then
    pass "$CRD_COUNT CRD files in crds/ (expected 14)"
  elif [ "$CRD_COUNT" -gt 0 ]; then
    warn "$CRD_COUNT CRD files in crds/ (expected 14)"
  else
    fail "No CRD files found in crds/ — run: make copy-crds"
  fi
else
  fail "crds/ directory not found — run: make copy-crds"
fi

# ---------------------------------------------------------------------------
# 10. helmfile check
# ---------------------------------------------------------------------------
header "Tools"

if command -v helmfile >/dev/null 2>&1; then
  HELMFILE_VERSION=$(helmfile version 2>/dev/null | head -1 || echo "unknown")
  pass "helmfile: $HELMFILE_VERSION"
else
  fail "helmfile not found — required for deployment"
fi

if command -v helm >/dev/null 2>&1; then
  HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
  pass "helm: $HELM_VERSION"
else
  fail "helm not found"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "  ${GREEN}OK: $((ERRORS == 0 && WARNINGS == 0 ? 1 : 0))${NC}  ${RED}ERRORS: $ERRORS${NC}  ${YELLOW}WARNINGS: $WARNINGS${NC}"

if [ "$ERRORS" -gt 0 ]; then
  echo -e "  ${RED}RESULT: $ERRORS error(s) — fix before deploying${NC}"
  echo -e "${CYAN}==========================================${NC}"
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo -e "  ${YELLOW}RESULT: Passed with $WARNINGS warning(s) — review before deploying${NC}"
  echo -e "${CYAN}==========================================${NC}"
  exit 0
else
  echo -e "  ${GREEN}RESULT: All pre-deploy checks passed${NC}"
  echo -e "${CYAN}==========================================${NC}"
fi
