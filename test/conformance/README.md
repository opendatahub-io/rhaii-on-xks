# LLM-D Conformance Tests

Conformance tests validate that LLM-D and KServe LLMInferenceService deployments meet expected specifications for each deployment profile/guide.

## Quick Start

```bash
# Run via Makefile (auto-detects EA1/EA2 KServe namespace)
make test NAMESPACE=llm-inference

# Deploy mock model and test (no GPU required)
make deploy-mock-model
make test NAMESPACE=mock-vllm-test
make clean-mock-model

# Run directly with options
./verify-llm-d-deployment.sh --kserve --namespace llm-inference

# Test specific profile
./verify-llm-d-deployment.sh --profile inference-scheduling --namespace llm-d

# List available profiles
./verify-llm-d-deployment.sh --list-profiles
```

## Mock vLLM Testing

A mock vLLM server is available for testing the KServe control plane without GPUs or real models. See [`test/mock-vllm/README.md`](../mock-vllm/README.md) for details.

```bash
make deploy-mock-model    # Deploy mock LLMInferenceService
make test NAMESPACE=mock-vllm-test   # Run conformance
make clean-mock-model     # Clean up
```

## Available Profiles

Profiles match official llm-d guides: https://github.com/llm-d/llm-d/tree/main/guides

| Profile | Description | Key Validations |
|---------|-------------|-----------------|
| `inference-scheduling` | Intelligent inference scheduling | EPP, ModelService decode, InferencePool, Gateway |
| `pd-disaggregation` | Prefill/Decode disaggregation | Prefill workers, Decode workers, P/D routing |
| `wide-ep-lws` | Wide Expert Parallelism with LWS | LeaderWorkerSet, multi-worker pods |
| `precise-prefix-cache-aware` | Prefix cache aware routing | Cache config, session affinity |
| `tiered-prefix-cache` | Tiered prefix caching | CPU offload, tiered cache config |
| `simulated-accelerators` | Testing without GPUs | Simulated workers, no GPU requests |
| `quickstart` | Basic deployment | EPP, ModelService, InferencePool |
| `kserve-basic` | KServe LLMInferenceService (basic) | LLMInferenceService, vLLM pods, HTTPRoute |
| `kserve-gpu` | KServe LLMInferenceService (GPU) | LLMInferenceService, vLLM pods, HTTPRoute, GPU |

## What Gets Tested

1. **Cluster Connectivity** - kubectl/oc access
1b. **Operator Prerequisites** - cert-manager, Istio, LWS operator
2. **Namespace Validation** - Namespace exists, pod health checks
3. **Helm Releases** - Deployed Helm charts
4. **Profile Components** - Profile-specific pods, deployments, CRDs
5. **Inference Readiness** - Port-forward, /v1/models, inference test
6. **Monitoring Stack** - Prometheus, Grafana, ServiceMonitors, PodMonitors
7. **Recent Events** - Warning/Error events

## Pod Health Checks

The script performs thorough pod health validation:

- **Failed pods** (Error, CrashLoop, Failed) → FAIL
- **Pending pods** (scheduling issues, resource constraints) → FAIL
- **Not fully ready** (Running but READY shows 0/X or 1/2) → FAIL

Example output:
```
[FAIL] 4 pod(s) running but not fully ready
wide-ep-llm-d-decode-0    1/2   Running   (1 of 2 containers ready)
wide-ep-llm-d-prefill-0   0/1   Running   (0 of 1 containers ready)
```

This catches issues like:
- Insufficient GPU resources
- Node affinity/selector mismatches
- Untolerated taints
- Container startup failures

## Operator Prerequisites

The script checks for required operators:

### cert-manager
- **Namespace**: `cert-manager-operator` (operator), `cert-manager` (operand)
- **Not present** → WARN (may not be needed for all deployments)
- **Present but pods failing** → FAIL

### Istio (sail-operator)
- **Namespace**: `istio-system`
- **Not present** → WARN
- **Present but pods failing** → FAIL
- **Checks for**: istiod control plane

### LWS (LeaderWorkerSet) Operator
- **Namespace**: `openshift-lws-operator`
- **Not present** → WARN (unless `wide-ep-lws` profile)
- **Not present + wide-ep-lws profile** → FAIL (required)
- **Present but pods failing** → FAIL

## Monitoring Validation

The script validates the monitoring stack required for metrics and autoscaling:

- **Auto-detects** Prometheus namespace (llm-d-monitoring, monitoring, openshift-monitoring, etc.)
- **Azure Managed Prometheus** - On AKS, detects ama-metrics pods in kube-system
- **Prometheus** - Checks for running Prometheus pods
- **Grafana** - Checks for Grafana (optional but recommended)
- **ServiceMonitor CRD** - Prometheus Operator installed
- **PodMonitor CRD** - For vLLM metrics collection
- **llm-d Monitors** - ServiceMonitors/PodMonitors in llm-d namespace
- **Prometheus Targets** - Validates llm-d metrics are being scraped

### Azure Managed Prometheus (AKS)

On AKS with Azure Managed Prometheus enabled:
- No in-cluster Prometheus server (metrics go to Azure Monitor workspace)
- Detected via `ama-metrics` pods in `kube-system`
- ServiceMonitors/PodMonitors still work (Prometheus Operator CRDs required)

### Expected Monitors

When llm-d is deployed with monitoring enabled:
- **ServiceMonitor for EPP** - `inferenceExtension.monitoring.prometheus.enabled: true`
- **PodMonitor for vLLM prefill** - `prefill.monitoring.podmonitor.enabled: true`
- **PodMonitor for vLLM decode** - `decode.monitoring.podmonitor.enabled: true`

## Inference Testing

The script tests actual inference capability:
- **Port Detection**: Prefers port 80 or 8000 over status ports (15021)
- **Model Detection**: Queries `/v1/models` endpoint
- **Inference Test**: Sends request to `/v1/completions`
- **FAIL if**: Model detection fails OR inference request fails (HTTP != 200)

Note: If modelservice pods are scaled to 0, inference will fail (expected behavior).

## Deployment Checks

The script detects deployments that exist but are scaled to 0:
- Reports as WARNING: "deployment exists but scaled to 0"
- Useful for identifying incomplete deployments

## Cloud Platform Detection

The script auto-detects the cloud platform:

| Platform | Detection Method | Supported |
|----------|------------------|-----------|
| **AKS** | Node label `kubernetes.azure.com/cluster` | Yes |
| **CoreWeave** | Node region label contains `coreweave` | Yes |
| **EKS** | Node providerID prefix `aws` | No |
| **GKE** | Node providerID prefix `gce` | No |
| **OpenShift** | API resource `routes.route.openshift.io` | Use ODH overlay |

Platform detection enables platform-specific behaviors like preferring Azure Managed Prometheus on AKS.

## Auto-Detection

The script automatically detects:
- **Cloud Platform**: AKS, CoreWeave (supported)
- **Monitoring Namespace**: Scans common namespaces for Prometheus pods
- **Azure Managed Prometheus**: Detects ama-metrics pods on AKS
- **Inference Service**: Scans for services matching gateway patterns
- **Inference Port**: Prefers port 80/8000 over status ports
- **Model Name**: Queries `/v1/models` endpoint

## Usage Examples

```bash
# Fully automatic
./verify-llm-d-deployment.sh -n llm-d

# Specify profile
./verify-llm-d-deployment.sh --profile pd-disaggregation -n llm-d

# Override model (skip auto-detection)
./verify-llm-d-deployment.sh -n llm-d -m "meta-llama/Llama-3.1-8B-Instruct"

# Skip inference test (faster, just check components)
./verify-llm-d-deployment.sh --profile inference-scheduling --skip-inference -n llm-d

# Skip monitoring validation
./verify-llm-d-deployment.sh -n llm-d --skip-monitoring

# Longer timeout for slow clusters
./verify-llm-d-deployment.sh -n llm-d --timeout 300
```

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --profile NAME` | Deployment profile to validate | `inference-scheduling` |
| `-n, --namespace NAME` | LLM-D namespace | `llm-d` |
| `-t, --timeout SECONDS` | Timeout for wait operations | `120` |
| `-m, --model NAME` | Model name for inference test | auto-detect |
| `--skip-inference` | Skip the inference test | - |
| `--skip-monitoring` | Skip monitoring stack validation | - |
| `--monitoring-namespace` | Override monitoring namespace | auto-detect |
| `--list-profiles` | List available profiles | - |
| `-h, --help` | Show help message | - |

## Adding New Profiles

1. Add profile name to `AVAILABLE_PROFILES` array
2. Create config function:

```bash
profile_my_profile_config() {
    PROFILE_DESCRIPTION="My custom profile"

    # Pod patterns to check
    EXPECTED_POD_PATTERNS="epp modelservice"
    EXPECTED_DEPLOYMENT_PATTERNS="epp modelservice"
    EXPECTED_SERVICE_PATTERNS="epp"
    EXPECTED_CRDS="inferencepool"

    # Inference service pattern for auto-detect
    INFERENCE_SERVICE_PATTERN="inference-gateway"

    # Feature flags
    VALIDATE_EPP="true"
    VALIDATE_MODELSERVICE="true"
    VALIDATE_GPU="true"
}
```

3. Optionally add custom validation:

```bash
profile_my_profile_validate() {
    log_info "Running custom validations..."

    check_pod_pattern "epp" "EPP"
    check_pod_pattern "modelservice" "ModelService"
    check_inferencepool
}
```

## Exit Codes

- `0` - All checks passed
- `1` - One or more checks failed

## Requirements

- `kubectl` or `oc` CLI with cluster access
- `curl` for inference testing
- `jq` for JSON parsing and Prometheus target validation (optional)
