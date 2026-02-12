#!/bin/bash
# Generate Helm chart from Kustomize overlay with RHOAI image replacements
#
# Usage:
#   ./generate-chart.sh --overlay PATH [OPTIONS]
#
# Options:
#   --overlay PATH              Path to Kustomize overlay (required)
#   --tag TAG                   Image tag for quay.io replacements (default: 3.4.0-ea.1)
#   --branch BRANCH             RHOAI-Build-Config branch for image mappings (default: rhoai-3.4)
#   --skip-image-replacement    Skip image replacement (use original images from overlay)
#   --help                      Show this help message
#
# quay.io images are replaced with registry.redhat.io equivalents using the specified tag.
# registry.redhat.io images are replaced with exact references (SHA digests) from the CSV.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}"
FILES_DIR="${CHART_DIR}/files"

# Defaults
TAG="3.4.0-ea.1"
BRANCH="rhoai-3.4"
KUSTOMIZE_OVERLAY=""
SKIP_IMAGE_REPLACEMENT="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --overlay)
            KUSTOMIZE_OVERLAY="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --skip-image-replacement)
            SKIP_IMAGE_REPLACEMENT="true"
            shift
            ;;
        --help)
            head -16 "$0" | tail -14
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "${KUSTOMIZE_OVERLAY}" ]]; then
    echo "Error: --overlay is required"
    echo "Usage: ./generate-chart.sh --overlay PATH [--tag TAG] [--branch BRANCH]"
    exit 1
fi

if [[ ! -d "${KUSTOMIZE_OVERLAY}" ]]; then
    echo "Error: Overlay path does not exist: ${KUSTOMIZE_OVERLAY}"
    exit 1
fi

CSV_URL="https://raw.githubusercontent.com/red-hat-data-services/RHOAI-Build-Config/refs/heads/${BRANCH}/bundle/manifests/rhods-operator.clusterserviceversion.yaml"

echo "Generating chart..."
echo "  Overlay: ${KUSTOMIZE_OVERLAY}"
echo "  Skip image replacement: ${SKIP_IMAGE_REPLACEMENT}"
if [[ "${SKIP_IMAGE_REPLACEMENT}" == "false" ]]; then
    echo "  Tag (for quay.io): ${TAG}"
    echo "  Branch: ${BRANCH}"
fi
echo ""

rm -rf "${FILES_DIR}"
rm -rf "${CHART_DIR}/crds"

# Ensure directories exist
mkdir -p "${FILES_DIR}"
mkdir -p "${CHART_DIR}/crds"

# Derive kserve repo root from overlay path
# e.g., /path/to/kserve/config/overlays/odh-xks -> /path/to/kserve
KSERVE_ROOT=$(dirname "$(dirname "$(dirname "${KUSTOMIZE_OVERLAY}")")")

# Copy LLM CRDs to crds/ directory (Helm installs these first automatically)
echo "Copying CRDs to crds/ directory..."
CRD_FILES=(
    "config/crd/full/serving.kserve.io_llminferenceservices.yaml"
    "config/crd/full/serving.kserve.io_llminferenceserviceconfigs.yaml"
    "config/crd/external/gateway-inference-extension/gateway-inference-extension.yaml"
)

for crd in "${CRD_FILES[@]}"; do
    src="${KSERVE_ROOT}/${crd}"
    if [[ -f "${src}" ]]; then
        cp "${src}" "${CHART_DIR}/crds/"
        echo "  Copied ${crd}"
    else
        echo "  CRD not found: ${src}"
        exit 1
    fi
done

# Build Kustomize overlay
echo "Building Kustomize overlay..."
TEMP_BUILD=$(mktemp)
kustomize build "${KUSTOMIZE_OVERLAY}" > "${TEMP_BUILD}"

# Filter out CRDs (they're in crds/ directory)
echo "Filtering resources..."
yq eval 'select(.kind != "CustomResourceDefinition")' "${TEMP_BUILD}" > "${FILES_DIR}/resources-all.yaml"
echo "  Filtered out CRDs"

# Extract webhook configurations to separate file (applied after deployment is ready via Helm hooks)
yq eval 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")' \
    "${FILES_DIR}/resources-all.yaml" > "${FILES_DIR}/webhooks.yaml"
WEBHOOK_COUNT=$(grep -cE "^kind: (Validating|Mutating)WebhookConfiguration" "${FILES_DIR}/webhooks.yaml" 2>/dev/null || echo 0)
echo "  Extracted ${WEBHOOK_COUNT} webhook configurations"

# Main resources without webhooks
yq eval 'select(.kind != "ValidatingWebhookConfiguration" and .kind != "MutatingWebhookConfiguration")' \
    "${FILES_DIR}/resources-all.yaml" > "${FILES_DIR}/resources.yaml"

rm -f "${TEMP_BUILD}" "${FILES_DIR}/resources-all.yaml"

if [[ "${SKIP_IMAGE_REPLACEMENT}" == "true" ]]; then
    echo ""
    echo "Skipping image replacement (--skip-image-replacement flag set)"
    echo ""
    echo "Final images:"
    grep -oE '(quay\.io|ghcr\.io|registry\.redhat\.io|docker\.io)[^"'\''[:space:]]+' "${FILES_DIR}/resources.yaml" | sort -u
    echo ""
    echo "Chart generated successfully at: ${CHART_DIR}"
    exit 0
fi

# Step 1: Fetch CSV and extract image mappings
echo "Fetching image mappings from RHOAI-Build-Config (${BRANCH})..."
CSV_CONTENT=$(curl -sfL "${CSV_URL}") || {
    echo "Error: Failed to fetch CSV from ${CSV_URL}"
    exit 1
}

# Build associative array for registry.redhat.io images: component_name -> full_image_ref (with SHA)
declare -A IMAGE_MAP

while IFS= read -r full_image; do
    repo_part=$(echo "${full_image}" | sed -E 's/@sha256:.*//')
    base_name=$(basename "${repo_part}")
    # Strip -rhel* suffix (e.g., -rhel9, -rhel10)
    component=$(echo "${base_name}" | sed -E 's/-rhel[0-9]+$//')
    component_short="${component#odh-}"

    IMAGE_MAP["${component}"]="${full_image}"
    IMAGE_MAP["${component_short}"]="${full_image}"
    IMAGE_MAP["${base_name}"]="${full_image}"
done < <(echo "${CSV_CONTENT}" | grep -oE 'registry\.redhat\.io/[^@"[:space:]]+@sha256:[a-f0-9]+' | sort -u)

echo "  Found ${#IMAGE_MAP[@]} image mappings"

# Step 2: Replace quay.io/opendatahub images with registry.redhat.io + TAG
echo "Replacing quay.io images (using tag: ${TAG})..."

QUAY_IMAGES=$(grep -oE 'quay\.io/opendatahub/[^@:"'\''[:space:]]+' "${FILES_DIR}/resources.yaml" | sort -u)

for quay_repo in ${QUAY_IMAGES}; do
    component=$(basename "${quay_repo}")

    # Find target repo (without SHA) from CSV - match any rhel version
    target_repo=$(echo "${CSV_CONTENT}" | grep -oE "registry\.redhat\.io/rhoai/odh-${component}-rhel[0-9]+" | head -1 || true)

    if [[ -z "${target_repo}" ]]; then
        target_repo=$(echo "${CSV_CONTENT}" | grep -oE "registry\.redhat\.io/rhoai/${component}-rhel[0-9]+" | head -1 || true)
    fi

    if [[ -z "${target_repo}" ]]; then
        target_repo=$(echo "${CSV_CONTENT}" | grep -oE "registry\.redhat\.io/rhaiis/${component}-rhel[0-9]+" | head -1 || true)
    fi

    if [[ -n "${target_repo}" ]]; then
        quay_repo_escaped="${quay_repo//./\\.}"
        sed -i -E "s#${quay_repo_escaped}(:[^\"[:space:]]+|@sha256:[a-f0-9]+)?#${target_repo}:${TAG}#g" "${FILES_DIR}/resources.yaml"
        echo "  ${quay_repo} -> ${target_repo}:${TAG}"
    else
        echo "  WARNING: No mapping found for ${quay_repo}"
    fi
done

# Step 3: Replace registry.redhat.io images with exact CSV versions (SHA)
echo "Replacing registry.redhat.io images (using SHA from CSV)..."

RH_IMAGES=$(grep -oE 'registry\.redhat\.io/[^@:"'\''[:space:]]+' "${FILES_DIR}/resources.yaml" | sort -u)

for rh_repo in ${RH_IMAGES}; do
    base_name=$(basename "${rh_repo}")
    # Strip -rhel* suffix (e.g., -rhel9, -rhel10)
    component=$(echo "${base_name}" | sed -E 's/-rhel[0-9]+$//')

    target_image="${IMAGE_MAP[${component}]:-}"
    if [[ -z "${target_image}" ]]; then
        target_image="${IMAGE_MAP[${base_name}]:-}"
    fi

    if [[ -n "${target_image}" ]]; then
        rh_repo_escaped="${rh_repo//./\\.}"
        sed -i -E "s#${rh_repo_escaped}(:[^\"[:space:]]+|@sha256:[a-f0-9]+)?#${target_image}#g" "${FILES_DIR}/resources.yaml"
        echo "  ${rh_repo} -> ${target_image}"
    fi
done

# Step 4: Verify all images are from registry.redhat.io
echo ""
echo "Final images:"
ALL_IMAGES=$(grep -oE '(quay\.io|ghcr\.io|registry\.redhat\.io|docker\.io)[^"'\''[:space:]]+' "${FILES_DIR}/resources.yaml" | sort -u)
echo "${ALL_IMAGES}"

# Check for non-Red Hat images
NON_RH_IMAGES=$(echo "${ALL_IMAGES}" | grep -v '^registry\.redhat\.io' || true)
if [[ -n "${NON_RH_IMAGES}" ]]; then
    echo ""
    echo "ERROR: Found images not from registry.redhat.io:"
    echo "${NON_RH_IMAGES}"
    exit 1
fi

echo ""
echo "Verification passed: All images are from registry.redhat.io"
echo "Chart generated successfully at: ${CHART_DIR}"