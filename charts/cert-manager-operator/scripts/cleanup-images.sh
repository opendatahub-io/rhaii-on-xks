#!/bin/bash
# Clean up cert-manager Operator images from cluster nodes using Eraser
# Usage: ./scripts/cleanup-images.sh [--install-eraser]
#
# Prerequisites:
#   - Eraser installed (https://eraser-dev.github.io/eraser/)
#   - Or use --install-eraser flag to install it
#
# What gets cleaned:
#   - cert-manager Operator image
#   - cert-manager images (controller, cainjector, webhook, acmesolver)

set -e

INSTALL_ERASER=false
ERASER_NAMESPACE="eraser-system"
IMAGELIST_NAME="cert-manager-cleanup"

# Parse arguments
for arg in "$@"; do
  case $arg in
    --install-eraser)
      INSTALL_ERASER=true
      ;;
  esac
done

echo "============================================"
echo "  cert-manager Operator Image Cleanup"
echo "============================================"
echo ""

# Check/Install Eraser
if ! kubectl get crd imagelists.eraser.sh &>/dev/null; then
  if [ "$INSTALL_ERASER" = true ]; then
    echo "[1/5] Installing Eraser..."
    helm repo add eraser https://eraser-dev.github.io/eraser/charts 2>/dev/null || true
    helm repo update
    helm install eraser eraser/eraser -n $ERASER_NAMESPACE --create-namespace --wait
    echo "Eraser installed"
  else
    echo "ERROR: Eraser is not installed."
    echo "Run with --install-eraser flag or install manually:"
    echo "  helm repo add eraser https://eraser-dev.github.io/eraser/charts"
    echo "  helm install eraser eraser/eraser -n eraser-system --create-namespace"
    exit 1
  fi
else
  echo "[1/5] Eraser is installed"
fi

# Show images to be cleaned
echo ""
echo "[2/5] The following images will be removed from all nodes:"
echo ""
echo "  - registry.redhat.io/cert-manager/cert-manager-operator-rhel9"
echo "  - registry.redhat.io/cert-manager/jetstack-cert-manager-rhel9"
echo "  - registry.redhat.io/cert-manager/jetstack-cert-manager-cainjector-rhel9"
echo "  - registry.redhat.io/cert-manager/jetstack-cert-manager-webhook-rhel9"
echo "  - registry.redhat.io/cert-manager/jetstack-cert-manager-acmesolver-rhel9"
echo ""
read -p "Continue with image cleanup? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Create ImageList
echo ""
echo "[3/5] Creating ImageList..."
kubectl apply -f - <<'EOF'
apiVersion: eraser.sh/v1
kind: ImageList
metadata:
  name: cert-manager-cleanup
spec:
  images:
    # cert-manager Operator
    - registry.redhat.io/cert-manager/cert-manager-operator-rhel9
    # cert-manager images
    - registry.redhat.io/cert-manager/jetstack-cert-manager-rhel9
    - registry.redhat.io/cert-manager/jetstack-cert-manager-cainjector-rhel9
    - registry.redhat.io/cert-manager/jetstack-cert-manager-webhook-rhel9
    - registry.redhat.io/cert-manager/jetstack-cert-manager-acmesolver-rhel9
EOF
echo "ImageList created"

# Wait for eraser to process
echo ""
echo "[4/5] Waiting for Eraser to process ImageList..."

# Wait for ImageJob to be created and complete
for i in $(seq 1 24); do
  # Check ImageList status
  status=$(kubectl get imagelist $IMAGELIST_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [ "$status" = "Completed" ] || [ "$status" = "Failed" ]; then
    echo "  ImageList status: $status"
    break
  fi

  # Show running eraser pods
  pods=$(kubectl get pods -n $ERASER_NAMESPACE --no-headers 2>/dev/null | grep -E "eraser|collector" | wc -l || echo "0")
  echo "  Waiting... (eraser pods: $pods, status: ${status:-pending}) [$i/24]"
  sleep 5
done

# Show results
echo ""
echo "[5/5] Cleanup results:"
echo ""
kubectl get imagelist $IMAGELIST_NAME 2>/dev/null || echo "  ImageList not found"
echo ""
kubectl get imagejob -n $ERASER_NAMESPACE 2>/dev/null || true

# Cleanup ImageList
echo ""
read -p "Delete ImageList? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  kubectl delete imagelist $IMAGELIST_NAME --ignore-not-found
  echo "ImageList deleted"
fi

echo ""
echo "============================================"
echo "  Image Cleanup Complete!"
echo "============================================"
