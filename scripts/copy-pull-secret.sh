#!/bin/bash
# Copy pull secret from istio-system to application namespace
# and patch the gateway ServiceAccount
#
# Usage: ./copy-pull-secret.sh <app-namespace>
# Example: ./copy-pull-secret.sh llm-d-pd-aputtur

set -e

NAMESPACE="${1}"

if [ -z "$NAMESPACE" ]; then
  echo "Usage: $0 <app-namespace>"
  echo "Example: $0 llm-d"
  exit 1
fi

echo "=== Copying pull secret to ${NAMESPACE} ==="

# Copy pull secret from istio-system (force replace if exists)
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "'"${NAMESPACE}"'"' | \
  kubectl apply --force -f -

echo "Pull secret copied."

# Find and patch gateway ServiceAccount
GATEWAY_SA=$(kubectl get serviceaccount -n ${NAMESPACE} -o name 2>/dev/null | grep -E "gateway-istio|inference-gateway" | head -1)

if [ -n "$GATEWAY_SA" ]; then
  echo "=== Patching ${GATEWAY_SA} ==="
  kubectl patch ${GATEWAY_SA} -n ${NAMESPACE} \
    -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'
  echo "ServiceAccount patched."

  # Restart gateway pod
  echo "=== Restarting gateway pod ==="
  kubectl delete pod -l gateway.networking.k8s.io/gateway-name -n ${NAMESPACE} --ignore-not-found
  kubectl delete pod -l gateway.istio.io/managed=istio.io-gateway-controller -n ${NAMESPACE} --ignore-not-found
  echo "Gateway pod restarted."
else
  echo "No gateway ServiceAccount found. You may need to patch manually:"
  echo "  kubectl patch serviceaccount <SA_NAME> -n ${NAMESPACE} -p '{\"imagePullSecrets\": [{\"name\": \"redhat-pull-secret\"}]}'"
fi

echo ""
echo "=== Done ==="
