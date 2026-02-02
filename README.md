# llm-d-infra-xks

Infrastructure Helm charts for deploying llm-d on xKS platforms (AKS, EKS, GKE).

## Overview

| Component | App Version | Description |
|-----------|-------------|-------------|
| cert-manager-operator | 1.15.2 | TLS certificate management |
| sail-operator (Istio) | 3.2.1 | Gateway API for inference routing |
| lws-operator | 1.0 | LeaderWorkerSet controller |

## Prerequisites

- Kubernetes cluster (AKS, EKS, GKE)
- `kubectl`, `helm`, `helmfile`
- Red Hat pull secret

```bash
# Configure pull secret
mkdir -p ~/.config/containers
cp ~/pull-secret.txt ~/.config/containers/auth.json
```

## Quick Start

```bash
git clone https://github.com/aneeshkp/llm-d-infra-xks.git
cd llm-d-infra-xks

# Deploy cert-manager + istio
make deploy

# Or deploy all including lws
make deploy-all

# Check status
make status
```

## Usage

```bash
# Deploy
make deploy              # cert-manager + istio
make deploy-all          # cert-manager + istio + lws

# Deploy individual
make deploy-cert-manager
make deploy-istio
make deploy-lws

# Undeploy
make undeploy            # Remove all
make undeploy-cert-manager
make undeploy-istio
make undeploy-lws

# Other
make status              # Show status
make test                # Run tests
make sync                # Update helm repos
```

## Configuration

Edit `values.yaml`:

```yaml
# Option 1: Use system podman auth (recommended)
useSystemPodmanAuth: true

# Option 2: Use pull secret file directly
# pullSecretFile: ~/pull-secret.txt

# Operators
certManager:
  enabled: true

sailOperator:
  enabled: true

lwsOperator:
  enabled: true   # Set false if not needed
```

## Structure

```
llm-d-infra-xks/
├── helmfile.yaml.gotmpl
├── values.yaml
├── Makefile
├── README.md
└── scripts/
    └── copy-pull-secret.sh
```

## Source Repositories

Operator helmfiles are imported from:

- https://github.com/aneeshkp/cert-manager-operator-chart
- https://github.com/aneeshkp/sail-operator-chart
- https://github.com/aneeshkp/lws-operator-chart

This approach imports the full helmfiles including presync hooks for CRD installation.

## Monitoring (Optional)

Monitoring is **disabled by default** in the KServe odh-xks overlay to avoid Prometheus Operator dependency.

### KServe Controller Settings

The odh-xks overlay disables several OpenShift-specific features for vanilla Kubernetes (AKS/EKS/GKE) compatibility
(see `config/overlays/odh-xks/patches/patch-controller-env.yaml` in KServe repo):

```yaml
# Disabled by default in odh-xks overlay
- name: LLMISVC_MONITORING_DISABLED
  value: "true"              # No Prometheus Operator dependency
- name: LLMISVC_AUTH_DISABLED
  value: "true"              # No Kuadrant/RHCL dependency
- name: LLMISVC_SCC_DISABLED
  value: "true"              # No OpenShift SecurityContextConstraints
```

| Setting | Why Disabled on xKS |
|---------|---------------------|
| `LLMISVC_MONITORING_DISABLED` | Prometheus Operator not required for basic inference |
| `LLMISVC_AUTH_DISABLED` | Authorino/Kuadrant (Red Hat Connectivity Link) is OpenShift-only |
| `LLMISVC_SCC_DISABLED` | SecurityContextConstraints are OpenShift-specific |

### Authentication on AKS/xKS

On OpenShift, LLMInferenceService uses **Authorino** (via Red Hat Connectivity Link) for API authentication:
- Requires valid JWT token to access inference endpoints
- Uses Kubernetes RBAC to check if ServiceAccount can "get" the LLMInferenceService
- Requests without valid token get `401 Unauthorized`

**On AKS/EKS/GKE (xKS):**
- Authorino/Kuadrant is **not available** (OpenShift-only operator)
- Authentication is **disabled by default** (`LLMISVC_AUTH_DISABLED=true`)
- Inference endpoints are accessible without authentication

**If you need authentication on xKS**, you have options:
1. Use Istio AuthorizationPolicy for JWT validation
2. Use an API Gateway with auth (e.g., Kong, Ambassador)
3. Implement auth at the application level

### Enabling Monitoring

Monitoring is only needed if you:
- Want to use **Workload Variant Autoscaler (WVA)** - requires Prometheus
- Want to visualize metrics with **Grafana dashboards**

To enable monitoring:

1. Deploy Prometheus Operator on your cluster (see [monitoring-stack/](./monitoring-stack/))

2. Patch the KServe controller to enable monitoring:
```bash
kubectl set env deployment/kserve-controller-manager \
  -n opendatahub \
  LLMISVC_MONITORING_DISABLED=false
```

3. Enable monitoring in your llm-d `values.yaml`:
```yaml
inferenceExtension:
  monitoring:
    prometheus:
      enabled: true

prefill:
  monitoring:
    podmonitor:
      enabled: true

decode:
  monitoring:
    podmonitor:
      enabled: true
```

See [monitoring-stack/](./monitoring-stack/) for details.

## KServe Integration

If using llm-d with KServe (LLMInferenceService), you need to set up the Gateway
with CA bundle mounting for mTLS between components.

```bash
# After deploying infrastructure
./scripts/setup-gateway.sh
```

See [docs/gateway-setup-for-kserve.md](./docs/gateway-setup-for-kserve.md) for details.

## Deploying LLMInferenceService

After infrastructure is ready, you can deploy LLM models using KServe's LLMInferenceService.

### Prerequisites Checklist

```bash
# 1. Verify infrastructure is running
make status

# 2. Verify KServe controller is running
kubectl get pods -n opendatahub -l control-plane=kserve-controller-manager

# 3. Verify Gateway is programmed (if not, run ./scripts/setup-gateway.sh)
kubectl get gateway -n opendatahub

# 4. Verify Gateway pod is running (not ErrImagePull)
kubectl get pods -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

**Important:** vLLM images are from `registry.redhat.io` which requires a Red Hat pull secret.
You must copy the pull secret to each namespace where you deploy LLMInferenceService.

### Deploy KServe with odh-xks Overlay

The `odh-xks` overlay configures KServe for vanilla Kubernetes (AKS, EKS, GKE).

**Prerequisites (provided by llm-d-infra-xks):**

| Component | Requirement |
|-----------|-------------|
| cert-manager | Handles certificate management |
| Istio | Must have Gateway API support (`PILOT_ENABLE_GATEWAY_API=true`) |
| Gateway API CRDs | Standard Gateway API installation |
| LeaderWorkerSet (LWS) | Required for multi-node LLM workloads |

**What odh-xks includes:**

| Resource | Description |
|----------|-------------|
| CRDs | LLMInferenceService, LLMInferenceServiceConfig, InferencePool, InferenceModel |
| Controller | kserve-controller-manager deployment |
| LLMInferenceServiceConfig | 9 template configs for vLLM, scheduler, router |
| Webhooks | Validation webhooks for LLMInferenceService |
| TLS | Certificate, ClusterIssuer for mTLS between components |

**Deploy:**

```bash
# Clone KServe repo
git clone https://github.com/opendatahub-io/kserve.git
cd kserve
git checkout release-v0.15

# Deploy KServe with odh-xks overlay
kustomize build config/overlays/odh-xks | kubectl apply --server-side -f -

# Wait for controller to be ready
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n opendatahub --timeout=300s

# Verify LLMInferenceServiceConfig templates exist
kubectl get llminferenceserviceconfig -n opendatahub
# Should show: kserve-config-llm-template, kserve-config-llm-router-route, kserve-config-llm-scheduler, etc.

# Set up Gateway with CA bundle (required for mTLS)
cd /path/to/llm-d-infra-xks
./scripts/setup-gateway.sh
```

**Troubleshooting:**

If the controller pod is stuck in `ContainerCreating` (waiting for certificate):
```bash
# Apply cert-manager resources separately first
kubectl apply -k config/overlays/odh-xks/cert-manager
kubectl wait --for=condition=Ready certificate/kserve-webhook-server -n opendatahub --timeout=120s

# Then re-apply the overlay
kustomize build config/overlays/odh-xks | kubectl apply --server-side -f -
```

If webhook validation blocks apply:
```bash
kubectl delete validatingwebhookconfiguration llminferenceservice.serving.kserve.io llminferenceserviceconfig.serving.kserve.io
kustomize build config/overlays/odh-xks | kubectl apply --server-side --force-conflicts -f -
```

**Key Differences from ODH (OpenShift) Overlay:**

| Component | OpenShift (ODH) | Vanilla K8s (odh-xks) |
|-----------|-----------------|----------------------|
| Certificates | OpenShift service-ca | cert-manager |
| Security constraints | SCC included | Removed |
| Traffic routing | Istio VirtualService | Gateway API |
| Webhook CA injection | Service annotations | cert-manager annotations |
| Auth | Authorino/Kuadrant | Disabled (LLMISVC_AUTH_DISABLED) |
| Monitoring | Prometheus included | Disabled (LLMISVC_MONITORING_DISABLED) |

**TLS Certificate Architecture:**

The overlay creates an OpenDataHub-scoped CA:
1. Self-signed bootstrap issuer creates root CA in cert-manager namespace
2. ClusterIssuer (`opendatahub-ca-issuer`) uses this CA to sign certificates
3. Controller generates certificates for LLM workload mTLS automatically
4. Gateway needs CA bundle mounted at `/var/run/secrets/opendatahub/ca.crt`

### Sample: Deploy Qwen2.5-7B on GPU (No Scheduler)

This is the simplest GPU deployment - uses Kubernetes service load balancing instead of the inference scheduler.

**Create namespace:**
```bash
export NAMESPACE=llm-test
kubectl create namespace $NAMESPACE
```

**Set up Red Hat pull secret (REQUIRED for vLLM images):**

The vLLM images are from `registry.redhat.io/rhaiis/` which requires a Red Hat registry service account.

1. Go to https://access.redhat.com/terms-based-registry/
2. Create a Registry Service Account (token)
3. Download the pull secret (OpenShift Pull Secret format)
4. Create the secret in your namespace and add to ServiceAccount:

```bash
# Create pull secret from downloaded auth file
kubectl create secret generic redhat-pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/path/to/your-auth.json \
  -n $NAMESPACE

# Add to default ServiceAccount (recommended - all pods in namespace will use it)
kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

# Verify
kubectl get secret redhat-pull-secret -n $NAMESPACE
kubectl get serviceaccount default -n $NAMESPACE -o yaml | grep -A2 imagePullSecrets
```

**Create HuggingFace token secret (for gated models):**
```bash
kubectl create secret generic hf-token \
  --from-literal=HF_TOKEN=<your-huggingface-token> \
  -n $NAMESPACE
```

**Deploy the LLMInferenceService:**
```bash
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen2-7b-instruct
spec:
  model:
    uri: hf://Qwen/Qwen2.5-7B-Instruct
    name: Qwen/Qwen2.5-7B-Instruct
  replicas: 1
  router:
    route: { }
    gateway: { }
  template:
    containers:
      - name: main
        resources:
          limits:
            cpu: '4'
            memory: 32Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: '2'
            memory: 16Gi
            nvidia.com/gpu: "1"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 30
          failureThreshold: 5
EOF
```

**Note:** The pull secret is inherited from the `default` ServiceAccount (patched above). Alternatively, you can add `imagePullSecrets` directly in the template spec.

**Check deployment status:**
```bash
# Watch LLMInferenceService status
kubectl get llmisvc -n $NAMESPACE -w

# Check pods
kubectl get pods -n $NAMESPACE

# Check events if pods are not starting
kubectl describe llmisvc qwen2-7b-instruct -n $NAMESPACE
```

**Test inference:**
```bash
# Get the service URL
SERVICE_URL=$(kubectl get llmisvc qwen2-7b-instruct -n $NAMESPACE -o jsonpath='{.status.url}')

# Port-forward to test locally
kubectl port-forward svc/qwen2-7b-instruct -n $NAMESPACE 8080:80 &

# Test with curl
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "prompt": "What is Kubernetes?",
    "max_tokens": 100
  }'
```

### More Examples

| Example | Description | Path |
|---------|-------------|------|
| CPU (OPT-125M) | Simple CPU deployment for testing | `docs/samples/llmisvc/opt-125m-cpu/` |
| GPU with Scheduler | Intelligent request routing | `docs/samples/llmisvc/single-node-gpu/llm-inference-service-qwen2-7b-gpu.yaml` |
| Prefill-Decode | Disaggregated serving | `docs/samples/llmisvc/single-node-gpu/llm-inference-service-pd-qwen2-7b-gpu.yaml` |
| Multi-node MoE | DeepSeek with expert parallelism | `docs/samples/llmisvc/dp-ep/` |

See the [KServe samples](https://github.com/opendatahub-io/kserve/tree/release-v0.15/docs/samples/llmisvc) for more examples.

## Next Steps

After deploying infrastructure, follow the [llm-d guides](https://github.com/llm-d/llm-d/tree/main/guides) to deploy llm-d.

**Helper scripts:**
- `scripts/copy-pull-secret.sh <namespace>` - Fix gateway pull secret issues
- `scripts/setup-gateway.sh` - Set up Gateway for KServe integration
