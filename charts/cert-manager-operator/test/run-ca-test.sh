#!/bin/bash
# Test CA issuer and certificate chain
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAMESPACE="${TEST_NAMESPACE:-cert-manager-test}"
TIMEOUT="${TIMEOUT:-120}"

echo ""
echo "========================================"
echo "  CA ISSUER CERTIFICATE TEST"
echo "========================================"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

# Deploy test resources
echo "Creating test namespace and resources..."
kubectl apply -f "$SCRIPT_DIR/ca-test.yaml"

echo "Waiting for CA certificate to be ready..."
sleep 5

# Wait for CA certificate
if ! kubectl wait --for=condition=ready certificate/ca-cert -n "$TEST_NAMESPACE" --timeout="${TIMEOUT}s"; then
    echo "ERROR: CA certificate did not become ready"
    kubectl describe certificate/ca-cert -n "$TEST_NAMESPACE" 2>/dev/null || true
    echo ""
    echo "=== CA TEST: FAIL ==="
    kubectl delete -f "$SCRIPT_DIR/ca-test.yaml" --ignore-not-found >/dev/null 2>&1
    exit 1
fi

echo "CA certificate ready. Waiting for leaf certificate..."
sleep 3

# Wait for leaf certificate
if ! kubectl wait --for=condition=ready certificate/leaf-cert -n "$TEST_NAMESPACE" --timeout="${TIMEOUT}s"; then
    echo "ERROR: Leaf certificate did not become ready"
    kubectl describe certificate/leaf-cert -n "$TEST_NAMESPACE" 2>/dev/null || true
    echo ""
    echo "=== CA TEST: FAIL ==="
    kubectl delete -f "$SCRIPT_DIR/ca-test.yaml" --ignore-not-found >/dev/null 2>&1
    exit 1
fi

echo ""
echo "Both certificates ready. Verifying chain..."

# Verify the leaf certificate is signed by the CA
CA_CERT=$(kubectl get secret ca-cert-tls -n "$TEST_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)
LEAF_CERT=$(kubectl get secret leaf-cert-tls -n "$TEST_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)

# Verify chain using openssl
if echo "$LEAF_CERT" | openssl verify -CAfile <(echo "$CA_CERT") >/dev/null 2>&1; then
    echo "Certificate chain verified successfully."

    # Show certificate details
    echo ""
    echo "CA Certificate:"
    echo "$CA_CERT" | openssl x509 -noout -subject -issuer 2>/dev/null
    echo ""
    echo "Leaf Certificate:"
    echo "$LEAF_CERT" | openssl x509 -noout -subject -issuer 2>/dev/null

    echo ""
    echo "=== CA TEST: PASS ==="
    kubectl delete -f "$SCRIPT_DIR/ca-test.yaml" --ignore-not-found >/dev/null 2>&1
    exit 0
else
    echo "ERROR: Certificate chain verification failed"
    echo ""
    echo "=== CA TEST: FAIL ==="
    kubectl delete -f "$SCRIPT_DIR/ca-test.yaml" --ignore-not-found >/dev/null 2>&1
    exit 1
fi
