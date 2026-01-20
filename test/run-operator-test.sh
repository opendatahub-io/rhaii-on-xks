#!/bin/bash
# Test Sail operator deployment
set -e

NAMESPACE="${NAMESPACE:-istio-system}"
TIMEOUT="${TIMEOUT:-120}"

echo ""
echo "========================================"
echo "  OPERATOR TEST"
echo "========================================"

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster. Check KUBECONFIG."; exit 1; }

FAILED=0

# Test 1: Operator deployment
echo ""
echo "[1/4] Checking operator deployment..."
if kubectl get deployment servicemesh-operator3 -n "$NAMESPACE" &>/dev/null; then
    READY=$(kubectl get deployment servicemesh-operator3 -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" -ge 1 ]; then
        echo "  OK: servicemesh-operator3 is running ($READY replicas)"
    else
        echo "  FAIL: servicemesh-operator3 not ready"
        FAILED=1
    fi
else
    echo "  FAIL: servicemesh-operator3 deployment not found"
    FAILED=1
fi

# Test 2: Istio CR exists and is ready
echo ""
echo "[2/4] Checking Istio CR..."
if kubectl get istio default -n "$NAMESPACE" &>/dev/null; then
    STATE=$(kubectl get istio default -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
    VERSION=$(kubectl get istio default -n "$NAMESPACE" -o jsonpath='{.spec.version}' 2>/dev/null || echo "Unknown")
    if [ "$STATE" = "Healthy" ]; then
        echo "  OK: Istio CR is Healthy (version: $VERSION)"
    else
        echo "  WARN: Istio CR state is '$STATE' (expected: Healthy)"
        # Don't fail on this - might still be reconciling
    fi
else
    echo "  FAIL: Istio CR 'default' not found"
    FAILED=1
fi

# Test 3: Istiod deployment
echo ""
echo "[3/4] Checking istiod..."
ISTIOD=$(kubectl get deployment -n "$NAMESPACE" -l app=istiod -o name 2>/dev/null | head -1)
if [ -n "$ISTIOD" ]; then
    READY=$(kubectl get "$ISTIOD" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" -ge 1 ]; then
        echo "  OK: istiod is running ($READY replicas)"
    else
        echo "  WARN: istiod not ready yet"
    fi
else
    echo "  WARN: istiod deployment not found (may still be deploying)"
fi

# Test 4: Istio version matches expected
echo ""
echo "[4/4] Checking Istio version..."
EXPECTED_VERSION="${EXPECTED_ISTIO_VERSION:-}"
if [ -n "$EXPECTED_VERSION" ]; then
    ACTUAL=$(kubectl get istio default -n "$NAMESPACE" -o jsonpath='{.spec.version}' 2>/dev/null || echo "")
    if [ "$ACTUAL" = "$EXPECTED_VERSION" ]; then
        echo "  OK: Istio version is $ACTUAL"
    else
        echo "  FAIL: Expected version $EXPECTED_VERSION, got $ACTUAL"
        FAILED=1
    fi
else
    VERSION=$(kubectl get istio default -n "$NAMESPACE" -o jsonpath='{.spec.version}' 2>/dev/null || echo "Unknown")
    echo "  INFO: Istio version is $VERSION (no expected version set)"
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo "=== OPERATOR TEST: PASS ==="
    exit 0
else
    echo "=== OPERATOR TEST: FAIL ==="
    exit 1
fi
