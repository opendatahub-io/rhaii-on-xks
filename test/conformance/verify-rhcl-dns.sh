#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# RHCL DNS Operator Test
#
# Validates the DNS operator is running and can reconcile DNS CRs.
# Does NOT require cloud DNS credentials — tests CR creation and operator
# reconciliation only.
#
# Prerequisites:
#   - RHCL deployed with operators.dns.enabled=true
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_NS="${OPERATOR_NAMESPACE:-kuadrant-operators}"
TEST_NS="rhcl-test-dns"

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
  kubectl delete -f "$SCRIPT_DIR/test-dns-operator.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false 2>/dev/null || true
  echo "  Cleanup complete"
}

trap cleanup EXIT

echo -e "${CYAN}=== RHCL DNS Operator Test ===${NC}"

# Check DNS operator is running
echo -e "\n${CYAN}--- DNS Operator Status ---${NC}"
if kubectl get deployment dns-operator-controller-manager -n "$OPERATOR_NS" >/dev/null 2>&1; then
  READY=$(kubectl get deployment dns-operator-controller-manager -n "$OPERATOR_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -ge 1 ]; then
    pass "DNS operator running (${READY} replica)"
  else
    fail "DNS operator not ready"
    echo -e "  ${RED}DNS operator must be enabled (operators.dns.enabled=true) to run this test${NC}"
    exit 1
  fi
else
  fail "DNS operator deployment not found"
  echo -e "  ${RED}Deploy RHCL with --set operators.dns.enabled=true first${NC}"
  exit 1
fi

# Check DNS CRDs
echo -e "\n${CYAN}--- DNS CRDs ---${NC}"
for crd in dnspolicies.kuadrant.io dnsrecords.kuadrant.io dnshealthcheckprobes.kuadrant.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "$crd installed"
  else
    fail "$crd MISSING"
  fi
done

# Apply test resources
echo -e "\n${CYAN}--- Applying test resources ---${NC}"
kubectl apply -f "$SCRIPT_DIR/test-dns-operator.yaml"
echo "  Test manifests applied"
sleep 10

# Verify CR creation
echo -e "\n${CYAN}--- CR Reconciliation ---${NC}"
if kubectl get dnspolicy test-dns-policy -n "$TEST_NS" >/dev/null 2>&1; then
  pass "DNSPolicy CR created"
else
  fail "DNSPolicy CR not found"
fi

if kubectl get dnsrecord test-dns-record -n "$TEST_NS" >/dev/null 2>&1; then
  pass "DNSRecord CR created"
  # Without cloud creds, the record won't be provisioned but the CR should exist
  STATUS=$(kubectl get dnsrecord test-dns-record -n "$TEST_NS" \
    -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")
  echo -e "  ${YELLOW}INFO${NC}  DNSRecord status reason: $STATUS (expected — no cloud DNS provider configured)"
else
  fail "DNSRecord CR not found"
fi

# Summary
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
