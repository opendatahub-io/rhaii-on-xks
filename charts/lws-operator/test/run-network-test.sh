#!/bin/bash
# Run network bandwidth test
#
# Creates a LeaderWorkerSet and measures network bandwidth between
# leader and worker pods to verify inter-pod communication.
#
# Environment variables:
#   TEST_NAMESPACE - namespace to run tests in (default: lws-test)
#   TIMEOUT        - wait timeout in seconds (default: 120)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAMESPACE="${TEST_NAMESPACE:-lws-test}"
TIMEOUT="${TIMEOUT:-120}"

cleanup() {
    kubectl delete -f "$SCRIPT_DIR/lws-network-test.yaml" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

echo ""
echo "========================================"
echo "  NETWORK TEST"
echo "========================================"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

# Deploy
kubectl apply -f "$SCRIPT_DIR/lws-network-test.yaml"
echo "Waiting for pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=network-test -n "$TEST_NAMESPACE" --timeout="${TIMEOUT}s"

echo "Pods ready, waiting for iperf3 to complete..."
sleep 20

echo "Checking test results..."
LOGS=$(kubectl logs -n "$TEST_NAMESPACE" network-test-0-1 2>/dev/null | tail -30) || true

if echo "$LOGS" | grep -q "TEST COMPLETE"; then
    echo "$LOGS" | grep -E "(Ping|iperf|Gbits|packets|TEST COMPLETE)" | head -10
    BANDWIDTH=$(echo "$LOGS" | grep "receiver" | grep -oE '[0-9.]+ Gbits' | head -1)
    [ -z "$BANDWIDTH" ] && BANDWIDTH=$(echo "$LOGS" | grep "receiver" | grep -oE '[0-9.]+ Mbits' | head -1)
    [ -z "$BANDWIDTH" ] && BANDWIDTH="N/A"
    echo ""
    echo "=== NETWORK TEST: PASS ($BANDWIDTH) ==="
    exit 0
else
    echo "$LOGS"
    echo ""
    echo "=== NETWORK TEST: FAIL (test did not complete) ==="
    exit 1
fi
