#!/bin/bash
# Update Helm chart with new bundle version
# Usage: ./update-bundle.sh [version]
# Examples:
#   ./update-bundle.sh 1.0
#   ./update-bundle.sh 1.1

set -e

VERSION="${1:-1.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Bundle image from registry.redhat.io
BUNDLE_IMAGE="registry.redhat.io/leader-worker-set/lws-operator-bundle:${VERSION}"

echo "============================================"
echo "  Updating LWS Operator Helm Chart"
echo "============================================"
echo "Version: $VERSION"
echo "Bundle: $BUNDLE_IMAGE"
echo ""

# Check for auth (persistent location first, then session)
if [ -f ~/.config/containers/auth.json ]; then
  echo "Using auth: ~/.config/containers/auth.json"
elif [ -f "${XDG_RUNTIME_DIR}/containers/auth.json" ]; then
  echo "Using auth: ${XDG_RUNTIME_DIR}/containers/auth.json"
else
  echo "ERROR: Not logged in to registry.redhat.io"
  echo "Run: podman login registry.redhat.io"
  echo "Then: cp ~/pull-secret.txt ~/.config/containers/auth.json"
  exit 1
fi

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Pull and extract bundle
echo "[1/4] Pulling bundle image..."
podman pull "$BUNDLE_IMAGE"

echo "[2/4] Extracting bundle contents..."
CONTAINER_ID=$(podman create "$BUNDLE_IMAGE")
podman cp "$CONTAINER_ID:/manifests" "$TMP_DIR/"
podman cp "$CONTAINER_ID:/metadata" "$TMP_DIR/"
podman rm "$CONTAINER_ID"

# Extract manifests using olm-extractor
echo "[3/4] Processing manifests with olm-extractor..."
podman run --rm --pull=always \
  -v "$TMP_DIR:/bundle:z" \
  quay.io/lburgazzoli/olm-extractor:main run \
  -n openshift-lws-operator \
  /bundle 2>/dev/null | grep -v "^time=" > "$TMP_DIR/manifests.yaml"

echo "Extracted $(wc -l < "$TMP_DIR/manifests.yaml") lines"

# Clear existing templates and CRDs (except custom/preserved files)
# Preserved custom templates:
#   - pull-secret.yaml: Registry pull secret for Red Hat images
#   - rolebinding-kube-system-auth-reader.yaml: Required for non-OpenShift clusters
# Preserved CRDs:
#   - customresourcedefinition-servicemonitors-monitoring-coreos-com.yaml: Required by LWS operator on non-OpenShift
echo "[4/4] Splitting into CRDs and templates..."
find "$CHART_DIR/crds" -name "*.yaml" \
  ! -name "customresourcedefinition-servicemonitors-monitoring-coreos-com.yaml" \
  -delete 2>/dev/null || true
find "$CHART_DIR/templates" -name "*.yaml" \
  ! -name "pull-secret.yaml" \
  ! -name "rolebinding-kube-system-auth-reader.yaml" \
  -delete 2>/dev/null || true

# Split manifests
python3 << PYEOF
import yaml
import os

input_file = '$TMP_DIR/manifests.yaml'
crds_dir = '$CHART_DIR/crds'  # Helm SSA crds/ directory
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
            # CRDs installed by Helm with SSA
            with open(filepath, 'w') as out:
                out.write(doc.strip() + '\n')
        elif kind == 'Namespace':
            # Skip namespace - created by helmfile
            continue
        else:
            filepath = os.path.join(templates_dir, filename)
            other_count += 1
            # Templatize namespace
            content = doc.strip()
            content = content.replace('namespace: openshift-lws-operator', 'namespace: {{ .Values.namespace }}')

            # Add imagePullSecrets to ServiceAccount
            if kind == 'ServiceAccount':
                content += '''
imagePullSecrets:
  - name: {{ .Values.pullSecret.name }}'''

            with open(filepath, 'w') as out:
                out.write(content + '\n')

    except Exception as e:
        print(f"Error: {e}")

print(f"Created {crd_count} CRDs")
print(f"Created {other_count} templates")
PYEOF

# Update bundle.version in values.yaml
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
