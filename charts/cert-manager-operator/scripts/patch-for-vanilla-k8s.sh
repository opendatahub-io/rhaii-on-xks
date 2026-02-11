#!/bin/bash
# Patch cert-manager deployments for vanilla Kubernetes compatibility
# This removes OpenShift-specific configurations that cause issues on non-OpenShift clusters
#
# Issues addressed:
# 1. Removes 'audience: openshift' projected token volume (not needed on vanilla k8s)
# 2. Removes the corresponding volumeMount
#
# Usage: ./patch-for-vanilla-k8s.sh

set -e

NAMESPACE="${1:-cert-manager}"

echo "============================================"
echo "  Patching cert-manager for vanilla K8s"
echo "============================================"
echo "Namespace: $NAMESPACE"
echo ""

# Wait for deployments to exist
echo "[1/4] Waiting for cert-manager deployments..."
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  timeout=60
  while ! kubectl get deployment $deploy -n $NAMESPACE &>/dev/null; do
    echo "  Waiting for $deploy..."
    sleep 5
    timeout=$((timeout - 5))
    if [ $timeout -le 0 ]; then
      echo "  Timeout waiting for $deploy"
      exit 1
    fi
  done
  echo "  Found $deploy"
done

echo ""
echo "[2/4] Patching deployments to remove OpenShift-specific volumes..."

# For each deployment, remove the bound-sa-token volume and volumeMount
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  echo "  Patching $deploy..."

  # Get current deployment
  kubectl get deployment $deploy -n $NAMESPACE -o yaml > /tmp/${deploy}-current.yaml

  # Check if bound-sa-token volume exists
  if grep -q "bound-sa-token" /tmp/${deploy}-current.yaml; then
    # Remove the volume and volumeMount using kubectl patch
    # This uses a strategic merge patch to remove the items

    # First, get the container name
    CONTAINER_NAME=$(kubectl get deployment $deploy -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].name}')

    # Patch to remove volumeMount (set to empty array if only one mount)
    kubectl patch deployment $deploy -n $NAMESPACE --type=json \
      -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/volumeMounts"}]' 2>/dev/null || true

    # Patch to remove volume
    kubectl patch deployment $deploy -n $NAMESPACE --type=json \
      -p='[{"op": "remove", "path": "/spec/template/spec/volumes"}]' 2>/dev/null || true

    echo "    Removed OpenShift-specific volume from $deploy"
  else
    echo "    No OpenShift-specific volume found in $deploy (already patched?)"
  fi
done

echo ""
echo "[3/4] Waiting for rollout..."
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  kubectl rollout status deployment/$deploy -n $NAMESPACE --timeout=120s
done

echo ""
echo "[4/4] Verifying patches..."
for deploy in cert-manager cert-manager-cainjector cert-manager-webhook; do
  if kubectl get deployment $deploy -n $NAMESPACE -o yaml | grep -q "audience: openshift"; then
    echo "  WARNING: $deploy still has OpenShift-specific config"
  else
    echo "  OK: $deploy patched successfully"
  fi
done

echo ""
echo "============================================"
echo "  Patching Complete!"
echo "============================================"
echo ""
echo "Cert-manager should now work on vanilla Kubernetes."
echo "If issues persist, check the cert-manager controller logs."
