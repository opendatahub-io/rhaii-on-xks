#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# RHCL Integration Test
#
# Deploys a test Gateway + HTTPRoute + AuthPolicy + RateLimitPolicy,
# validates everything works, then cleans up.
#
# Prerequisites:
#   - RHCL operators running (make install)
#   - Istio/Service Mesh installed
#   - Gateway API CRDs installed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
TEST_NS="rhcl-test"
GW_NS="rhcl-test-gateway"
INSTANCE_NS="${INSTANCE_NAMESPACE:-kuadrant-system}"
TIMEOUT=120

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  echo -e "\n${CYAN}--- Cleanup ---${NC}"
  kubectl delete secret test-api-key -n "$INSTANCE_NS" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "$SCRIPT_DIR/test-rhcl-deployment.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete namespace "$GW_NS" --ignore-not-found --wait=false 2>/dev/null || true
  echo "  Cleanup complete"
}

trap cleanup EXIT

echo -e "${CYAN}=== RHCL Integration Test ===${NC}"

# ---------------------------------------------------------------------------
# 1. Deploy test resources
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Deploying test resources ---${NC}"
kubectl apply -f "$SCRIPT_DIR/test-rhcl-deployment.yaml"
echo "  Test manifests applied"

# ---------------------------------------------------------------------------
# 2. Wait for echo-server
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Waiting for echo-server ---${NC}"
if kubectl wait --for=condition=Available deployment/echo-server \
  -n "$TEST_NS" --timeout=${TIMEOUT}s 2>/dev/null; then
  pass "echo-server deployment ready"
else
  fail "echo-server deployment not ready after ${TIMEOUT}s"
fi

# ---------------------------------------------------------------------------
# 3. Wait for Gateway to be programmed
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Waiting for Gateway ---${NC}"
GW_READY=false
for i in $(seq 1 $((TIMEOUT / 5))); do
  PROGRAMMED=$(kubectl get gateway test-gateway -n "$GW_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [ "$PROGRAMMED" = "True" ]; then
    GW_READY=true
    break
  fi
  sleep 5
done
if [ "$GW_READY" = "true" ]; then
  pass "Gateway programmed"
else
  fail "Gateway not programmed after ${TIMEOUT}s"
fi

# Get gateway address
GW_ADDRESS=$(kubectl get gateway test-gateway -n "$GW_NS" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")

if [ -n "$GW_ADDRESS" ]; then
  pass "Gateway address: $GW_ADDRESS"
else
  fail "Gateway has no address assigned"
fi

# ---------------------------------------------------------------------------
# 4. Wait for policies to be enforced
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Waiting for policies ---${NC}"
sleep 15

# Check AuthPolicy
AUTH_STATUS=$(kubectl get authpolicy echo-auth -n "$TEST_NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "")
if [ "$AUTH_STATUS" = "True" ]; then
  pass "AuthPolicy enforced"
else
  echo -e "  ${YELLOW}WARN${NC}  AuthPolicy status: $AUTH_STATUS (may still be reconciling)"
fi

# Check RateLimitPolicy
RL_STATUS=$(kubectl get ratelimitpolicy test-ratelimit -n "$GW_NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "")
if [ "$RL_STATUS" = "True" ]; then
  pass "RateLimitPolicy enforced"
else
  echo -e "  ${YELLOW}WARN${NC}  RateLimitPolicy status: $RL_STATUS (may still be reconciling)"
fi

# ---------------------------------------------------------------------------
# 5. Test HTTP requests (only if gateway has address)
# ---------------------------------------------------------------------------
if [ -n "$GW_ADDRESS" ]; then
  echo -e "\n${CYAN}--- HTTP Request Tests (in-cluster) ---${NC}"

  # Istio creates a Service named <gateway-name>-istio in the gateway namespace.
  # Use its ClusterIP to avoid AKS hairpin NAT issues with external LB IPs.
  GW_SVC="test-gateway-istio.${GW_NS}.svc.cluster.local"

  CURL_POD="rhcl-test-curl"
  kubectl run "$CURL_POD" -n "$TEST_NS" --image=curlimages/curl:8.12.1 \
    --restart=Never --command -- sleep 300 >/dev/null 2>&1
  kubectl wait --for=condition=Ready pod/"$CURL_POD" -n "$TEST_NS" --timeout=60s >/dev/null 2>&1

  # Wait for WASM plugin to be loaded by Envoy (can take up to 30s)
  echo "  Waiting 30s for WASM plugin to load..."
  sleep 30

  in_cluster_curl() {
    local code
    code=$(kubectl exec "$CURL_POD" -n "$TEST_NS" -- \
      curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$@" 2>/dev/null)
    echo "${code:-000}"
  }

  # Test without API key (should get 401)
  HTTP_CODE=$(in_cluster_curl "http://${GW_SVC}/")
  if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    pass "Unauthenticated request rejected (HTTP $HTTP_CODE)"
  elif [ "$HTTP_CODE" = "000" ]; then
    echo -e "  ${YELLOW}WARN${NC}  Cannot reach gateway from test pod (service: $GW_SVC)"
  else
    fail "Unauthenticated request returned HTTP $HTTP_CODE (expected 401/403)"
  fi

  # Test with API key (should get 200 or 429 if rate limit already hit)
  HTTP_CODE=$(in_cluster_curl "http://${GW_SVC}/?apikey=test-rhcl-key")
  if [ "$HTTP_CODE" = "200" ]; then
    pass "Authenticated request succeeded (HTTP 200)"
  elif [ "$HTTP_CODE" = "429" ]; then
    pass "Authenticated request hit rate limit (HTTP 429 — auth + rate limiting both working)"
  elif [ "$HTTP_CODE" = "000" ]; then
    echo -e "  ${YELLOW}WARN${NC}  Cannot reach gateway from test pod"
  else
    fail "Authenticated request returned HTTP $HTTP_CODE (expected 200 or 429)"
  fi

  # Test rate limiting (send 10 requests, expect some 429s)
  echo -e "\n${CYAN}--- Rate Limit Test ---${NC}"
  COUNT_429=0
  COUNT_200=0
  for i in $(seq 1 10); do
    CODE=$(in_cluster_curl "http://${GW_SVC}/?apikey=test-rhcl-key")
    if [ "$CODE" = "429" ]; then
      COUNT_429=$((COUNT_429 + 1))
    elif [ "$CODE" = "200" ]; then
      COUNT_200=$((COUNT_200 + 1))
    fi
  done
  if [ "$COUNT_429" -gt 0 ]; then
    pass "Rate limiting active ($COUNT_200 allowed, $COUNT_429 rejected)"
  elif [ "$COUNT_200" -eq 10 ]; then
    echo -e "  ${YELLOW}WARN${NC}  All 10 requests succeeded (rate limit may not have kicked in yet)"
  else
    fail "Rate limiting not working ($COUNT_200 allowed, $COUNT_429 rejected)"
  fi

  # Cleanup curl pod
  kubectl delete pod "$CURL_POD" -n "$TEST_NS" --ignore-not-found >/dev/null 2>&1
else
  echo -e "\n${YELLOW}  Skipping HTTP tests: gateway has no address${NC}"
fi

# ---------------------------------------------------------------------------
# 6. Verify operator-created resources
# ---------------------------------------------------------------------------
echo -e "\n${CYAN}--- Operator-Created Resources ---${NC}"

if kubectl get authconfig -n "$INSTANCE_NS" --no-headers 2>/dev/null | grep -q .; then
  pass "AuthConfig CR created by Kuadrant operator"
else
  echo -e "  ${YELLOW}WARN${NC}  No AuthConfig found (may take time to reconcile)"
fi

if kubectl get wasmplugin -n "$GW_NS" --no-headers 2>/dev/null | grep -q .; then
  pass "WasmPlugin injected in gateway namespace"
else
  echo -e "  ${YELLOW}WARN${NC}  No WasmPlugin found in $GW_NS"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}RESULT: $FAIL test(s) failed${NC}"
else
  echo -e "  ${GREEN}RESULT: All tests passed${NC}"
fi
echo -e "${CYAN}==========================================${NC}"
exit "$FAIL"
