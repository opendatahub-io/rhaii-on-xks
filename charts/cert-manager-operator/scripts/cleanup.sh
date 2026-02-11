#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Cleaning up cert-manager operator ==="

# Delete CertManager CR first (before operator, to allow normal cleanup)
echo "Deleting CertManager CR..."
if kubectl get certmanager cluster &>/dev/null; then
  # Try normal delete first
  kubectl delete certmanager cluster --timeout=30s 2>/dev/null || {
    # If stuck, remove finalizers and force delete
    echo "CR stuck, removing finalizers..."
    kubectl patch certmanager cluster --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    kubectl delete certmanager cluster --ignore-not-found
  }
fi

# Delete operand namespace (cert-manager pods created by operator)
echo "Deleting cert-manager namespace..."
kubectl delete namespace cert-manager --ignore-not-found --timeout=60s || {
  # If namespace stuck, remove finalizers from any stuck resources
  echo "Namespace stuck, forcing deletion..."
  kubectl get all -n cert-manager -o name 2>/dev/null | xargs -r kubectl delete -n cert-manager --force --grace-period=0 || true
  kubectl delete namespace cert-manager --ignore-not-found --force --grace-period=0 || true
}

# Destroy helmfile release (operator)
cd "$CHART_DIR"
echo "Destroying helmfile release..."
helmfile destroy || true

# Delete operator namespace
echo "Deleting operator namespace..."
kubectl delete namespace cert-manager-operator --ignore-not-found

# Delete CRDs
echo "Deleting cert-manager CRDs..."
kubectl get crd 2>/dev/null | grep cert-manager | awk '{print $1}' | xargs -r kubectl delete crd --ignore-not-found

echo "Deleting infrastructure CRD stub..."
kubectl delete crd infrastructures.config.openshift.io --ignore-not-found

echo "=== Cleanup complete ==="
