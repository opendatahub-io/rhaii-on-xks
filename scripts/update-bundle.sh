#!/bin/bash
# Update Helm chart with new bundle version
# Usage: ./update-bundle.sh [version] [source]
# Examples:
#   ./update-bundle.sh 3.2.1 redhat
#   ./update-bundle.sh sha256:abc123 konflux

set -e

VERSION="${1:-3.2.1}"
SOURCE="${2:-redhat}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "============================================"
echo "  Updating Sail Operator Helm Chart"
echo "============================================"
echo "Source: $SOURCE"
echo "Version: $VERSION"
echo ""

# Set bundle image and auth
if [ "$SOURCE" == "redhat" ]; then
  BUNDLE_IMAGE="registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle:${VERSION}"
  # Check for auth (persistent location first, then session)
  if [ -f ~/.config/containers/auth.json ]; then
    AUTH_FILE=~/.config/containers/auth.json
  elif [ -f "${XDG_RUNTIME_DIR}/containers/auth.json" ]; then
    AUTH_FILE="${XDG_RUNTIME_DIR}/containers/auth.json"
  else
    echo "ERROR: Not logged in to registry.redhat.io"
    echo "Run: podman login registry.redhat.io"
    echo "Then: cp ~/pull-secret.txt ~/.config/containers/auth.json"
    exit 1
  fi
  AUTH_ARG="-v ${AUTH_FILE}:/root/.docker/config.json:z"
else
  BUNDLE_IMAGE="quay.io/redhat-user-workloads/service-mesh-tenant/ossm-3-2-bundle@${VERSION}"
  AUTH_ARG=""
fi

echo "Bundle: $BUNDLE_IMAGE"
echo ""

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Extract manifests
echo "[1/3] Extracting manifests..."
podman run --rm --pull=always $AUTH_ARG \
  quay.io/lburgazzoli/olm-extractor:main \
  run "$BUNDLE_IMAGE" \
  -n istio-system \
  --exclude '.kind == "ConsoleCLIDownload"' \
  2>/dev/null | grep -v "^time=" > "$TMP_DIR/manifests.yaml"

echo "Extracted $(wc -l < "$TMP_DIR/manifests.yaml") lines"

# Clear existing templates and CRDs (except custom templates)
echo "[2/3] Clearing old manifests..."
find "$CHART_DIR/manifests-crds" -name "*.yaml" -delete 2>/dev/null || true
find "$CHART_DIR/templates" -name "*.yaml" \
  ! -name "pull-secret.yaml" \
  ! -name "istio-cr.yaml" \
  ! -name "post-install-hook.yaml" \
  -delete 2>/dev/null || true
# Note: istiod ServiceAccount is in manifests-presync/ (not templates/) with operator's Helm annotations

# Split manifests
echo "[3/3] Splitting into CRDs and templates..."
python3 << PYEOF
import yaml
import os

input_file = '$TMP_DIR/manifests.yaml'
crds_dir = '$CHART_DIR/manifests-crds'
templates_dir = '$CHART_DIR/templates'

os.makedirs(crds_dir, exist_ok=True)
os.makedirs(templates_dir, exist_ok=True)

with open(input_file, 'r') as f:
    content = f.read()

docs = content.split('\n---\n')
crd_count = 0
other_count = 0

for doc in docs:
    if not doc.strip():
        continue
    try:
        obj = yaml.safe_load(doc)
        if not obj:
            continue
        kind = obj.get('kind', 'unknown')
        name = obj.get('metadata', {}).get('name', 'unknown')
        filename = f"{kind.lower()}-{name.replace('.', '-')[:50]}.yaml"
        
        if kind == 'CustomResourceDefinition':
            filepath = os.path.join(crds_dir, filename)
            crd_count += 1
            # CRDs stay as-is
            with open(filepath, 'w') as out:
                out.write(doc.strip() + '\n')
        elif kind == 'Namespace':
            # Skip namespace - created in manifests-presync/
            continue
        elif kind == 'ServiceAccount' and name == 'istiod':
            # Skip istiod SA - managed in manifests-presync/ with operator's Helm annotations
            continue
        else:
            filepath = os.path.join(templates_dir, filename)
            other_count += 1
            # Templatize namespace
            content = doc.strip()
            content = content.replace('namespace: istio-system', 'namespace: {{ .Values.namespace }}')
            
            # Add imagePullSecrets to ServiceAccount
            if kind == 'ServiceAccount':
                content += '''
{{- if eq .Values.bundle.source "redhat" }}
imagePullSecrets:
  - name: {{ .Values.pullSecret.name }}
{{- end }}'''
            
            with open(filepath, 'w') as out:
                out.write(content + '\n')
                
    except Exception as e:
        print(f"Error: {e}")

print(f"Created {crd_count} CRDs")
print(f"Created {other_count} templates")
PYEOF

# Update bundle.version in values.yaml (only the line after "bundle:")
sed -i '/^bundle:/,/^[a-z]/{s/  version: ".*"/  version: "'"$VERSION"'"/}' "$CHART_DIR/values.yaml"

echo ""
echo "============================================"
echo "  Update Complete!"
echo "============================================"
echo ""
echo "Chart updated at: $CHART_DIR"
echo "New version: $VERSION"
echo ""
echo "To install:"
echo "  1. Ensure you're logged in: podman login registry.redhat.io"
echo "  2. Run: cd $CHART_DIR && helmfile apply"
