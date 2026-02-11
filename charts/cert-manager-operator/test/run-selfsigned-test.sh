#!/bin/bash
# Test self-signed certificate issuance
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAMESPACE="${TEST_NAMESPACE:-cert-manager-test}"
TIMEOUT="${TIMEOUT:-120}"

echo ""
echo "========================================"
echo "  SELF-SIGNED CERTIFICATE TEST"
echo "========================================"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

# Deploy test resources
echo "Creating test namespace and resources..."
kubectl apply -f "$SCRIPT_DIR/selfsigned-test.yaml"

echo "Waiting for certificate to be ready..."
sleep 5

# Wait for certificate to become ready
if kubectl wait --for=condition=ready certificate/selfsigned-cert -n "$TEST_NAMESPACE" --timeout="${TIMEOUT}s"; then
    echo ""
    echo "Certificate is ready. Verifying..."

    # Verify the secret was created
    if kubectl get secret selfsigned-cert-tls -n "$TEST_NAMESPACE" >/dev/null 2>&1; then
        echo "Secret 'selfsigned-cert-tls' created successfully."

        # Verify certificate content
        CERT_SUBJECT=$(kubectl get secret selfsigned-cert-tls -n "$TEST_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject 2>/dev/null || echo "")

        if [[ "$CERT_SUBJECT" == *"selfsigned.example.com"* ]]; then
            CERT_CN="$CERT_SUBJECT"
            echo "Certificate CN verified: $CERT_CN"
            echo ""
            echo "=== SELF-SIGNED TEST: PASS ==="
            kubectl delete -f "$SCRIPT_DIR/selfsigned-test.yaml" --ignore-not-found >/dev/null 2>&1
            exit 0
        else
            echo "Certificate CN mismatch. Got: $CERT_SUBJECT"
            echo ""
            echo "=== SELF-SIGNED TEST: FAIL ==="
            kubectl delete -f "$SCRIPT_DIR/selfsigned-test.yaml" --ignore-not-found >/dev/null 2>&1
            exit 1
        fi
    else
        echo "ERROR: Secret 'selfsigned-cert-tls' not found"
        echo ""
        echo "=== SELF-SIGNED TEST: FAIL ==="
        kubectl delete -f "$SCRIPT_DIR/selfsigned-test.yaml" --ignore-not-found >/dev/null 2>&1
        exit 1
    fi
else
    echo "ERROR: Certificate did not become ready within ${TIMEOUT}s"
    kubectl describe certificate/selfsigned-cert -n "$TEST_NAMESPACE" 2>/dev/null || true
    echo ""
    echo "=== SELF-SIGNED TEST: FAIL ==="
    kubectl delete -f "$SCRIPT_DIR/selfsigned-test.yaml" --ignore-not-found >/dev/null 2>&1
    exit 1
fi
