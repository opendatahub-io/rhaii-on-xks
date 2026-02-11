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
cd "$(dirname "$0")/.."
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

# Clean up presync-created namespaces
log "Cleaning up namespaces..."
kubectl delete namespace cert-manager --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace cert-manager-operator --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace istio-system --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace openshift-lws-operator --ignore-not-found --wait=false 2>/dev/null || true

log "=== Cleanup Complete ==="
