#!/usr/bin/env bash
#
# mirror-images.sh - Mirror all RHOAI-on-xKS images to a target registry
#
# Usage:
#   ./scripts/mirror-images.sh <TARGET_REGISTRY>
#
# Examples:
#   ./scripts/mirror-images.sh jfrog.customer.com/redhat-mirror
#   ./scripts/mirror-images.sh myacr.azurecr.io/rhaii
#
# Prerequisites:
#   - skopeo installed
#   - Authenticated to source registries:
#       podman login registry.redhat.io
#       podman login ghcr.io  (if using dev chart)
#   - Authenticated to target registry:
#       podman login <target>

set -euo pipefail

TARGET_REGISTRY="${1:?Usage: $0 <TARGET_REGISTRY>}"

# =============================================================================
# IMAGE LIST
# =============================================================================
# All images used by rhaii-on-xks infrastructure and inference components.
# Update this list when chart versions change.

IMAGES=(
  # --- cert-manager-operator ---
  "registry.redhat.io/cert-manager/cert-manager-operator-rhel9@sha256:7c91cda4ad5b62f1f1bad8466fa94f54d0c5ab82296f2e8e22bf87d996f6c40e"
  "registry.redhat.io/cert-manager/jetstack-cert-manager-rhel9@sha256:76fe0671c410cb063225ecfa51c30f86634518a48757ee69bd2662f0643b5f40"
  "registry.redhat.io/cert-manager/jetstack-cert-manager-acmesolver-rhel9@sha256:80d9e21cee7578e80ef80628436c5ce0d7af3118d161a196c31b8b1825e04dc7"
  "registry.redhat.io/cert-manager/cert-manager-istio-csr-rhel9@sha256:9573d74bd2b926ec94af76f813e6358f14c5b2f4e0eedab7c1ff1070b7279a5c"

  # --- sail-operator ---
  "registry.redhat.io/openshift-service-mesh/istio-rhel9-operator@sha256:656511cdb0683ff7e3336d4f41a672b4063b665e9e6e34d5370640103fd49365"
  "registry.redhat.io/openshift-service-mesh/istio-pilot-rhel9@sha256:0850242436e88f7d82f0f2126de064c7e0f09844f31d8ff0f53dc8d3908075d9"
  "registry.redhat.io/openshift-service-mesh/istio-proxyv2-rhel9@sha256:7d15cebf9b62f3f235c0eab5158ac8ff2fda86a1d193490dc94c301402c99da8"

  # --- lws-operator ---
  "registry.redhat.io/leader-worker-set/lws-rhel9-operator@sha256:c202bfa15626262ff22682b64ac57539d28dd35f5960c490f5afea75cef34309"
  "registry.redhat.io/leader-worker-set/lws-rhel9@sha256:affb303b1173c273231bb50fef07310b0e220d2f08bfc0aa5912d0825e3e0d4f"

  # --- KServe / Inference (from OCI chart) ---
  "ghcr.io/opendatahub-io/rhaii-on-xks/kserve-controller:e6b5db0@sha256:8837c5d3da4a4df80f613576183c65a108d83ad1a0d1e92bc90c399d246489ee"
  "ghcr.io/opendatahub-io/rhaii-on-xks/kserve-storage-initializer:e6b5db0@sha256:b305264fe2211be2c6063500c4c11da79e8357af4b34dd8567b0d8e8dea7e1d4"
  "ghcr.io/opendatahub-io/rhaii-on-xks/llm-d-inference-scheduler:e6b5db0@sha256:43e8b8edc158f31535c8b23d77629f8cde111cc762a8f4ee5f2f884470566211"
  "ghcr.io/opendatahub-io/rhaii-on-xks/llm-d-routing-sidecar:e6b5db0@sha256:92638d3658e5d3c05f4dcc5a303ac5c8924d081d9f6b80b7a92c83e2d24cb702"
  "ghcr.io/opendatahub-io/rhaii-on-xks/kserve-router:e6b5db0@sha256:687d51fecc4b2c00e2555905fd069e0dd1ff4e2477b56b6ae1fc9f4aa8355e34"
  "ghcr.io/opendatahub-io/rhaii-on-xks/kserve-agent:e6b5db0@sha256:7076de2b4af9fec62665049dac0d6fed5cc6134a6ee7f15e3f1f0629cd2ffe04"
  "ghcr.io/opendatahub-io/rhaii-on-xks/odh-kube-auth-proxy:e6b5db0@sha256:dcb09fbabd8811f0956ef612a0c9ddd5236804b9bd6548a0647d2b531c9d01b3"
  "registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:fc68d623d1bfc36c8cb2fe4a71f19c8578cfb420ce8ce07b20a02c1ee0be0cf3"
)

echo "============================================"
echo "  RHOAI-on-xKS Image Mirror"
echo "============================================"
echo "Target: ${TARGET_REGISTRY}"
echo "Images: ${#IMAGES[@]}"
echo ""

FAILED=0
SUCCEEDED=0

for image in "${IMAGES[@]}"; do
  # Extract registry and path
  registry="${image%%/*}"
  path="${image#*/}"
  target="${TARGET_REGISTRY}/${path}"

  echo "Mirroring: ${image}"
  echo "      To: ${target}"

  if skopeo copy --all "docker://${image}" "docker://${target}" 2>&1; then
    SUCCEEDED=$((SUCCEEDED + 1))
    echo "      OK"
  else
    FAILED=$((FAILED + 1))
    echo "      FAILED"
  fi
  echo ""
done

echo "============================================"
echo "  Results: ${SUCCEEDED} succeeded, ${FAILED} failed"
echo "============================================"

if [[ ${FAILED} -gt 0 ]]; then
  echo "WARNING: Some images failed to mirror. Check output above."
  exit 1
fi

echo ""
echo "Next steps:"
echo "  1. Deploy with:  make deploy-all"
echo "  2. Patch images: ./scripts/patch-images.sh ${TARGET_REGISTRY}"
