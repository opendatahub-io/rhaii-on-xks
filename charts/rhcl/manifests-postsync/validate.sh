#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# RHCL Post-Deploy Validation
# Validates operators, instances, CRDs, and policy readiness.
# ---------------------------------------------------------------------------

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-kuadrant-operators}"
INSTANCE_NAMESPACE="${INSTANCE_NAMESPACE:-kuadrant-system}"
TIMEOUT="${TIMEOUT:-300}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass()  { echo -e "  ${GREEN}PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail()  { echo -e "  ${RED}FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
warn()  { echo -e "  ${YELLOW}WARN${NC}  $1"; WARN=$((WARN + 1)); }
header(){ echo -e "\n${CYAN}--- $1 ---${NC}"; }

# ---------------------------------------------------------------------------
# 1. Operator Deployments
# ---------------------------------------------------------------------------
header "Operator Deployments"

OPERATORS=(
  "kuadrant-operator-controller-manager"
  "authorino-operator"
  "limitador-operator-controller-manager"
)

for deploy in "${OPERATORS[@]}"; do
  if kubectl get deployment "$deploy" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    READY=$(kubectl get deployment "$deploy" -n "$OPERATOR_NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment "$deploy" -n "$OPERATOR_NAMESPACE" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [ "${READY:-0}" -ge "${DESIRED:-1}" ]; then
      pass "$deploy (${READY}/${DESIRED} ready)"
    else
      fail "$deploy (${READY:-0}/${DESIRED} ready)"
    fi
  else
    fail "$deploy NOT FOUND"
  fi
done

# DNS operator (optional)
if kubectl get deployment dns-operator-controller-manager -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
  READY=$(kubectl get deployment dns-operator-controller-manager -n "$OPERATOR_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -ge 1 ]; then
    pass "dns-operator-controller-manager (${READY}/1 ready)"
  else
    warn "dns-operator-controller-manager (${READY:-0}/1 ready)"
  fi
else
  pass "dns-operator-controller-manager SKIPPED (disabled)"
fi

# ---------------------------------------------------------------------------
# 2. Kuadrant Instance
# ---------------------------------------------------------------------------
header "Kuadrant Instance"

if kubectl get kuadrant -n "$INSTANCE_NAMESPACE" >/dev/null 2>&1; then
  STATUS=$(kubectl get kuadrant kuadrant -n "$INSTANCE_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" = "True" ]; then
    pass "Kuadrant CR: Ready"
  else
    fail "Kuadrant CR: status=$STATUS (expected True)"
  fi
else
  fail "Kuadrant CR not found in $INSTANCE_NAMESPACE"
fi

# ---------------------------------------------------------------------------
# 3. Authorino Instance
# ---------------------------------------------------------------------------
header "Authorino Instance"

if kubectl get authorino -n "$INSTANCE_NAMESPACE" >/dev/null 2>&1; then
  AUTH_DEPLOY=$(kubectl get deployment authorino -n "$INSTANCE_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${AUTH_DEPLOY:-0}" -ge 1 ]; then
    pass "Authorino deployment: ${AUTH_DEPLOY} replica(s) ready"
  else
    fail "Authorino deployment: not ready"
  fi

  for svc in authorino-authorino-authorization authorino-authorino-oidc authorino-controller-metrics; do
    if kubectl get svc "$svc" -n "$INSTANCE_NAMESPACE" >/dev/null 2>&1; then
      pass "Service: $svc"
    else
      warn "Service: $svc not found"
    fi
  done
else
  fail "Authorino CR not found in $INSTANCE_NAMESPACE"
fi

# ---------------------------------------------------------------------------
# 4. Limitador Instance
# ---------------------------------------------------------------------------
header "Limitador Instance"

if kubectl get limitador -n "$INSTANCE_NAMESPACE" >/dev/null 2>&1; then
  LIM_STATUS=$(kubectl get limitador limitador -n "$INSTANCE_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$LIM_STATUS" = "True" ]; then
    pass "Limitador CR: Ready"
  else
    fail "Limitador CR: status=$LIM_STATUS (expected True)"
  fi

  if kubectl get svc limitador-limitador -n "$INSTANCE_NAMESPACE" >/dev/null 2>&1; then
    pass "Service: limitador-limitador"
  else
    warn "Service: limitador-limitador not found"
  fi
else
  fail "Limitador CR not found in $INSTANCE_NAMESPACE"
fi

# ---------------------------------------------------------------------------
# 5. CRDs
# ---------------------------------------------------------------------------
header "RHCL CRDs"

EXPECTED_CRDS=(
  "kuadrants.kuadrant.io"
  "authpolicies.kuadrant.io"
  "ratelimitpolicies.kuadrant.io"
  "tokenratelimitpolicies.kuadrant.io"
  "tlspolicies.kuadrant.io"
  "dnspolicies.kuadrant.io"
  "dnsrecords.kuadrant.io"
  "dnshealthcheckprobes.kuadrant.io"
  "oidcpolicies.extensions.kuadrant.io"
  "planpolicies.extensions.kuadrant.io"
  "telemetrypolicies.extensions.kuadrant.io"
  "authconfigs.authorino.kuadrant.io"
  "authorinos.operator.authorino.kuadrant.io"
  "limitadors.limitador.kuadrant.io"
)

for crd in "${EXPECTED_CRDS[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "$crd"
  else
    fail "$crd MISSING"
  fi
done

# ---------------------------------------------------------------------------
# 6. RBAC
# ---------------------------------------------------------------------------
header "ClusterRoles"

EXPECTED_ROLES=(
  "kuadrant-operator-manager-role"
  "authorino-operator-manager-role"
  "authorino-manager-role"
  "authorino-manager-k8s-auth-role"
  "limitador-operator-manager-role"
  "limitador-operator-metrics-reader"
)

for role in "${EXPECTED_ROLES[@]}"; do
  if kubectl get clusterrole "$role" >/dev/null 2>&1; then
    pass "$role"
  else
    fail "$role MISSING"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}==========================================${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}WARN: $WARN${NC}  TOTAL: $TOTAL"

if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}RESULT: $FAIL check(s) failed${NC}"
  echo -e "${CYAN}==========================================${NC}"
  exit 1
else
  echo -e "  ${GREEN}RESULT: All checks passed${NC}"
  echo -e "${CYAN}==========================================${NC}"
fi
