#!/usr/bin/env bash
#
# Strip runtime metadata from CRD YAML files so they can be committed cleanly.
# Removes: creationTimestamp, generation, resourceVersion, uid, OLM annotations, status blocks.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRD_DIR="${1:-$SCRIPT_DIR/../crds}"

if [ ! -d "$CRD_DIR" ]; then
  echo "ERROR: CRD directory not found: $CRD_DIR"
  exit 1
fi

echo "Cleaning CRD files in: $CRD_DIR"

for f in "$CRD_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  echo "  Cleaning: $(basename "$f")"

  # Remove runtime metadata fields
  sed -i.bak \
    -e '/^  creationTimestamp:/d' \
    -e '/^  generation:/d' \
    -e '/^  resourceVersion:/d' \
    -e '/^  uid:/d' \
    -e '/^  selfLink:/d' \
    "$f"

  # Remove OLM-specific annotations
  sed -i.bak \
    -e '/olm\.operatorframework\.io/d' \
    -e '/operatorframework\.io/d' \
    -e '/operators\.coreos\.com/d' \
    "$f"

  # Remove the status block (everything from top-level "status:" to end of file)
  # CRDs exported from a live cluster include status with acceptedNames, conditions, storedVersions
  python3 - "$f" <<'PYEOF'
import sys
filepath = sys.argv[1]
lines = open(filepath).readlines()
out = []
in_status = False
for line in lines:
    if line.rstrip() == 'status:':
        in_status = True
        continue
    if in_status and (line[0:1] == ' ' or line.strip() == ''):
        continue
    in_status = False
    out.append(line)
open(filepath, 'w').writelines(out)
PYEOF

  rm -f "$f.bak"
done

echo "CRD cleanup complete!"
