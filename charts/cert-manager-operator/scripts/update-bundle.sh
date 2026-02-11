#!/bin/bash
# Update Helm chart with new bundle version
# Usage: ./update-bundle.sh [version]
# Examples:
#   ./update-bundle.sh v1.15.2
#   ./update-bundle.sh v1.18.0

set -e

VERSION="${1:-v1.15.2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Bundle image from registry.redhat.io
BUNDLE_IMAGE="registry.redhat.io/cert-manager/cert-manager-operator-bundle:${VERSION}"

echo "============================================"
echo "  Updating cert-manager Operator Helm Chart"
echo "============================================"
echo "Version: $VERSION"
echo "Bundle: $BUNDLE_IMAGE"
echo ""

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

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Extract manifests using olm-extractor
echo "[1/3] Extracting manifests..."
podman run --rm --pull=always $AUTH_ARG \
  quay.io/lburgazzoli/olm-extractor:main \
  run "$BUNDLE_IMAGE" \
  -n cert-manager-operator \
  --watch-namespace="" \
  --exclude '.kind == "ConsoleCLIDownload"' \
  --exclude '.kind == "ConsolePlugin"' \
  --exclude '.kind == "Route"' \
  --exclude '.kind == "SecurityContextConstraints"' \
  --exclude '.kind == "ConsoleYAMLSample"' \
  2>/dev/null | grep -v "^time=" > "$TMP_DIR/manifests.yaml"

echo "Extracted $(wc -l < "$TMP_DIR/manifests.yaml") lines"

# Clear existing templates and CRDs (except custom/stub CRDs)
echo "[2/3] Clearing old manifests..."
find "$CHART_DIR/crds" -name "*.yaml" \
  ! -name "customresourcedefinition-infrastructures-config-openshift-io.yaml" \
  -delete 2>/dev/null || true
find "$CHART_DIR/templates" -name "*.yaml" \
  ! -name "pull-secret.yaml" \
  ! -name "certmanager-cr.yaml" \
  ! -name "serviceaccounts-cert-manager.yaml" \
  -delete 2>/dev/null || true

# Split manifests into CRDs and templates
echo "[3/3] Splitting into CRDs and templates..."

export TMP_DIR CHART_DIR
python3 << 'PYEOF'
import yaml
import os

tmp_dir = os.environ.get('TMP_DIR', '/tmp')
chart_dir = os.environ.get('CHART_DIR', '.')

input_file = f'{tmp_dir}/manifests.yaml'
crds_dir = f'{chart_dir}/crds'  # Helm SSA crds/ directory
templates_dir = f'{chart_dir}/templates'

os.makedirs(crds_dir, exist_ok=True)
os.makedirs(templates_dir, exist_ok=True)

with open(input_file, 'r') as f:
    content = f.read()

docs = content.split('\n---\n')
crd_count = 0
other_count = 0
skipped = []

# OpenShift-specific resources to skip
skip_kinds = [
    'ConsoleCLIDownload',
    'ConsolePlugin',
    'ConsoleYAMLSample',
    'Route',
    'SecurityContextConstraints',
    'ImageContentSourcePolicy',
]

for doc in docs:
    if not doc.strip():
        continue
    try:
        obj = yaml.safe_load(doc)
        if not obj:
            continue
        kind = obj.get('kind', 'unknown')
        name = obj.get('metadata', {}).get('name', 'unknown')

        # Skip OpenShift-specific resources
        if kind in skip_kinds:
            skipped.append(f"{kind}/{name}")
            continue

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

            # Templatize namespace references
            content = doc.strip()
            content = content.replace('namespace: cert-manager-operator', 'namespace: {{ .Values.operatorNamespace }}')
            content = content.replace('namespace: cert-manager', 'namespace: {{ .Values.operandNamespace }}')

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
if skipped:
    print(f"Skipped {len(skipped)} OpenShift-specific resources:")
    for s in skipped:
        print(f"  - {s}")
PYEOF

echo ""
echo "============================================"
echo "  Update Complete!"
echo "============================================"
echo ""
echo "Chart updated at: $CHART_DIR"
echo "New version: $VERSION"
echo ""
echo "Next steps:"
echo "  1. Review extracted manifests"
echo "  2. Create values.yaml and helmfile.yaml.gotmpl"
echo "  3. Test with: helmfile apply"
