#!/bin/bash
# Update RHCL Helm chart from a new RHCL operator bundle version
#
# Usage:
#   ./update-bundle.sh [version]
#
# Examples:
#   ./update-bundle.sh v1.2.0
#   ./update-bundle.sh v1.3.0
#
# This script:
#   1. Pulls the RHCL operator bundle from registry.redhat.io
#   2. Extracts CRDs, operator deployments, RBAC, and component images
#   3. Updates charts/rhcl/crds/ with the new CRDs
#   4. Prints the new image digests for values.yaml update

set -euo pipefail

VERSION="${1:-v1.2.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE_IMAGE="registry.redhat.io/rhcl-1/rhcl-operator-bundle:${VERSION}"

echo "============================================"
echo "  Updating RHCL Helm Chart"
echo "============================================"
echo "Version: $VERSION"
echo "Bundle:  $BUNDLE_IMAGE"
echo ""

# Check for auth
if [ -f ~/.config/containers/auth.json ]; then
  AUTH_FILE=~/.config/containers/auth.json
elif [ -f "${XDG_RUNTIME_DIR:-/tmp}/containers/auth.json" ]; then
  AUTH_FILE="${XDG_RUNTIME_DIR}/containers/auth.json"
else
  echo "ERROR: Not logged in to registry.redhat.io"
  echo "Run: podman login registry.redhat.io"
  exit 1
fi

AUTH_ARG="-v ${AUTH_FILE}:/root/.docker/config.json:z"

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Step 1: Extract manifests using olm-extractor
echo "[1/4] Extracting manifests from bundle..."
podman run --rm --pull=always $AUTH_ARG \
  quay.io/lburgazzoli/olm-extractor:main \
  run "$BUNDLE_IMAGE" \
  -n kuadrant-operators \
  --watch-namespace="" \
  --exclude '.kind == "ConsoleCLIDownload"' \
  --exclude '.kind == "ConsolePlugin"' \
  --exclude '.kind == "Route"' \
  --exclude '.kind == "SecurityContextConstraints"' \
  --exclude '.kind == "ConsoleYAMLSample"' \
  2>/dev/null | grep -v "^time=" > "$TMP_DIR/manifests.yaml"

echo "Extracted $(wc -l < "$TMP_DIR/manifests.yaml") lines"

# Step 2: Extract CRDs
echo "[2/4] Extracting CRDs..."
echo "Clearing existing CRDs..."
rm -f "$CHART_DIR/crds/"*.yaml
export TMP_DIR CHART_DIR
python3 << 'PYEOF'
import yaml
import os

tmp_dir = os.environ['TMP_DIR']
chart_dir = os.environ['CHART_DIR']
crds_dir = f'{chart_dir}/crds'

os.makedirs(crds_dir, exist_ok=True)

with open(f'{tmp_dir}/manifests.yaml') as f:
    content = f.read()

crd_count = 0
for doc in yaml.safe_load_all(content):
    if doc is None:
        continue
    kind = doc.get('kind', '')
    name = doc.get('metadata', {}).get('name', '')

    if kind == 'CustomResourceDefinition':
        # Strip runtime metadata
        meta = doc.get('metadata', {})
        for key in ['creationTimestamp', 'generation', 'resourceVersion', 'uid', 'selfLink', 'managedFields']:
            meta.pop(key, None)
        annotations = meta.get('annotations', {})
        for key in list(annotations.keys()):
            if 'olm' in key or 'operatorframework' in key or 'operators.coreos.com' in key:
                del annotations[key]
        if not annotations:
            meta.pop('annotations', None)
        doc.pop('status', None)

        filename = f'{crds_dir}/{name}.yaml'
        with open(filename, 'w') as out:
            yaml.dump(doc, out, default_flow_style=False, sort_keys=False)
        crd_count += 1
        print(f'  CRD: {name}')

print(f'\nExtracted {crd_count} CRDs')
PYEOF

# Step 3: Extract image references
echo ""
echo "[3/4] Extracting image references..."
python3 << 'PYEOF'
import yaml
import os

tmp_dir = os.environ['TMP_DIR']

with open(f'{tmp_dir}/manifests.yaml') as f:
    content = f.read()

images = set()
for doc in yaml.safe_load_all(content):
    if doc is None:
        continue
    kind = doc.get('kind', '')

    if kind == 'Deployment':
        name = doc.get('metadata', {}).get('name', '')
        containers = doc.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
        for c in containers:
            img = c.get('image', '')
            if img:
                print(f'  Operator: {name}')
                print(f'    image: {img}')
            for env in c.get('env', []):
                if env.get('name', '').startswith('RELATED_IMAGE'):
                    print(f'    {env["name"]}: {env["value"]}')
PYEOF

# Step 4: Summary
echo ""
echo "[4/4] Summary"
echo "============================================"
echo "CRDs updated in: $CHART_DIR/crds/"
echo ""
echo "Next steps:"
echo "  1. Review the extracted CRDs in crds/"
echo "  2. Update image digests in values.yaml"
echo "  3. Run: helm lint $CHART_DIR"
echo "  4. Test: helmfile apply"
echo "============================================"
