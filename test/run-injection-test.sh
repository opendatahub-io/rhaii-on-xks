#!/bin/bash
# Test sidecar injection
set -e

NAMESPACE="${TEST_NAMESPACE:-sail-test}"
TIMEOUT="${TIMEOUT:-120}"

echo ""
echo "========================================"
echo "  SIDECAR INJECTION TEST"
echo "========================================"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

# Create test namespace with injection enabled
echo ""
echo "[1/4] Creating test namespace with injection label..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

# Deploy test pod
echo ""
echo "[2/4] Deploying test pod..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: injection-test
  labels:
    app: injection-test
spec:
  containers:
  - name: app
    image: nginx:alpine
    ports:
    - containerPort: 80
EOF

# Wait for pod
echo ""
echo "[3/4] Waiting for pod to be ready..."
sleep 5
kubectl wait --for=condition=ready pod/injection-test -n "$NAMESPACE" --timeout="${TIMEOUT}s" || true

# Check for sidecar
echo ""
echo "[4/4] Checking for istio-proxy sidecar..."
CONTAINERS=$(kubectl get pod injection-test -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")

if echo "$CONTAINERS" | grep -q "istio-proxy"; then
    echo "  Containers: $CONTAINERS"
    echo ""
    echo "=== INJECTION TEST: PASS (sidecar injected) ==="
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    exit 0
else
    echo "  Containers: $CONTAINERS"
    echo "  Expected: istio-proxy sidecar"
    echo ""
    echo "=== INJECTION TEST: FAIL (no sidecar) ==="
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    exit 1
fi
