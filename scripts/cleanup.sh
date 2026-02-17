#!/bin/bash
# Cleanup script for rhaii-on-xks
# Runs helmfile destroy and cleans up presync/template resources

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -y, --yes         Skip confirmation prompt"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Confirmation
if [ "$SKIP_CONFIRM" = false ]; then
    echo ""
    warn "This will remove all infrastructure components!"
    echo ""
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Clear helmfile cache
log "Clearing helmfile cache..."
rm -rf ~/.cache/helmfile/git 2>/dev/null || true

# Run helmfile destroy
log "Running helmfile destroy..."
cd "$(dirname "$0")/.." || { error "Failed to cd to repo root"; exit 1; }
helmfile destroy 2>/dev/null || true

# Remove finalizers from stuck resources
log "Removing finalizers from stuck resources..."
kubectl get istiorevision -A -o name 2>/dev/null | while read rev; do
    kubectl patch $rev -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done
kubectl get istio -A -o name 2>/dev/null | while read ist; do
    kubectl patch $ist -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done
kubectl patch infrastructure cluster -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl patch certmanager cluster -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true

# Delete template-created CRs (with timeout)
log "Cleaning up template CRs..."
timeout 10 kubectl delete istio --all -A --ignore-not-found 2>/dev/null || true
timeout 10 kubectl delete istiorevision --all -A --ignore-not-found 2>/dev/null || true
timeout 10 kubectl delete certmanager cluster --ignore-not-found 2>/dev/null || true
timeout 10 kubectl delete infrastructure cluster --ignore-not-found 2>/dev/null || true

# Delete cert-manager webhook secret (forces CA regeneration on redeploy)
log "Deleting cert-manager webhook secret..."
kubectl delete secret cert-manager-webhook-ca -n cert-manager --ignore-not-found 2>/dev/null || true

# Delete CRDs installed by this repo (Helm does not remove CRDs on uninstall)
log "Cleaning up CRDs..."
CRDS=$(kubectl get crd -o name 2>/dev/null || true)
# Sail Operator / Istio CRDs
echo "$CRDS" | grep -E "sailoperator\.io|\.istio\.io" | while read -r crd; do
    kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done
# cert-manager CRDs
echo "$CRDS" | grep -E "\.cert-manager\.io" | while read -r crd; do
    kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done
# LWS CRDs
echo "$CRDS" | grep -E "leaderworkerset\.x-k8s\.io" | while read -r crd; do
    kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done
# Operator CRDs (exact names to avoid matching other OpenShift operators)
kubectl delete crd certmanagers.operator.openshift.io leaderworkersetoperators.operator.openshift.io istiocsrs.operator.openshift.io --ignore-not-found 2>/dev/null || true
# Gateway API CRDs and Inference Extension CRDs (InferencePool, InferenceModel)
# Matches both inference.networking.k8s.io (v1) and inference.networking.x-k8s.io (v1alpha2)
echo "$CRDS" | grep -E "gateway\.networking\.k8s\.io|inference\.networking\.k8s\.io|inference\.networking\.x-k8s\.io" | while read -r crd; do
    kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done
# KServe CRDs
echo "$CRDS" | grep -E "serving\.kserve\.io" | while read -r crd; do
    kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done
# Infrastructure stub CRD
kubectl delete crd infrastructures.config.openshift.io --ignore-not-found 2>/dev/null || true

# Kuadrant CRDs (Kuadrant/RHCL)
echo "$CRDS" | grep -E "kuadrant\.io|limitador\.kuadrant\.io|authorino\.kuadrant\.io" | while read -r crd; do
    kubectl delete "$crd" --ignore-not-found 2>/dev/null || true
done

# Clean up presync-created namespaces
log "Cleaning up namespaces..."
kubectl delete namespace cert-manager --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace cert-manager-operator --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace istio-system --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace kuadrant-system --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace openshift-lws-operator --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace opendatahub --ignore-not-found --wait=false 2>/dev/null || true

log "=== Cleanup Complete ==="
