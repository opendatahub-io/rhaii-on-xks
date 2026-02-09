#!/bin/bash
#
# LLM-D Deployment Conformance Tests
# Validates LLM-D installation based on official deployment guides
#
# Usage:
#   # Upstream llm-d (Helm-based, default)
#   ./verify-llm-d-deployment.sh --profile inference-scheduling
#   ./verify-llm-d-deployment.sh --upstream --profile pd-disaggregation --namespace llm-d-pd
#
#   # KServe LLMInferenceService (CRD-based)
#   ./verify-llm-d-deployment.sh --kserve --namespace llm-d-aputtur
#   ./verify-llm-d-deployment.sh --kserve --profile kserve-pd --namespace llm-d-pd
#
#   ./verify-llm-d-deployment.sh --list-profiles
#
# Deployment modes:
#   --upstream (default): Helm-based llm-d deployment via guides
#   --kserve:             KServe LLMInferenceService CRD-based deployment
#
# Profiles match official llm-d guides:
#   https://github.com/llm-d/llm-d/tree/main/guides
#
# To add a new profile:
#   1. Create a function: profile_<name>_config
#   2. Add to AVAILABLE_PROFILES array
#   3. Optionally add custom validation: profile_<name>_validate
#

set -euo pipefail

# =============================================================================
# DEPLOYMENT MODE: kserve (CRD) or upstream (Helm)
# =============================================================================

DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-kserve}"

# =============================================================================
# AVAILABLE PROFILES (matching official llm-d guides)
# =============================================================================

# Upstream llm-d profiles (Helm-based)
UPSTREAM_PROFILES=(
    "inference-scheduling"
    "pd-disaggregation"
    "wide-ep-lws"
    "precise-prefix-cache-aware"
    "tiered-prefix-cache"
    "simulated-accelerators"
    "quickstart"
)

# KServe LLMInferenceService profiles
KSERVE_PROFILES=(
    "kserve-basic"
    "kserve-gpu"
    "kserve-pd"
    "kserve-scheduler"
)

# Combined list (set dynamically based on mode - default to kserve)
AVAILABLE_PROFILES=("${KSERVE_PROFILES[@]}")

# =============================================================================
# PROFILE CONFIGURATIONS
# Based on official llm-d guides: https://github.com/llm-d/llm-d/tree/main/guides
# =============================================================================

# -----------------------------------------------------------------------------
# Profile: inference-scheduling
# Well-Lit Path: Intelligent Inference Scheduling
# https://github.com/llm-d/llm-d/tree/main/guides/inference-scheduling
# -----------------------------------------------------------------------------
profile_inference_scheduling_config() {
    PROFILE_DESCRIPTION="Intelligent Inference Scheduling (EPP + ModelService)"

    # Expected helm releases pattern: infra-*, gaie-*, ms-*
    # Expected pods: *-epp, *-modelservice-decode, *-inference-gateway-*
    EXPECTED_POD_PATTERNS="epp modelservice-decode"

    # Expected deployments (partial match)
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice-decode inference-gateway"

    # Expected services
    EXPECTED_SERVICE_PATTERNS="epp inference-gateway"

    # Expected CRDs
    EXPECTED_CRDS="inferencepool"

    # Inference service pattern (auto-detect)
    INFERENCE_SERVICE_PATTERN="inference-gateway"

    # Features to validate
    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_GATEWAY="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_GPU="true"
}

# Custom validation for inference-scheduling profile
profile_inference_scheduling_validate() {
    log_info "Running inference-scheduling specific validations..."

    # Check EPP pod
    check_pod_pattern "epp" "EPP (Endpoint Picker/Proxy)"

    # Check modelservice decode pods
    check_pod_pattern "modelservice-decode" "ModelService Decode"

    # Check InferencePool CRD and resources
    check_inferencepool

    # Check HTTPRoute - gateway is only required if using Gateway API
    local route_count
    route_count=$($KUBECTL get httproute -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [[ "$route_count" -gt 0 ]]; then
        log_pass "Found $route_count HTTPRoute(s) - using Gateway API"
        # Gateway required when using HTTPRoutes
        check_pod_pattern "gateway" "Inference Gateway"
    else
        log_info "No HTTPRoute found - using standalone mode (gateway not required)"
    fi
}

# -----------------------------------------------------------------------------
# Profile: pd-disaggregation
# Well-Lit Path: Prefill/Decode Disaggregation
# https://github.com/llm-d/llm-d/tree/main/guides/pd-disaggregation
# -----------------------------------------------------------------------------
profile_pd_disaggregation_config() {
    PROFILE_DESCRIPTION="P/D Disaggregation (Prefill + Decode Workers)"

    EXPECTED_POD_PATTERNS="epp modelservice-decode modelservice-prefill"
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice-decode modelservice-prefill inference-gateway"
    EXPECTED_SERVICE_PATTERNS="epp inference-gateway"
    EXPECTED_CRDS="inferencepool"

    INFERENCE_SERVICE_PATTERN="inference-gateway"

    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_GATEWAY="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_GPU="true"
    VALIDATE_PD="true"
}

# Custom validation for pd-disaggregation profile
profile_pd_disaggregation_validate() {
    log_info "Running pd-disaggregation specific validations..."

    # Check EPP pod
    check_pod_pattern "epp" "EPP"

    # Check prefill pods
    local prefill_count
    prefill_count=$(check_pod_pattern "modelservice-prefill" "ModelService Prefill")

    # Check decode pods
    local decode_count
    decode_count=$(check_pod_pattern "modelservice-decode" "ModelService Decode")

    # Check for deployments that exist but are scaled to 0
    check_deployment_pattern "modelservice-prefill" "ModelService Prefill Deployment"
    check_deployment_pattern "modelservice-decode" "ModelService Decode Deployment"

    # Validate P/D ratio
    if [[ -n "$prefill_count" ]] && [[ -n "$decode_count" ]]; then
        log_info "P/D ratio: $prefill_count prefill : $decode_count decode"
    fi

    # Check InferencePool
    check_inferencepool

    # Check HTTPRoute - gateway is only required if using Gateway API
    local route_count
    route_count=$($KUBECTL get httproute -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [[ "$route_count" -gt 0 ]]; then
        log_pass "Found $route_count HTTPRoute(s) - using Gateway API"
        check_pod_pattern "gateway" "Inference Gateway"
    else
        log_info "No HTTPRoute found - using standalone mode (gateway not required)"
    fi

    # Check for NIXL/KV transfer configuration (RDMA)
    log_info "Checking for RDMA/NIXL configuration..."
    local nixl_config
    nixl_config=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].env[?(@.name=="VLLM_NIXL_SIDE_CHANNEL_HOST")].value}' 2>/dev/null || echo "")
    if [[ -n "$nixl_config" ]]; then
        log_pass "NIXL KV transfer configured"
    else
        log_info "NIXL environment variable not found (may use different config)"
    fi
}

# -----------------------------------------------------------------------------
# Profile: wide-ep-lws
# Well-Lit Path: Wide Expert Parallelism with LeaderWorkerSet
# https://github.com/llm-d/llm-d/tree/main/guides/wide-ep-lws
# -----------------------------------------------------------------------------
profile_wide_ep_lws_config() {
    PROFILE_DESCRIPTION="Wide Expert Parallelism (EP/DP) with LeaderWorkerSet"

    EXPECTED_POD_PATTERNS="decode prefill"
    EXPECTED_DEPLOYMENT_PATTERNS=""  # Uses LeaderWorkerSet, not Deployment
    EXPECTED_SERVICE_PATTERNS="epp"
    EXPECTED_CRDS="inferencepool leaderworkersets"

    INFERENCE_SERVICE_PATTERN="inference-gateway"

    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_GATEWAY="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_LWS="true"
    VALIDATE_GPU="true"
}

# Custom validation for wide-ep-lws profile
profile_wide_ep_lws_validate() {
    log_info "Running wide-ep-lws specific validations..."

    # Check LeaderWorkerSet CRD
    if $KUBECTL get crd leaderworkersets.leaderworkerset.x-k8s.io &> /dev/null; then
        log_pass "LeaderWorkerSet CRD is installed"

        # List LeaderWorkerSets
        local lws_count
        lws_count=$($KUBECTL get leaderworkerset -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
        if [[ "$lws_count" -gt 0 ]]; then
            log_pass "Found $lws_count LeaderWorkerSet resource(s)"
            $KUBECTL get leaderworkerset -n "$LLMD_NAMESPACE" 2>/dev/null
        else
            log_warn "No LeaderWorkerSet resources found"
        fi
    else
        log_fail "LeaderWorkerSet CRD not installed"
    fi

    # Check for wide parallelism (DP > 1)
    local pod_count
    pod_count=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    log_info "Total pods in namespace: $pod_count"

    # Check decode and prefill workers
    check_pod_pattern "decode" "Decode Workers"
    check_pod_pattern "prefill" "Prefill Workers"

    # Check InferencePool
    check_inferencepool

    # Check for RDMA networking
    log_info "Checking for RDMA/InfiniBand configuration..."
    local rdma_config
    rdma_config=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].resources.limits}' 2>/dev/null | grep -i "rdma\|infiniband" || echo "")
    if [[ -n "$rdma_config" ]]; then
        log_pass "RDMA resources configured"
    else
        log_info "RDMA resources not explicitly found in pod specs"
    fi
}

# -----------------------------------------------------------------------------
# Profile: precise-prefix-cache-aware
# Precise Prefix Cache Aware Routing
# https://github.com/llm-d/llm-d/tree/main/guides/precise-prefix-cache-aware
# -----------------------------------------------------------------------------
profile_precise_prefix_cache_aware_config() {
    PROFILE_DESCRIPTION="Precise Prefix Cache Aware Routing"

    EXPECTED_POD_PATTERNS="epp modelservice"
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice"
    EXPECTED_SERVICE_PATTERNS="epp"
    EXPECTED_CRDS="inferencepool"

    INFERENCE_SERVICE_PATTERN="inference-gateway"

    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_PREFIX_CACHE="true"
    VALIDATE_GPU="true"
}

# Custom validation for precise-prefix-cache-aware profile
profile_precise_prefix_cache_aware_validate() {
    log_info "Running precise-prefix-cache-aware specific validations..."

    # Check EPP
    check_pod_pattern "epp" "EPP"

    # Check modelservice
    check_pod_pattern "modelservice" "ModelService"

    # Check InferencePool
    check_inferencepool

    # Check for prefix cache scorer configuration
    log_info "Checking for prefix cache scorer configuration..."

    # Check EPP configmap or pod env for scorer config
    local scorer_config
    scorer_config=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -l app.kubernetes.io/component=epp -o jsonpath='{.items[0].spec.containers[0].args}' 2>/dev/null || echo "")
    if echo "$scorer_config" | grep -qi "prefix-cache\|scorer"; then
        log_pass "Prefix cache scorer appears to be configured"
    else
        log_info "Could not confirm prefix cache scorer from pod args"
    fi

    # Check for vLLM prefix cache metrics
    log_info "Check vLLM metrics for prefix cache hit rate:"
    echo "  curl <model-server-ip>:8000/metrics | grep prefix_cache"
}

# -----------------------------------------------------------------------------
# Profile: tiered-prefix-cache
# Tiered Prefix Cache (CPU offload)
# https://github.com/llm-d/llm-d/tree/main/guides/tiered-prefix-cache
# -----------------------------------------------------------------------------
profile_tiered_prefix_cache_config() {
    PROFILE_DESCRIPTION="Tiered Prefix Cache (CPU Memory Offload)"

    EXPECTED_POD_PATTERNS="epp modelservice"
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice"
    EXPECTED_SERVICE_PATTERNS="epp"
    EXPECTED_CRDS="inferencepool"

    INFERENCE_SERVICE_PATTERN="inference-gateway"

    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_TIERED_CACHE="true"
    VALIDATE_GPU="true"
}

# Custom validation for tiered-prefix-cache profile
profile_tiered_prefix_cache_validate() {
    log_info "Running tiered-prefix-cache specific validations..."

    # Check EPP
    check_pod_pattern "epp" "EPP"

    # Check modelservice
    check_pod_pattern "modelservice" "ModelService"

    # Check for tiered cache vLLM args
    log_info "Checking for tiered prefix cache configuration..."
    local vllm_args
    vllm_args=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].args}' 2>/dev/null || echo "")

    if echo "$vllm_args" | grep -qi "kv-cache-dtype\|cpu-offload"; then
        log_pass "Tiered cache configuration detected in vLLM args"
    else
        log_info "Could not confirm tiered cache from vLLM args"
    fi

    # Check CPU memory allocation for tiered cache
    local cpu_memory
    cpu_memory=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].resources.requests.memory}' 2>/dev/null | head -1 || echo "")
    log_info "Pod memory requests: $cpu_memory"
}

# -----------------------------------------------------------------------------
# Profile: simulated-accelerators
# Simulated Model Servers (no GPU required)
# https://github.com/llm-d/llm-d/tree/main/guides/simulated-accelerators
# -----------------------------------------------------------------------------
profile_simulated_accelerators_config() {
    PROFILE_DESCRIPTION="Simulated Accelerators (Testing without GPUs)"

    EXPECTED_POD_PATTERNS="epp modelservice"
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice"
    EXPECTED_SERVICE_PATTERNS="epp"
    EXPECTED_CRDS="inferencepool"

    INFERENCE_SERVICE_PATTERN="inference-gateway"

    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_GPU="false"  # Simulated - no GPU required
}

# Custom validation for simulated-accelerators profile
profile_simulated_accelerators_validate() {
    log_info "Running simulated-accelerators specific validations..."

    # Check EPP
    check_pod_pattern "epp" "EPP"

    # Check modelservice (simulated)
    check_pod_pattern "modelservice" "ModelService (Simulated)"

    # Verify no GPU resources required
    local gpu_requests
    gpu_requests=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].resources.requests.nvidia\.com/gpu}' 2>/dev/null | tr -d ' ' || echo "")
    if [[ -z "$gpu_requests" ]] || [[ "$gpu_requests" == "0" ]]; then
        log_pass "No GPU resources requested (simulated mode)"
    else
        log_info "GPU resources found: $gpu_requests (may be mixed deployment)"
    fi
}

# -----------------------------------------------------------------------------
# Profile: quickstart
# Basic quickstart deployment
# https://github.com/llm-d/llm-d/tree/main/guides/QUICKSTART.md
# -----------------------------------------------------------------------------
profile_quickstart_config() {
    PROFILE_DESCRIPTION="Quickstart (Basic Deployment)"

    EXPECTED_POD_PATTERNS="epp modelservice"
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice"
    EXPECTED_SERVICE_PATTERNS="epp"
    EXPECTED_CRDS="inferencepool"

    INFERENCE_SERVICE_PATTERN="inference-gateway"

    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_GPU="true"
}

profile_quickstart_validate() {
    log_info "Running quickstart validations..."
    check_pod_pattern "epp" "EPP"
    check_pod_pattern "modelservice" "ModelService"
    check_inferencepool
}

# =============================================================================
# KSERVE LLMINFERENCESERVICE PROFILES
# =============================================================================

# -----------------------------------------------------------------------------
# Profile: kserve-basic
# Basic KServe LLMInferenceService deployment (no scheduler)
# -----------------------------------------------------------------------------
profile_kserve_basic_config() {
    PROFILE_DESCRIPTION="KServe LLMInferenceService - Basic (no scheduler)"

    EXPECTED_POD_PATTERNS="kserve"
    EXPECTED_DEPLOYMENT_PATTERNS="kserve"
    EXPECTED_SERVICE_PATTERNS="kserve-workload-svc"
    EXPECTED_CRDS="llminferenceservices"

    INFERENCE_SERVICE_PATTERN="kserve-workload-svc"

    VALIDATE_LLMISVC="true"
    VALIDATE_HTTPROUTE="true"
    VALIDATE_GPU="true"
}

profile_kserve_basic_validate() {
    log_info "Running kserve-basic validations..."

    # Check LLMInferenceService CRD
    check_llminferenceservice_crd

    # Check LLMInferenceService resources
    check_llminferenceservice_resources

    # Check vLLM pods
    check_pod_pattern "kserve" "vLLM Pod"

    # Check HTTPRoute
    check_kserve_httproute
}

# -----------------------------------------------------------------------------
# Profile: kserve-gpu
# KServe LLMInferenceService with GPU and scheduler
# -----------------------------------------------------------------------------
profile_kserve_gpu_config() {
    PROFILE_DESCRIPTION="KServe LLMInferenceService - GPU with Scheduler"

    EXPECTED_POD_PATTERNS="kserve inference-scheduler"
    EXPECTED_DEPLOYMENT_PATTERNS="kserve"
    EXPECTED_SERVICE_PATTERNS="kserve-workload-svc"
    EXPECTED_CRDS="llminferenceservices inferencepool"

    INFERENCE_SERVICE_PATTERN="kserve-workload-svc"

    VALIDATE_LLMISVC="true"
    VALIDATE_SCHEDULER="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_HTTPROUTE="true"
    VALIDATE_GPU="true"
}

profile_kserve_gpu_validate() {
    log_info "Running kserve-gpu validations..."

    # Check LLMInferenceService CRD
    check_llminferenceservice_crd

    # Check LLMInferenceService resources
    check_llminferenceservice_resources

    # Check vLLM pods
    check_pod_pattern "kserve" "vLLM Pod"

    # Check scheduler pods (EPP)
    check_pod_pattern "inference-scheduler\|epp\|router-scheduler" "Scheduler/EPP"

    # Check InferencePool
    check_inferencepool

    # Check HTTPRoute
    check_kserve_httproute

    # Check GPU allocation
    check_gpu_allocation
}

# -----------------------------------------------------------------------------
# Profile: kserve-pd
# KServe LLMInferenceService with Prefill/Decode disaggregation
# -----------------------------------------------------------------------------
profile_kserve_pd_config() {
    PROFILE_DESCRIPTION="KServe LLMInferenceService - Prefill/Decode Disaggregation"

    EXPECTED_POD_PATTERNS="kserve prefill decode"
    EXPECTED_DEPLOYMENT_PATTERNS="kserve"
    EXPECTED_SERVICE_PATTERNS="kserve-workload-svc"
    EXPECTED_CRDS="llminferenceservices inferencepool"

    INFERENCE_SERVICE_PATTERN="kserve-workload-svc"

    VALIDATE_LLMISVC="true"
    VALIDATE_SCHEDULER="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_HTTPROUTE="true"
    VALIDATE_PD="true"
    VALIDATE_GPU="true"
}

profile_kserve_pd_validate() {
    log_info "Running kserve-pd validations..."

    # Check LLMInferenceService CRD
    check_llminferenceservice_crd

    # Check LLMInferenceService resources
    check_llminferenceservice_resources

    # Check prefill pods
    local prefill_count
    prefill_count=$(check_pod_pattern "prefill" "Prefill Pod")

    # Check decode pods
    local decode_count
    decode_count=$(check_pod_pattern "decode\|kserve" "Decode Pod")

    # Validate P/D configuration
    if [[ -n "$prefill_count" ]] && [[ "$prefill_count" != "0" ]]; then
        log_pass "Prefill/Decode disaggregation detected"
        log_info "P/D ratio: $prefill_count prefill : $decode_count decode"
    else
        log_warn "Prefill pods not found - may be single-pool deployment"
    fi

    # Check for NIXL/RDMA configuration
    check_kserve_kv_transfer

    # Check InferencePool
    check_inferencepool

    # Check HTTPRoute
    check_kserve_httproute
}

# -----------------------------------------------------------------------------
# Profile: kserve-scheduler
# KServe LLMInferenceService with custom scheduler configuration
# -----------------------------------------------------------------------------
profile_kserve_scheduler_config() {
    PROFILE_DESCRIPTION="KServe LLMInferenceService - Custom Scheduler"

    EXPECTED_POD_PATTERNS="kserve inference-scheduler"
    EXPECTED_DEPLOYMENT_PATTERNS="kserve"
    EXPECTED_SERVICE_PATTERNS="kserve-workload-svc"
    EXPECTED_CRDS="llminferenceservices inferencepool"

    INFERENCE_SERVICE_PATTERN="kserve-workload-svc"

    VALIDATE_LLMISVC="true"
    VALIDATE_SCHEDULER="true"
    VALIDATE_INFERENCEPOOL="true"
    VALIDATE_HTTPROUTE="true"
    VALIDATE_GPU="true"
}

profile_kserve_scheduler_validate() {
    log_info "Running kserve-scheduler validations..."

    # Check LLMInferenceService CRD
    check_llminferenceservice_crd

    # Check LLMInferenceService resources
    check_llminferenceservice_resources

    # Check vLLM pods
    check_pod_pattern "kserve" "vLLM Pod"

    # Check scheduler pods
    check_pod_pattern "inference-scheduler\|epp\|router-scheduler" "Scheduler/EPP"

    # Check scheduler configuration
    check_kserve_scheduler_config

    # Check InferencePool
    check_inferencepool

    # Check HTTPRoute
    check_kserve_httproute
}

# =============================================================================
# GLOBAL CONFIGURATION
# =============================================================================

LLMD_NAMESPACE="${LLMD_NAMESPACE:-llm-d}"
KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-opendatahub}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
SELECTED_PROFILE="${PROFILE:-}"
MODEL_NAME="${MODEL_NAME:-}"
TIMEOUT="${TIMEOUT:-120}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"
SKIP_INFERENCE_TEST="${SKIP_INFERENCE_TEST:-false}"
SKIP_MONITORING_TEST="${SKIP_MONITORING_TEST:-false}"
GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"

# =============================================================================
# PARSE COMMAND LINE ARGUMENTS
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --kserve)
            DEPLOYMENT_MODE="kserve"
            AVAILABLE_PROFILES=("${KSERVE_PROFILES[@]}")
            shift
            ;;
        --upstream)
            DEPLOYMENT_MODE="upstream"
            AVAILABLE_PROFILES=("${UPSTREAM_PROFILES[@]}")
            shift
            ;;
        --profile|-p)
            SELECTED_PROFILE="$2"
            shift 2
            ;;
        --namespace|-n)
            LLMD_NAMESPACE="$2"
            shift 2
            ;;
        --kserve-namespace)
            KSERVE_NAMESPACE="$2"
            shift 2
            ;;
        --timeout|-t)
            TIMEOUT="$2"
            shift 2
            ;;
        --model|-m)
            MODEL_NAME="$2"
            shift 2
            ;;
        --skip-inference)
            SKIP_INFERENCE_TEST="true"
            shift
            ;;
        --skip-monitoring)
            SKIP_MONITORING_TEST="true"
            shift
            ;;
        --monitoring-namespace)
            MONITORING_NAMESPACE="$2"
            shift 2
            ;;
        --list-profiles)
            echo "Available profiles:"
            echo ""
            echo "Upstream llm-d (Helm-based) - use with --upstream (default):"
            for profile in "${UPSTREAM_PROFILES[@]}"; do
                if declare -f "profile_${profile//-/_}_config" > /dev/null; then
                    "profile_${profile//-/_}_config" 2>/dev/null
                    printf "  %-30s %s\n" "$profile" "$PROFILE_DESCRIPTION"
                fi
            done
            echo ""
            echo "KServe LLMInferenceService (CRD-based) - use with --kserve:"
            for profile in "${KSERVE_PROFILES[@]}"; do
                if declare -f "profile_${profile//-/_}_config" > /dev/null; then
                    "profile_${profile//-/_}_config" 2>/dev/null
                    printf "  %-30s %s\n" "$profile" "$PROFILE_DESCRIPTION"
                fi
            done
            echo ""
            echo "Upstream guides: https://github.com/llm-d/llm-d/tree/main/guides"
            echo "KServe docs:     https://github.com/opendatahub-io/kserve/tree/release-v0.15/docs/samples/llmisvc"
            exit 0
            ;;
        --help|-h)
            cat <<EOF
LLM-D Conformance Tests

Usage: $0 [OPTIONS]

Deployment Modes:
  --upstream                  Upstream llm-d (Helm-based) - default
  --kserve                    KServe LLMInferenceService (CRD-based)

Options:
  -p, --profile NAME          Deployment profile to validate
                              Upstream default: inference-scheduling
                              KServe default: kserve-basic
  -n, --namespace NAME        Deployment namespace (default: llm-d)
  --kserve-namespace NS       KServe controller namespace (default: opendatahub)
  -t, --timeout SECONDS       Timeout for wait operations (default: 120)
  -m, --model NAME            Model name for inference test (default: auto-detect)
  --skip-inference            Skip the inference test
  --skip-monitoring           Skip the monitoring stack validation
  --monitoring-namespace NS   Monitoring stack namespace (default: monitoring)
  --list-profiles             List available profiles for both modes
  -h, --help                  Show this help message

Examples:
  # Upstream llm-d (Helm-based)
  $0 --upstream --profile inference-scheduling --namespace llm-d
  $0 --profile pd-disaggregation -n llm-d-pd

  # KServe LLMInferenceService
  $0 --kserve --namespace llm-d-aputtur
  $0 --kserve --profile kserve-pd -n llm-d-pd

Profiles:
  Upstream: inference-scheduling, pd-disaggregation, wide-ep-lws, etc.
  KServe:   kserve-basic, kserve-gpu, kserve-pd, kserve-scheduler

Documentation:
  Upstream: https://github.com/llm-d/llm-d/tree/main/guides
  KServe:   https://github.com/opendatahub-io/kserve/tree/release-v0.15/docs/samples/llmisvc
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Set default profile based on mode
if [[ -z "$SELECTED_PROFILE" ]]; then
    if [[ "$DEPLOYMENT_MODE" == "kserve" ]]; then
        SELECTED_PROFILE="kserve-basic"
    else
        SELECTED_PROFILE="inference-scheduling"
    fi
fi

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0
KUBECTL=""
CLOUD_PLATFORM=""
MANAGED_PROMETHEUS=""

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILED++)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARNINGS++)); }

log_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

load_profile() {
    local profile="$1"
    local profile_func="profile_${profile//-/_}_config"

    if ! declare -f "$profile_func" > /dev/null; then
        echo "Error: Unknown profile '$profile'"
        if [[ "$DEPLOYMENT_MODE" == "kserve" ]]; then
            echo "Available KServe profiles: ${KSERVE_PROFILES[*]}"
        else
            echo "Available upstream profiles: ${UPSTREAM_PROFILES[*]}"
        fi
        echo "Run with --list-profiles to see descriptions"
        exit 1
    fi

    "$profile_func"
    log_info "Loaded profile: $profile"
    log_info "Description: $PROFILE_DESCRIPTION"
}

# Check for pods matching a pattern
check_pod_pattern() {
    local pattern="$1"
    local description="$2"

    local count
    count=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -i "$pattern" | wc -l)

    if [[ "$count" -gt 0 ]]; then
        local running
        running=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -i "$pattern" | grep -c "Running" || echo "0")
        if [[ "$running" -eq "$count" ]]; then
            log_pass "$description: $count pod(s) running"
        else
            log_warn "$description: $running/$count pods running"
        fi
        echo "$count"
    else
        log_fail "$description: No pods found matching '$pattern'"
        echo "0"
    fi
}

# Check for deployments matching a pattern (including scaled-to-0)
check_deployment_pattern() {
    local pattern="$1"
    local description="$2"

    local deployments
    deployments=$($KUBECTL get deployments -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -i "$pattern" || echo "")

    if [[ -n "$deployments" ]]; then
        local name ready replicas
        while read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            if [[ "$ready" == "0/0" ]]; then
                log_warn "$description: $name exists but scaled to 0"
            else
                log_pass "$description: $name ($ready ready)"
            fi
        done <<< "$deployments"
    else
        log_info "$description: No deployment found matching '$pattern'"
    fi
}

# Check InferencePool CRD and resources
check_inferencepool() {
    log_info "Checking InferencePool..."

    # Check CRD exists
    local crd_found=false
    for crd in "inferencepools.inference.networking.x-k8s.io" "inferencepool"; do
        if $KUBECTL get crd "$crd" &> /dev/null 2>&1; then
            crd_found=true
            log_pass "InferencePool CRD installed"
            break
        fi
    done

    if [[ "$crd_found" == "false" ]]; then
        log_fail "InferencePool CRD not found"
        return 1
    fi

    # Check for InferencePool resources
    local pool_count
    pool_count=$($KUBECTL get inferencepool -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [[ "$pool_count" -gt 0 ]]; then
        log_pass "Found $pool_count InferencePool resource(s)"
        $KUBECTL get inferencepool -n "$LLMD_NAMESPACE" 2>/dev/null
    else
        log_warn "No InferencePool resources in namespace"
    fi
}

# Check HTTPRoute
check_httproute() {
    log_info "Checking HTTPRoute..."

    local route_count
    route_count=$($KUBECTL get httproute -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [[ "$route_count" -gt 0 ]]; then
        log_pass "Found $route_count HTTPRoute(s)"
    else
        log_info "No HTTPRoute found (may use standalone mode)"
    fi
}

# =============================================================================
# KSERVE-SPECIFIC HELPER FUNCTIONS
# =============================================================================

# Check LLMInferenceService CRD is installed
check_llminferenceservice_crd() {
    log_info "Checking LLMInferenceService CRD..."

    if $KUBECTL get crd llminferenceservices.serving.kserve.io &> /dev/null; then
        log_pass "LLMInferenceService CRD installed"
        return 0
    else
        log_fail "LLMInferenceService CRD not found"
        log_info "  Hint: Deploy KServe with odh-xks overlay:"
        log_info "  kustomize build config/overlays/odh-xks | kubectl apply --server-side -f -"
        return 1
    fi
}

# Check LLMInferenceServiceConfig templates exist
check_llminferenceserviceconfig() {
    log_info "Checking LLMInferenceServiceConfig templates..."

    local kserve_ns="${KSERVE_NAMESPACE:-opendatahub}"
    local config_count
    config_count=$($KUBECTL get llminferenceserviceconfig -n "$kserve_ns" --no-headers 2>/dev/null | wc -l)

    if [[ "$config_count" -gt 0 ]]; then
        log_pass "Found $config_count LLMInferenceServiceConfig template(s) in $kserve_ns"
        $KUBECTL get llminferenceserviceconfig -n "$kserve_ns" 2>/dev/null | head -10
        return 0
    else
        log_fail "No LLMInferenceServiceConfig templates found in $kserve_ns"
        log_info "  Hint: Re-apply odh-xks overlay to create templates"
        return 1
    fi
}

# Check LLMInferenceService resources in namespace
check_llminferenceservice_resources() {
    log_info "Checking LLMInferenceService resources..."

    local llmisvc_count
    llmisvc_count=$($KUBECTL get llminferenceservice -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)

    if [[ "$llmisvc_count" -gt 0 ]]; then
        log_pass "Found $llmisvc_count LLMInferenceService resource(s)"

        # Show status
        $KUBECTL get llminferenceservice -n "$LLMD_NAMESPACE" 2>/dev/null

        # Check each one's status
        local ready_count=0
        local not_ready=()
        while IFS= read -r line; do
            local name ready
            name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $3}')
            if [[ "$ready" == "True" ]]; then
                ((ready_count++))
            else
                not_ready+=("$name")
            fi
        done < <($KUBECTL get llminferenceservice -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null)

        if [[ "$ready_count" -eq "$llmisvc_count" ]]; then
            log_pass "All $llmisvc_count LLMInferenceService(s) are Ready"
        else
            log_warn "$ready_count/$llmisvc_count LLMInferenceService(s) Ready"
            for name in "${not_ready[@]}"; do
                log_info "  Not ready: $name"
                # Show conditions
                $KUBECTL get llminferenceservice "$name" -n "$LLMD_NAMESPACE" -o jsonpath='{.status.conditions[?(@.status=="False")].message}' 2>/dev/null | head -1
                echo ""
            done
        fi
        return 0
    else
        log_fail "No LLMInferenceService resources found in $LLMD_NAMESPACE"
        return 1
    fi
}

# Check KServe HTTPRoute
check_kserve_httproute() {
    log_info "Checking KServe HTTPRoute..."

    local route_count
    route_count=$($KUBECTL get httproute -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)

    if [[ "$route_count" -gt 0 ]]; then
        log_pass "Found $route_count HTTPRoute(s)"
        $KUBECTL get httproute -n "$LLMD_NAMESPACE" 2>/dev/null

        # Check parent gateway
        local gateway
        gateway=$($KUBECTL get httproute -n "$LLMD_NAMESPACE" -o jsonpath='{.items[0].spec.parentRefs[0].name}' 2>/dev/null || echo "")
        local gateway_ns
        gateway_ns=$($KUBECTL get httproute -n "$LLMD_NAMESPACE" -o jsonpath='{.items[0].spec.parentRefs[0].namespace}' 2>/dev/null || echo "")

        if [[ -n "$gateway" ]]; then
            log_info "Parent Gateway: $gateway_ns/$gateway"

            # Check gateway status
            if $KUBECTL get gateway "$gateway" -n "$gateway_ns" &>/dev/null; then
                local programmed
                programmed=$($KUBECTL get gateway "$gateway" -n "$gateway_ns" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
                if [[ "$programmed" == "True" ]]; then
                    log_pass "Gateway $gateway is Programmed"
                else
                    log_warn "Gateway $gateway is not Programmed"
                fi
            else
                log_fail "Gateway $gateway_ns/$gateway not found"
            fi
        fi
        return 0
    else
        log_info "No HTTPRoute found in $LLMD_NAMESPACE"
        return 0
    fi
}

# Check KServe KV transfer configuration (RDMA/NIXL)
check_kserve_kv_transfer() {
    log_info "Checking KV transfer configuration..."

    # Check for NIXL configuration
    local nixl_config
    nixl_config=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].env[?(@.name=="VLLM_NIXL_SIDE_CHANNEL_HOST")].value}' 2>/dev/null || echo "")

    if [[ -n "$nixl_config" ]]; then
        log_pass "NIXL KV transfer configured"
    else
        # Check for NixlConnector in VLLM_ADDITIONAL_ARGS
        local nixl_args
        nixl_args=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}' 2>/dev/null | grep -i "NixlConnector" || echo "")
        if [[ -n "$nixl_args" ]]; then
            log_pass "NixlConnector KV transfer configured in vLLM args"
        else
            log_info "NIXL/KV transfer not configured (standard mode)"
        fi
    fi

    # Check for RDMA resources
    local rdma_resources
    rdma_resources=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].resources.limits}' 2>/dev/null | grep -i "rdma" || echo "")
    if [[ -n "$rdma_resources" ]]; then
        log_pass "RDMA resources allocated"
    fi
}

# Check KServe scheduler configuration
check_kserve_scheduler_config() {
    log_info "Checking scheduler configuration..."

    # Find scheduler pods
    local scheduler_pods
    scheduler_pods=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -E "inference-scheduler|epp|router-scheduler" | wc -l)

    if [[ "$scheduler_pods" -gt 0 ]]; then
        log_pass "Found $scheduler_pods scheduler pod(s)"

        # Check scheduler args for config
        local scheduler_config
        scheduler_config=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -l app.kubernetes.io/component=inference-scheduler -o jsonpath='{.items[0].spec.containers[0].args}' 2>/dev/null || echo "")

        if echo "$scheduler_config" | grep -q "config-text"; then
            log_pass "Custom scheduler config detected"
        else
            log_info "Using default scheduler config"
        fi
    else
        log_info "No scheduler pods found (may use k8s service load balancing)"
    fi
}

# Check GPU allocation for KServe pods
check_gpu_allocation() {
    log_info "Checking GPU allocation..."

    local gpu_pods
    gpu_pods=$($KUBECTL get pods -n "$LLMD_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -v "^$" | grep -v " $" || echo "")

    if [[ -n "$gpu_pods" ]]; then
        local gpu_count
        gpu_count=$(echo "$gpu_pods" | wc -l)
        log_pass "Found $gpu_count pod(s) with GPU allocation"
        echo "$gpu_pods" | while read -r line; do
            log_info "  $line"
        done
    else
        log_warn "No pods with GPU allocation found"
    fi
}

# Check KServe controller
check_kserve_controller() {
    log_info "Checking KServe controller..."

    local kserve_ns="${KSERVE_NAMESPACE:-opendatahub}"

    # Check controller pod
    local controller_pods
    controller_pods=$($KUBECTL get pods -n "$kserve_ns" -l control-plane=kserve-controller-manager --no-headers 2>/dev/null | wc -l)

    if [[ "$controller_pods" -gt 0 ]]; then
        local running
        running=$($KUBECTL get pods -n "$kserve_ns" -l control-plane=kserve-controller-manager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        if [[ "$running" -gt 0 ]]; then
            log_pass "KServe controller: $running pod(s) running in $kserve_ns"
        else
            log_fail "KServe controller pods not running"
            $KUBECTL get pods -n "$kserve_ns" -l control-plane=kserve-controller-manager
        fi
    else
        log_fail "KServe controller not found in $kserve_ns"
        return 1
    fi
}

# Check Gateway with CA bundle (for KServe mTLS)
check_kserve_gateway() {
    log_info "Checking KServe Gateway..."

    local kserve_ns="${KSERVE_NAMESPACE:-opendatahub}"
    local gateway_name="${GATEWAY_NAME:-inference-gateway}"

    # Check gateway exists
    if ! $KUBECTL get gateway "$gateway_name" -n "$kserve_ns" &>/dev/null; then
        log_fail "Gateway $gateway_name not found in $kserve_ns"
        log_info "  Hint: Run ./scripts/setup-gateway.sh to create the gateway"
        return 1
    fi

    # Check gateway is programmed
    local programmed
    programmed=$($KUBECTL get gateway "$gateway_name" -n "$kserve_ns" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")

    if [[ "$programmed" == "True" ]]; then
        log_pass "Gateway $gateway_name is Programmed"

        # Get external address and detect protocol
        local address protocol port curl_tls_opt=""
        address=$($KUBECTL get gateway "$gateway_name" -n "$kserve_ns" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
        protocol=$($KUBECTL get gateway "$gateway_name" -n "$kserve_ns" -o jsonpath='{.spec.listeners[0].protocol}' 2>/dev/null || echo "HTTP")
        port=$($KUBECTL get gateway "$gateway_name" -n "$kserve_ns" -o jsonpath='{.spec.listeners[0].port}' 2>/dev/null || echo "80")

        if [[ -n "$address" ]]; then
            local scheme="http"
            if [[ "$protocol" == "HTTPS" ]]; then
                scheme="https"
                curl_tls_opt="-k "
            fi

            # Include port if non-standard
            local url_port=""
            if [[ "$port" != "80" && "$port" != "443" ]]; then
                url_port=":${port}"
            fi

            log_info "Gateway address: $address"
            log_info "External URL: ${scheme}://${address}${url_port}"
            log_info "To test externally:"
            echo "  curl ${curl_tls_opt}-X POST '${scheme}://${address}${url_port}/v1/completions' \\"
            echo "    -H 'Content-Type: application/json' \\"
            echo "    -d '{\"model\":\"MODEL_NAME\",\"prompt\":\"Hello\",\"max_tokens\":10}'"
            echo ""
        fi
    else
        log_warn "Gateway $gateway_name is not Programmed"
    fi

    # Check gateway pod has CA bundle mounted
    local gateway_pod
    gateway_pod=$($KUBECTL get pods -n "$kserve_ns" -l "gateway.networking.k8s.io/gateway-name=$gateway_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$gateway_pod" ]]; then
        local ca_mount
        ca_mount=$($KUBECTL get pod "$gateway_pod" -n "$kserve_ns" -o jsonpath='{.spec.containers[*].volumeMounts[?(@.mountPath=="/var/run/secrets/opendatahub")].name}' 2>/dev/null || echo "")
        if [[ -n "$ca_mount" ]]; then
            log_pass "Gateway pod has CA bundle mounted"
        else
            log_warn "Gateway pod missing CA bundle mount at /var/run/secrets/opendatahub"
            log_info "  Hint: Re-run ./scripts/setup-gateway.sh"
        fi
    fi
}

# =============================================================================
# CLOUD PLATFORM DETECTION
# =============================================================================

# Detect cloud platform (AKS, EKS, GKE, OpenShift, etc.)
detect_cloud_platform() {
    log_info "Detecting cloud platform..."

    # Check for AKS (Azure Kubernetes Service)
    local aks_label
    aks_label=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.azure\.com/cluster}' 2>/dev/null || echo "")
    if [[ -n "$aks_label" ]]; then
        CLOUD_PLATFORM="aks"
        log_pass "Detected platform: AKS (Azure Kubernetes Service)"
        return 0
    fi

    # Check for EKS (Amazon Elastic Kubernetes Service)
    local eks_label
    eks_label=$($KUBECTL get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -o "^aws" || echo "")
    if [[ -n "$eks_label" ]]; then
        CLOUD_PLATFORM="eks"
        log_pass "Detected platform: EKS (Amazon Elastic Kubernetes Service)"
        return 0
    fi

    # Check for GKE (Google Kubernetes Engine)
    local gke_label
    gke_label=$($KUBECTL get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -o "^gce" || echo "")
    if [[ -n "$gke_label" ]]; then
        CLOUD_PLATFORM="gke"
        log_pass "Detected platform: GKE (Google Kubernetes Engine)"
        return 0
    fi

    # Check for OpenShift
    if $KUBECTL api-resources | grep -q "routes.route.openshift.io"; then
        CLOUD_PLATFORM="openshift"
        log_pass "Detected platform: OpenShift"
        return 0
    fi

    # Check for CoreWeave (backend.coreweave.cloud/enabled label)
    local coreweave_label
    coreweave_label=$($KUBECTL get nodes -o jsonpath='{.items[0].metadata.labels.backend\.coreweave\.cloud/enabled}' 2>/dev/null || echo "")
    if [[ "$coreweave_label" == "true" ]]; then
        CLOUD_PLATFORM="coreweave"
        log_pass "Detected platform: CoreWeave"
        return 0
    fi

    CLOUD_PLATFORM="unknown"
    log_info "Platform: Unknown (generic Kubernetes)"
    return 0
}

# =============================================================================
# MONITORING VALIDATION
# Based on: https://github.com/llm-d/llm-d/tree/main/docs/monitoring
# =============================================================================

# Auto-detect monitoring namespace by finding Prometheus pods
auto_detect_monitoring_namespace() {
    log_info "Auto-detecting monitoring namespace..."

    # On AKS, check for Azure Managed Prometheus first
    if [[ "$CLOUD_PLATFORM" == "aks" ]]; then
        local ama_pods
        ama_pods=$($KUBECTL get pods -n kube-system --no-headers 2>/dev/null | grep -i "ama-metrics" | wc -l | tr -d '[:space:]')
        if [[ "$ama_pods" -gt 0 ]]; then
            MONITORING_NAMESPACE="kube-system"
            MANAGED_PROMETHEUS="azure"
            log_pass "Found Azure Managed Prometheus (ama-metrics in kube-system)"
            return 0
        fi
    fi

    # Common monitoring namespace patterns (llm-d-monitoring is the default for llm-d deployments)
    local namespaces=("llm-d-monitoring" "monitoring" "prometheus" "openshift-monitoring" "openshift-user-workload-monitoring" "kube-prometheus-stack" "observability")

    for ns in "${namespaces[@]}"; do
        if $KUBECTL get namespace "$ns" &>/dev/null; then
            local prom_pods
            prom_pods=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep -i "prometheus" | wc -l)
            if [[ "$prom_pods" -gt 0 ]]; then
                MONITORING_NAMESPACE="$ns"
                log_pass "Found Prometheus in namespace: $ns"
                return 0
            fi
        fi
    done

    # Check for Azure Managed Prometheus (ama-metrics in kube-system) - fallback for non-AKS detected
    local ama_pods
    ama_pods=$($KUBECTL get pods -n kube-system --no-headers 2>/dev/null | grep -i "ama-metrics" | wc -l | tr -d '[:space:]')
    if [[ "$ama_pods" -gt 0 ]]; then
        MONITORING_NAMESPACE="kube-system"
        MANAGED_PROMETHEUS="azure"
        log_pass "Found Azure Managed Prometheus (ama-metrics in kube-system)"
        return 0
    fi

    # Fallback: search all namespaces for prometheus pods
    local prom_ns
    prom_ns=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | grep -i "prometheus" | head -1 | awk '{print $1}')
    if [[ -n "$prom_ns" ]]; then
        MONITORING_NAMESPACE="$prom_ns"
        log_pass "Found Prometheus in namespace: $prom_ns"
        return 0
    fi

    log_warn "Could not auto-detect monitoring namespace"
    return 1
}

# Check if Prometheus is running
check_prometheus() {
    log_info "Checking Prometheus..."

    # Azure Managed Prometheus uses ama-metrics agents
    if [[ "$MANAGED_PROMETHEUS" == "azure" ]]; then
        local ama_running
        ama_running=$($KUBECTL get pods -n kube-system --no-headers 2>/dev/null | grep -i "ama-metrics" | grep -c "Running" || echo "0")
        if [[ "$ama_running" -gt 0 ]]; then
            log_pass "Azure Managed Prometheus: $ama_running ama-metrics pod(s) running"
            return 0
        else
            log_fail "Azure Managed Prometheus: ama-metrics pods not running"
            return 1
        fi
    fi

    local prom_pods
    prom_pods=$($KUBECTL get pods -n "$MONITORING_NAMESPACE" --no-headers 2>/dev/null | grep -i "prometheus" | wc -l)

    if [[ "$prom_pods" -gt 0 ]]; then
        local running
        running=$($KUBECTL get pods -n "$MONITORING_NAMESPACE" --no-headers 2>/dev/null | grep -i "prometheus" | grep -c "Running" || echo "0")
        if [[ "$running" -gt 0 ]]; then
            log_pass "Prometheus: $running pod(s) running in $MONITORING_NAMESPACE"
            return 0
        else
            log_warn "Prometheus pods found but not running"
            return 1
        fi
    else
        log_fail "No Prometheus pods found in $MONITORING_NAMESPACE"
        return 1
    fi
}

# Check if Grafana is running
check_grafana() {
    log_info "Checking Grafana..."

    # Check in monitoring namespace first
    local grafana_pods
    grafana_pods=$($KUBECTL get pods -n "$MONITORING_NAMESPACE" --no-headers 2>/dev/null | grep -i "grafana" | wc -l)

    if [[ "$grafana_pods" -gt 0 ]]; then
        local running
        running=$($KUBECTL get pods -n "$MONITORING_NAMESPACE" --no-headers 2>/dev/null | grep -i "grafana" | grep -c "Running" || echo "0")
        if [[ "$running" -gt 0 ]]; then
            log_pass "Grafana: $running pod(s) running in $MONITORING_NAMESPACE"
            return 0
        fi
    fi

    # Fallback: check all namespaces
    local grafana_ns
    grafana_ns=$($KUBECTL get pods --all-namespaces --no-headers 2>/dev/null | grep -i "grafana" | grep "Running" | head -1 | awk '{print $1}')
    if [[ -n "$grafana_ns" ]]; then
        log_pass "Grafana running in namespace: $grafana_ns"
        return 0
    fi

    log_warn "No Grafana pods found (optional but recommended)"
    return 0  # Not a failure - Grafana is optional
}

# Check ServiceMonitor CRD exists (Prometheus Operator)
check_servicemonitor_crd() {
    log_info "Checking ServiceMonitor CRD..."

    if $KUBECTL get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        log_pass "ServiceMonitor CRD installed (Prometheus Operator)"
        return 0
    else
        log_warn "ServiceMonitor CRD not found - using legacy Prometheus config?"
        return 1
    fi
}

# Check PodMonitor CRD exists
check_podmonitor_crd() {
    log_info "Checking PodMonitor CRD..."

    if $KUBECTL get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        log_pass "PodMonitor CRD installed"
        return 0
    else
        log_info "PodMonitor CRD not found"
        return 1
    fi
}

# Check for llm-d ServiceMonitors/PodMonitors
check_llmd_monitors() {
    log_info "Checking llm-d monitoring resources..."

    # Check ServiceMonitors in llm-d namespace
    local sm_count
    sm_count=$($KUBECTL get servicemonitor -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [[ "$sm_count" -gt 0 ]]; then
        log_pass "Found $sm_count ServiceMonitor(s) in $LLMD_NAMESPACE"
        $KUBECTL get servicemonitor -n "$LLMD_NAMESPACE" 2>/dev/null | head -10
    else
        log_warn "No ServiceMonitors found in $LLMD_NAMESPACE namespace"
        log_info "  Hint: EPP metrics require a ServiceMonitor"
    fi

    # Check PodMonitors in llm-d namespace (for vLLM metrics)
    local pm_count
    pm_count=$($KUBECTL get podmonitor -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [[ "$pm_count" -gt 0 ]]; then
        log_pass "Found $pm_count PodMonitor(s) in $LLMD_NAMESPACE"
        $KUBECTL get podmonitor -n "$LLMD_NAMESPACE" 2>/dev/null | head -10
    else
        log_info "No PodMonitors found in $LLMD_NAMESPACE (vLLM metrics may use ServiceMonitor)"
    fi
}

# Check if Prometheus can reach llm-d targets (optional - requires port-forward)
check_prometheus_targets() {
    log_info "Checking Prometheus targets for llm-d..."

    # Find Prometheus service
    local prom_svc
    prom_svc=$($KUBECTL get svc -n "$MONITORING_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "prometheus|prom" | grep -v "alertmanager\|operator" | head -1)

    if [[ -z "$prom_svc" ]]; then
        log_info "Could not find Prometheus service for target check"
        return 0
    fi

    local prom_port
    prom_port=$($KUBECTL get svc "$prom_svc" -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "9090")

    # Port-forward to Prometheus
    local local_port=19090
    pkill -f "port-forward.*$local_port:" 2>/dev/null || true
    sleep 1

    log_info "Port-forwarding to Prometheus ($prom_svc:$prom_port)..."
    $KUBECTL port-forward "svc/$prom_svc" "$local_port:$prom_port" -n "$MONITORING_NAMESPACE" &>/dev/null &
    local pf_pid=$!
    sleep 3

    if ! kill -0 "$pf_pid" 2>/dev/null; then
        log_info "Could not port-forward to Prometheus"
        return 0
    fi

    # Query Prometheus targets API
    local targets
    targets=$(curl -s --max-time 10 "http://localhost:$local_port/api/v1/targets" 2>/dev/null || echo "")

    if [[ -n "$targets" ]]; then
        # Check for llm-d targets
        local llmd_targets
        llmd_targets=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.namespace == "'"$LLMD_NAMESPACE"'") | .scrapeUrl' 2>/dev/null | wc -l)

        if [[ "$llmd_targets" -gt 0 ]]; then
            log_pass "Prometheus is scraping $llmd_targets target(s) from $LLMD_NAMESPACE"
        else
            log_warn "No Prometheus targets found for $LLMD_NAMESPACE namespace"
            log_info "  Hint: Check ServiceMonitor/PodMonitor label selectors"
        fi

        # Check for EPP metrics
        local epp_targets
        epp_targets=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | test("epp"; "i")) | .scrapeUrl' 2>/dev/null | wc -l)
        if [[ "$epp_targets" -gt 0 ]]; then
            log_pass "EPP metrics target found"
        fi

        # Check for vLLM metrics
        local vllm_targets
        vllm_targets=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | test("vllm|modelservice"; "i")) | .scrapeUrl' 2>/dev/null | wc -l)
        if [[ "$vllm_targets" -gt 0 ]]; then
            log_pass "vLLM/ModelService metrics target found"
        fi
    else
        log_info "Could not query Prometheus targets API"
    fi

    kill "$pf_pid" 2>/dev/null || true
}

# Main monitoring check function
# Only runs if ServiceMonitors/PodMonitors are created by the llm-d deployment
check_monitoring_stack() {
    log_section "7. Monitoring Stack"

    if [[ "${SKIP_MONITORING_TEST}" == "true" ]]; then
        log_info "Skipping monitoring test (--skip-monitoring)"
        return 0
    fi

    # Check if monitoring is enabled in this deployment (ServiceMonitors/PodMonitors created)
    local sm_count=0
    local pm_count=0

    if $KUBECTL get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        sm_count=$($KUBECTL get servicemonitor -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    fi

    if $KUBECTL get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        pm_count=$($KUBECTL get podmonitor -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    fi

    if [[ "${sm_count:-0}" -eq 0 ]] && [[ "${pm_count:-0}" -eq 0 ]]; then
        log_info "No ServiceMonitors/PodMonitors found in $LLMD_NAMESPACE"
        log_info "Monitoring not enabled in this deployment - skipping monitoring validation"
        log_info "  Hint: Enable monitoring with: kubectl set env deployment/kserve-controller-manager -n opendatahub LLMISVC_MONITORING_DISABLED=false"
        return 0
    fi

    log_info "Found monitoring resources: $sm_count ServiceMonitor(s), $pm_count PodMonitor(s)"

    # Auto-detect monitoring namespace
    auto_detect_monitoring_namespace || true

    # Check Prometheus
    check_prometheus || true

    # Check Grafana (optional)
    check_grafana || true

    # Check CRDs
    check_servicemonitor_crd || true
    check_podmonitor_crd || true

    # Check llm-d monitors
    check_llmd_monitors || true

    # Check Prometheus targets (optional, requires jq)
    if command -v jq &>/dev/null; then
        check_prometheus_targets || true
    else
        log_info "Skipping target check (jq not installed)"
    fi
}

# Auto-detect inference service
auto_detect_inference_service() {
    log_info "Auto-detecting inference service..."

    local pattern="${INFERENCE_SERVICE_PATTERN:-inference-gateway}"

    # Find service matching pattern
    local service
    service=$($KUBECTL get svc -n "$LLMD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i "$pattern" | head -1 || echo "")

    if [[ -n "$service" ]]; then
        INFERENCE_SERVICE="$service"
        log_pass "Auto-detected inference service: $INFERENCE_SERVICE"
        return 0
    fi

    # Fallback: look for any service with port 80 or 8000
    service=$($KUBECTL get svc -n "$LLMD_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.ports[*].port}{"\n"}{end}' 2>/dev/null | grep -E " 80$| 8000" | head -1 | awk '{print $1}' || echo "")

    if [[ -n "$service" ]]; then
        INFERENCE_SERVICE="$service"
        log_pass "Auto-detected inference service by port: $INFERENCE_SERVICE"
        return 0
    fi

    log_warn "Could not auto-detect inference service"
    log_info "Available services:"
    $KUBECTL get svc -n "$LLMD_NAMESPACE" 2>/dev/null
    return 1
}

# Auto-detect model from /v1/models
auto_detect_model() {
    local base_url="$1"
    local curl_opts="${2:-}"

    log_info "Auto-detecting model from /v1/models..."

    local response
    if response=$(curl -s $curl_opts --max-time 10 "${base_url}/v1/models" 2>/dev/null); then
        local model
        model=$(echo "$response" | jq -r '.data[0].id // .models[0].id // .models[0] // empty' 2>/dev/null || echo "")
        if [[ -n "$model" ]]; then
            MODEL_NAME="$model"
            log_pass "Auto-detected model: $MODEL_NAME"
            return 0
        fi
    fi

    log_fail "Could not auto-detect model from /v1/models"
    return 1
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

check_cluster_connectivity() {
    log_section "1. Cluster Connectivity"

    if command -v oc &> /dev/null && oc whoami &> /dev/null 2>&1; then
        KUBECTL="oc"
        log_info "Using OpenShift CLI (oc)"
    elif command -v kubectl &> /dev/null; then
        KUBECTL="kubectl"
        log_info "Using kubectl CLI"
    else
        log_fail "Neither kubectl nor oc CLI found"
        return 1
    fi

    if $KUBECTL cluster-info &> /dev/null; then
        log_pass "Connected to cluster"
        log_info "Context: $($KUBECTL config current-context 2>/dev/null || echo 'unknown')"
        return 0
    else
        log_fail "Cannot connect to cluster"
        return 1
    fi
}

# Check cert-manager operator
# - Not present → WARN
# - Present but pods failing → FAIL
check_cert_manager() {
    log_info "Checking cert-manager operator..."

    local operator_ns="cert-manager-operator"
    local operand_ns="cert-manager"

    # Check if operator namespace exists
    if ! $KUBECTL get namespace "$operator_ns" &> /dev/null; then
        log_warn "cert-manager operator not installed (namespace $operator_ns not found)"
        return 0
    fi

    # Operator namespace exists - check pods
    local total running failed
    total=$($KUBECTL get pods -n "$operator_ns" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    running=$($KUBECTL get pods -n "$operator_ns" --no-headers 2>/dev/null | grep -c "Running" | tr -d '[:space:]' || echo "0")
    failed=$($KUBECTL get pods -n "$operator_ns" --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" | tr -d '[:space:]' || echo "0")

    if [[ "${failed:-0}" -gt 0 ]]; then
        log_fail "cert-manager operator: $failed pod(s) failing in $operator_ns"
        return 1
    elif [[ "${running:-0}" -gt 0 ]]; then
        log_pass "cert-manager operator: $running pod(s) running"
    else
        log_warn "cert-manager operator: no running pods in $operator_ns"
    fi

    # Check operand namespace (cert-manager itself)
    if $KUBECTL get namespace "$operand_ns" &> /dev/null; then
        local cm_running cm_failed
        cm_running=$($KUBECTL get pods -n "$operand_ns" --no-headers 2>/dev/null | grep -c "Running" | tr -d '[:space:]' || echo "0")
        cm_failed=$($KUBECTL get pods -n "$operand_ns" --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" | tr -d '[:space:]' || echo "0")

        if [[ "${cm_failed:-0}" -gt 0 ]]; then
            log_fail "cert-manager: $cm_failed pod(s) failing in $operand_ns"
            return 1
        elif [[ "${cm_running:-0}" -gt 0 ]]; then
            log_pass "cert-manager: $cm_running pod(s) running"
        fi
    fi
}

# Check Istio (sail-operator)
# - Not present → WARN
# - Present but pods failing → FAIL
check_istio() {
    log_info "Checking Istio..."

    local istio_ns="istio-system"

    # Check if namespace exists
    if ! $KUBECTL get namespace "$istio_ns" &> /dev/null; then
        log_warn "Istio not installed (namespace $istio_ns not found)"
        return 0
    fi

    # Namespace exists - check pods
    local total running failed
    total=$($KUBECTL get pods -n "$istio_ns" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    running=$($KUBECTL get pods -n "$istio_ns" --no-headers 2>/dev/null | grep -c "Running" | tr -d '[:space:]' || echo "0")
    failed=$($KUBECTL get pods -n "$istio_ns" --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" | tr -d '[:space:]' || echo "0")

    if [[ "${failed:-0}" -gt 0 ]]; then
        log_fail "Istio: $failed pod(s) failing in $istio_ns"
        return 1
    elif [[ "${running:-0}" -gt 0 ]]; then
        log_pass "Istio: $running pod(s) running in $istio_ns"
    else
        log_warn "Istio: no running pods in $istio_ns"
    fi

    # Check for istiod specifically
    local istiod
    istiod=$($KUBECTL get pods -n "$istio_ns" --no-headers 2>/dev/null | grep -c "istiod" | tr -d '[:space:]' || echo "0")
    if [[ "${istiod:-0}" -gt 0 ]]; then
        log_pass "istiod control plane running"
    else
        log_warn "istiod not found"
    fi
}

# Check LWS (LeaderWorkerSet) operator
# - Not present → WARN (unless wide-ep-lws profile, then FAIL)
# - Present but pods failing → FAIL
check_lws_operator() {
    log_info "Checking LWS operator..."

    local operator_ns="openshift-lws-operator"

    # Check if operator namespace exists
    if ! $KUBECTL get namespace "$operator_ns" &> /dev/null; then
        if [[ "$SELECTED_PROFILE" == "wide-ep-lws" ]]; then
            log_fail "LWS operator required for wide-ep-lws profile (namespace $operator_ns not found)"
            return 1
        else
            log_warn "LWS operator not installed (namespace $operator_ns not found)"
            return 0
        fi
    fi

    # Operator namespace exists - check pods
    local total running failed
    total=$($KUBECTL get pods -n "$operator_ns" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    running=$($KUBECTL get pods -n "$operator_ns" --no-headers 2>/dev/null | grep -c "Running" | tr -d '[:space:]' || echo "0")
    failed=$($KUBECTL get pods -n "$operator_ns" --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" | tr -d '[:space:]' || echo "0")

    if [[ "${failed:-0}" -gt 0 ]]; then
        log_fail "LWS operator: $failed pod(s) failing in $operator_ns"
        return 1
    elif [[ "${running:-0}" -gt 0 ]]; then
        log_pass "LWS operator: $running pod(s) running"
    else
        log_warn "LWS operator: no running pods in $operator_ns"
    fi

    # Check LWS CRD
    if $KUBECTL get crd leaderworkersets.leaderworkerset.x-k8s.io &> /dev/null; then
        log_pass "LeaderWorkerSet CRD installed"
    else
        if [[ "$SELECTED_PROFILE" == "wide-ep-lws" ]]; then
            log_fail "LeaderWorkerSet CRD not found (required for wide-ep-lws)"
            return 1
        fi
    fi
}

check_namespace() {
    log_section "2. Namespace Validation"

    if ! $KUBECTL get namespace "$LLMD_NAMESPACE" &> /dev/null; then
        log_fail "Namespace '$LLMD_NAMESPACE' does not exist"
        return 1
    fi
    log_pass "Namespace '$LLMD_NAMESPACE' exists"

    # Pod summary
    local total running failed pending not_ready
    total=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    running=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" | tr -d '[:space:]' || echo "0")
    failed=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" | tr -d '[:space:]' || echo "0")
    pending=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep -c "Pending" | tr -d '[:space:]' || echo "0")

    log_info "Pods: $total total, $running running, $pending pending, $failed failed"

    # Check for failed pods
    if [[ "${failed:-0}" -gt 0 ]]; then
        log_fail "$failed pod(s) in failed state"
        $KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers | grep -E "Error|CrashLoop|Failed"
    else
        log_pass "No failed pods"
    fi

    # Check for pending pods
    if [[ "${pending:-0}" -gt 0 ]]; then
        log_fail "$pending pod(s) in Pending state"
        $KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers | grep "Pending"
    fi

    # Check for pods not fully ready (Running but 0/X or partial ready)
    # READY column shows X/Y where X < Y means not all containers ready
    local not_ready_pods
    not_ready_pods=$($KUBECTL get pods -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | grep "Running" | awk '{split($2,a,"/"); if(a[1]<a[2]) print $0}')
    if [[ -n "$not_ready_pods" ]]; then
        local not_ready_count
        not_ready_count=$(echo "$not_ready_pods" | wc -l | tr -d '[:space:]')
        log_fail "$not_ready_count pod(s) running but not fully ready"
        echo "$not_ready_pods"
    fi

    # Show all pods
    log_info "Pod status:"
    $KUBECTL get pods -n "$LLMD_NAMESPACE" 2>/dev/null
}

check_helm_releases() {
    log_section "3. Helm Releases"

    if ! command -v helm &> /dev/null; then
        log_info "Helm not installed, skipping release check"
        return 0
    fi

    local releases
    releases=$(helm list -n "$LLMD_NAMESPACE" --no-headers 2>/dev/null | wc -l)

    if [[ "$releases" -gt 0 ]]; then
        log_pass "Found $releases Helm release(s)"
        helm list -n "$LLMD_NAMESPACE" 2>/dev/null
    else
        log_info "No Helm releases found (may use kubectl apply)"
    fi
}

check_profile_components() {
    log_section "4. Profile Components ($SELECTED_PROFILE)"

    local validate_func="profile_${SELECTED_PROFILE//-/_}_validate"

    if declare -f "$validate_func" > /dev/null; then
        "$validate_func"
    else
        log_info "No custom validations for profile"
        # Default validations
        if [[ -n "${EXPECTED_POD_PATTERNS:-}" ]]; then
            for pattern in $EXPECTED_POD_PATTERNS; do
                check_pod_pattern "$pattern" "$pattern"
            done
        fi
    fi
}

check_inference_readiness() {
    log_section "5. Inference Readiness"

    if [[ "${SKIP_INFERENCE_TEST}" == "true" ]]; then
        log_info "Skipping inference test (--skip-inference)"
        return 0
    fi

    # Auto-detect service
    if ! auto_detect_inference_service; then
        log_warn "Skipping inference test - no service found"
        return 0
    fi

    # Get port - prefer port 80 or 8000 over status ports
    local port
    port=$($KUBECTL get svc "$INFERENCE_SERVICE" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.ports[?(@.port==80)].port}' 2>/dev/null)
    if [[ -z "$port" ]]; then
        port=$($KUBECTL get svc "$INFERENCE_SERVICE" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.ports[?(@.port==8000)].port}' 2>/dev/null)
    fi
    if [[ -z "$port" ]]; then
        port=$($KUBECTL get svc "$INFERENCE_SERVICE" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="default")].port}' 2>/dev/null)
    fi
    if [[ -z "$port" ]]; then
        port=$($KUBECTL get svc "$INFERENCE_SERVICE" -n "$LLMD_NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
    fi

    # Check endpoints
    local endpoints
    endpoints=$($KUBECTL get endpoints "$INFERENCE_SERVICE" -n "$LLMD_NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [[ -z "$endpoints" ]]; then
        log_warn "No endpoints for service - pods may not be ready"
        return 0
    fi
    log_pass "Service has $(echo $endpoints | wc -w) endpoint(s)"

    # Port-forward
    local local_port=18080
    pkill -f "port-forward.*$local_port:" 2>/dev/null || true
    sleep 1

    log_info "Port-forwarding to $INFERENCE_SERVICE:$port..."
    $KUBECTL port-forward "svc/$INFERENCE_SERVICE" "$local_port:$port" -n "$LLMD_NAMESPACE" &> /dev/null &
    local pf_pid=$!
    sleep 3

    if ! kill -0 "$pf_pid" 2>/dev/null; then
        log_warn "Port-forward failed"
        return 0
    fi

    # Determine protocol - KServe uses HTTPS, upstream uses HTTP
    local base_url
    local curl_opts=""
    if [[ "$DEPLOYMENT_MODE" == "kserve" ]]; then
        base_url="https://localhost:$local_port"
        curl_opts="-k"  # Skip certificate verification for self-signed certs
        log_info "Using HTTPS (KServe mTLS mode)"
    else
        base_url="http://localhost:$local_port"
    fi

    # Auto-detect model
    if [[ -z "$MODEL_NAME" ]]; then
        auto_detect_model "$base_url" "$curl_opts" || MODEL_NAME="default"
    fi

    # Test inference
    log_info "Testing inference with model: $MODEL_NAME"

    # Print the curl command so user can try it manually
    log_info "To test manually, run:"
    echo "  curl $curl_opts -X POST '${base_url}/v1/completions' \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\":\"$MODEL_NAME\",\"prompt\":\"Hello\",\"max_tokens\":10}'"
    echo ""

    local response http_code
    if response=$(curl -s $curl_opts -w "\n%{http_code}" --max-time 60 \
        -X POST "${base_url}/v1/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_NAME\",\"prompt\":\"Hello\",\"max_tokens\":10}" 2>/dev/null); then

        http_code=$(echo "$response" | tail -1)

        if [[ "$http_code" == "200" ]]; then
            log_pass "Inference successful (HTTP 200)"
        else
            log_fail "Inference returned HTTP $http_code"
            log_info "Response: $(echo "$response" | head -1)"
        fi
    else
        log_fail "Inference request failed"
    fi

    kill "$pf_pid" 2>/dev/null || true
}

check_events() {
    log_section "8. Recent Events"

    log_info "Warning/Error events:"
    $KUBECTL get events -n "$LLMD_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | grep -E "Warning|Error" | tail -5 || echo "  (none)"
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    log_section "CONFORMANCE SUMMARY"

    echo ""
    echo -e "  Profile:    ${CYAN}$SELECTED_PROFILE${NC}"
    echo -e "  Guide:      ${CYAN}$PROFILE_DESCRIPTION${NC}"
    echo -e "  Namespace:  ${CYAN}$LLMD_NAMESPACE${NC}"
    echo ""
    echo -e "  ${GREEN}PASSED:${NC}   $PASSED"
    echo -e "  ${RED}FAILED:${NC}   $FAILED"
    echo -e "  ${YELLOW}WARNINGS:${NC} $WARNINGS"
    echo ""

    if [[ "$FAILED" -eq 0 ]]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                                            ║${NC}"
        echo -e "${GREEN}║   ✓  CONFORMANCE TEST: PASSED                              ║${NC}"
        echo -e "${GREEN}║                                                            ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        return 0
    else
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                                            ║${NC}"
        echo -e "${RED}║   ✗  CONFORMANCE TEST: FAILED                              ║${NC}"
        echo -e "${RED}║                                                            ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    if [[ "$DEPLOYMENT_MODE" == "kserve" ]]; then
        echo "║     KServe LLMInferenceService Conformance Tests           ║"
    else
        echo "║         LLM-D Conformance Tests                            ║"
    fi
    echo "╚════════════════════════════════════════════════════════════╝"

    load_profile "$SELECTED_PROFILE"

    echo ""
    echo "Configuration:"
    echo "  Mode:       $DEPLOYMENT_MODE"
    echo "  Profile:    $SELECTED_PROFILE"
    echo "  Namespace:  $LLMD_NAMESPACE"
    if [[ "$DEPLOYMENT_MODE" == "kserve" ]]; then
        echo "  KServe NS:  $KSERVE_NAMESPACE"
    fi
    echo "  Timeout:    ${TIMEOUT}s"
    echo ""

    check_cluster_connectivity || true
    [[ -z "$KUBECTL" ]] && { print_summary; exit 1; }

    detect_cloud_platform || true
    echo ""
    echo "  Platform:   ${CLOUD_PLATFORM:-unknown}"
    echo ""

    log_section "1b. Operator Prerequisites"
    check_cert_manager || true
    check_istio || true

    if [[ "$DEPLOYMENT_MODE" == "kserve" ]]; then
        # KServe-specific checks
        check_kserve_controller || true
        check_llminferenceserviceconfig || true
        check_kserve_gateway || true
    else
        # Upstream llm-d checks
        check_lws_operator || true
    fi

    check_namespace || true

    if [[ "$DEPLOYMENT_MODE" != "kserve" ]]; then
        check_helm_releases || true
    fi

    check_profile_components || true
    check_inference_readiness || true
    check_monitoring_stack || true
    check_events || true

    print_summary
}

main "$@"
