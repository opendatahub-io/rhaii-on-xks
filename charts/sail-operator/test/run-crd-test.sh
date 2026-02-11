#!/bin/bash
# Test that required CRDs are installed with correct versions
#
# Validates that Gateway API and Inference Extension CRDs are present
# in the cluster and match the expected versions from values.yaml.
#
# Environment variables:
#   GATEWAY_API_VERSION         - expected Gateway API version (default: v1.4.0)
#   INFERENCE_EXTENSION_VERSION - expected Inference Extension version (default: v1.2.0)
set -e

# Expected versions (from values.yaml or override via env)
EXPECTED_GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.0}"
EXPECTED_INFERENCE_VERSION="${INFERENCE_EXTENSION_VERSION:-v1.2.0}"

echo ""
echo "========================================"
echo "  CRD TEST"
echo "========================================"
echo "Expected Gateway API version: $EXPECTED_GATEWAY_API_VERSION"
echo "Expected Inference Extension version: $EXPECTED_INFERENCE_VERSION"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

FAILED=0

# Sail Operator CRDs
ISTIO_CRDS=(
    "istios.sailoperator.io"
    "istiorevisions.sailoperator.io"
    "istiocnis.sailoperator.io"
)

# Istio networking/security CRDs
ISTIO_API_CRDS=(
    "virtualservices.networking.istio.io"
    "destinationrules.networking.istio.io"
    "gateways.networking.istio.io"
    "serviceentries.networking.istio.io"
    "authorizationpolicies.security.istio.io"
    "peerauthentications.security.istio.io"
)

# Gateway API CRDs
GATEWAY_API_CRDS=(
    "gateways.gateway.networking.k8s.io"
    "httproutes.gateway.networking.k8s.io"
    "grpcroutes.gateway.networking.k8s.io"
)

# Inference Extension CRDs (v1.2.0)
INFERENCE_CRDS=(
    "inferencepools.inference.networking.x-k8s.io"
)

check_crds() {
    local name="$1"
    shift
    local crds=("$@")
    local missing=0

    echo ""
    echo "[$name]"
    for crd in "${crds[@]}"; do
        if kubectl get crd "$crd" &>/dev/null; then
            echo "  OK: $crd"
        else
            echo "  MISSING: $crd"
            missing=1
        fi
    done
    return $missing
}

check_version() {
    local crd="$1"
    local annotation="$2"
    local expected="$3"

    # Escape dots in annotation key for jsonpath
    local escaped_annotation=$(echo "$annotation" | sed 's/\./\\./g')
    local actual=$(kubectl get crd "$crd" -o jsonpath="{.metadata.annotations.$escaped_annotation}" 2>/dev/null || echo "")

    if [ -z "$actual" ]; then
        echo "  WARN: $crd - no version annotation found"
        return 0
    elif [ "$actual" = "$expected" ]; then
        echo "  OK: $crd version $actual"
        return 0
    else
        echo "  FAIL: $crd version $actual (expected $expected)"
        return 1
    fi
}

# Check existence
echo ""
echo "Checking CRD existence..."

check_crds "Sail Operator CRDs" "${ISTIO_CRDS[@]}" || FAILED=1
check_crds "Istio API CRDs" "${ISTIO_API_CRDS[@]}" || FAILED=1
check_crds "Gateway API CRDs" "${GATEWAY_API_CRDS[@]}" || FAILED=1
check_crds "Inference Extension CRDs" "${INFERENCE_CRDS[@]}" || FAILED=1

# Check versions
echo ""
echo "Checking CRD versions..."

echo ""
echo "[Gateway API Version]"
check_version "gateways.gateway.networking.k8s.io" "gateway.networking.k8s.io/bundle-version" "$EXPECTED_GATEWAY_API_VERSION" || FAILED=1

echo ""
echo "[Inference Extension Version]"
check_version "inferencepools.inference.networking.x-k8s.io" "inference.networking.k8s.io/bundle-version" "$EXPECTED_INFERENCE_VERSION" || FAILED=1

# Summary
echo ""
TOTAL_CRDS=$((${#ISTIO_CRDS[@]} + ${#ISTIO_API_CRDS[@]} + ${#GATEWAY_API_CRDS[@]} + ${#INFERENCE_CRDS[@]}))
FOUND=$(kubectl get crd -o name 2>/dev/null | grep -cE "istio\.io|sailoperator\.io|gateway\.networking\.k8s\.io|inference\.networking\.x-k8s\.io" || echo "0")
echo "Found $FOUND CRDs (checking $TOTAL_CRDS required)"

echo ""
if [ $FAILED -eq 0 ]; then
    echo "=== CRD TEST: PASS ==="
    exit 0
else
    echo "=== CRD TEST: FAIL ==="
    exit 1
fi
