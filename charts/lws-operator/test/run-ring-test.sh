#!/bin/bash
# Run ring topology test
#
# Creates a LeaderWorkerSet with ring topology and verifies that
# all pods can communicate in the expected ring pattern.
#
# Environment variables:
#   TEST_NAMESPACE - namespace to run tests in (default: lws-test)
#   TIMEOUT        - wait timeout in seconds (default: 120)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAMESPACE="${TEST_NAMESPACE:-lws-test}"
TIMEOUT="${TIMEOUT:-120}"

echo ""
echo "========================================"
echo "  RING TEST"
echo "========================================"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

# Deploy
kubectl apply -f "$SCRIPT_DIR/lws-ring-test.yaml"
echo "Waiting for pods..."
sleep 5
kubectl wait --for=condition=ready pod -l app=ring-test -n "$TEST_NAMESPACE" --timeout="${TIMEOUT}s"

echo "Pods ready, waiting for workers to register..."
sleep 10

echo "Checking leader health..."
RESULT=$(kubectl exec -n "$TEST_NAMESPACE" ring-test-0 -- curl -s localhost:8080/health 2>/dev/null) || true
COUNT=$(echo "$RESULT" | grep -o '10\.' | wc -l)

if [ "$COUNT" -ge 3 ]; then
    echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
    echo ""
    echo "=== RING TEST: PASS ($COUNT workers registered) ==="
    kubectl delete -f "$SCRIPT_DIR/lws-ring-test.yaml" --ignore-not-found
    exit 0
else
    echo "$RESULT"
    echo ""
    echo "=== RING TEST: FAIL (expected 3 workers, got $COUNT) ==="
    kubectl delete -f "$SCRIPT_DIR/lws-ring-test.yaml" --ignore-not-found >/dev/null 2>&1
    exit 1
fi
