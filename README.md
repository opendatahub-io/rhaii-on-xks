# rhaii-on-xks

Infrastructure Helm charts for deploying Red Hat AI Inference Server (KServe LLMInferenceService) on managed Kubernetes
platforms (AKS, CoreWeave).

> **Getting started?** See
> the [Deploying Red Hat AI Inference Server on Managed Kubernetes](./docs/deploying-llm-d-on-managed-kubernetes.md)
> guide for step-by-step deployment instructions.

## Related Repositories

| Repository                                                       | Purpose                                                               |
|------------------------------------------------------------------|-----------------------------------------------------------------------|
| [llm-d-xks-aks](https://github.com/kwozyman/llm-d-xks-aks)       | AKS cluster provisioning (creates cluster + GPU nodes + GPU Operator) |
| [rhaii-xks-kserve](https://github.com/pierDipi/rhaii-xks-kserve) | KServe Helm charts (WIP)                                              |

## Overview

| Component             | App Version | Description                                         |
|-----------------------|-------------|-----------------------------------------------------|
| cert-manager-operator | 1.15.2      | TLS certificate management                          |
| sail-operator (Istio) | 3.2.x       | Gateway API for inference routing                   |
| lws-operator          | 1.0         | LeaderWorkerSet controller for multi-node workloads |

### Version Compatibility

| Component            | Version    | Notes                             |
|----------------------|------------|-----------------------------------|
| OSSM (Sail Operator) | 3.2.x      | Gateway API for inference routing |
| Istio                | v1.27.x    | Service mesh                      |
| InferencePool API    | v1         | `inference.networking.k8s.io/v1`  |
| KServe               | rhoai-3.4+ | LLMInferenceService controller    |

## Prerequisites

- Kubernetes cluster (AKS or CoreWeave) - see [llm-d-xks-aks](https://github.com/kwozyman/llm-d-xks-aks) for AKS
  provisioning
- `kubectl`, `helm` (v3.17+), `helmfile`, `kustomize` (v5.7+)
- Red Hat account (for Sail Operator and vLLM images from `registry.redhat.io`)

### Red Hat Pull Secret Setup

The Sail Operator and RHAIIS vLLM images are hosted on `registry.redhat.io` which requires authentication.
Choose **one** of the following methods:

#### Method 1: Registry Service Account (Recommended)

Create a Registry Service Account (works for both Sail Operator and vLLM images):

1. Go to: https://access.redhat.com/terms-based-registry/
2. Click "New Service Account"
3. Create account and note the username (e.g., `12345678|myserviceaccount`)
4. Login with the service account credentials:

```bash
$ podman login registry.redhat.io
Username: {REGISTRY-SERVICE-ACCOUNT-USERNAME}
Password: {REGISTRY-SERVICE-ACCOUNT-PASSWORD}
Login Succeeded!

# Verify it works
$ podman pull registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle:3.2
```

Then configure `values.yaml`:

```yaml
useSystemPodmanAuth: true
```

**Alternative:** Download the pull secret file (OpenShift secret tab) and copy to persistent location:

```bash
mkdir -p ~/.config/containers
cp ~/pull-secret.txt ~/.config/containers/auth.json
```

> **Note:** Registry Service Accounts are recommended as they don't expire like personal credentials.

#### Method 2: Podman Login with Red Hat Account (For Developers)

If you have direct Red Hat account access (e.g., internal developers):

```bash
$ podman login registry.redhat.io
Username: {YOUR-REDHAT-USERNAME}
Password: {YOUR-REDHAT-PASSWORD}
Login Succeeded!
```

This stores credentials in `${XDG_RUNTIME_DIR}/containers/auth.json` or `~/.config/containers/auth.json`.

Then configure `values.yaml`:

```yaml
useSystemPodmanAuth: true
```

---

## Quick Start

### Step 1: Deploy Infrastructure

```bash
git clone https://github.com/opendatahub-io/rhaii-on-xks.git
cd rhaii-on-xks

# Deploy cert-manager + istio + lws
make deploy-all

# Check status
make status
```

### Step 2: Deploy KServe

```bash
make deploy-kserve

# Verify
kubectl get pods -n opendatahub
kubectl get llminferenceserviceconfig -n opendatahub
```

<details>
<summary>Manual steps (click to expand)</summary>

```bash
# Create opendatahub namespace
kubectl create namespace opendatahub --dry-run=client -o yaml | kubectl apply -f -

# Copy pull secret from istio-system (created by infrastructure deployment)
kubectl get secret redhat-pull-secret -n istio-system -o yaml | \
  sed 's/namespace: istio-system/namespace: opendatahub/' | \
  kubectl apply -f -

# Apply cert-manager PKI resources first (required for webhook certificates)
kubectl apply -k "https://github.com/opendatahub-io/kserve/config/overlays/odh-test/cert-manager?ref=release-v0.15"
kubectl wait --for=condition=Ready clusterissuer/opendatahub-ca-issuer --timeout=120s

# First apply - creates CRDs and deployment (CR errors expected due to webhook)
kustomize build "https://github.com/opendatahub-io/kserve/config/overlays/odh-xks?ref=release-v0.15" | kubectl apply --server-side --force-conflicts -f - || true

# Delete webhooks to allow controller startup
kubectl delete validatingwebhookconfiguration llminferenceservice.serving.kserve.io llminferenceserviceconfig.serving.kserve.io --ignore-not-found

# Wait for controller to be ready
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n opendatahub --timeout=300s

# Second apply - now webhooks work, applies CRs
kustomize build "https://github.com/opendatahub-io/kserve/config/overlays/odh-xks?ref=release-v0.15" | kubectl apply --server-side --force-conflicts -f -

# Verify LLMInferenceServiceConfig templates exist
kubectl get llminferenceserviceconfig -n opendatahub
```

</details>

### Step 3: Set up Gateway

```bash
./scripts/setup-gateway.sh

# Verify
kubectl get gateway -n opendatahub
```

<details>
<summary>What the script does (click to expand)</summary>

The script:

1. Copies the CA bundle from cert-manager to opendatahub namespace
2. Creates a Gateway with the CA bundle mounted for mTLS to backend services
3. Patches the Gateway pod to use the pull secret

</details>

### Step 4: Deploy LLMInferenceService

#### Hardware Requirements

| Resource | Per Replica   | Notes                       |
|----------|---------------|-----------------------------|
| GPU      | 1x NVIDIA GPU | A10, A100, H100, or similar |
| CPU      | 2-4 cores     |                             |
| Memory   | 16-32 Gi      | Depends on model size       |

#### Node Requirements

Ensure your cluster has GPU nodes with the NVIDIA device plugin installed:

```bash
# Verify GPU nodes are available
kubectl get nodes -l nvidia.com/gpu.present=true

# Check GPU resources
kubectl describe nodes | grep -A5 "nvidia.com/gpu"
```

For AKS, create a GPU node pool:

```bash
az aks nodepool add \
  --resource-group <rg> \
  --cluster-name <cluster> \
  --name gpunp \
  --node-count 2 \
  --node-vm-size Standard_NC24ads_A100_v4 \
  --node-taints sku=gpu:NoSchedule \
  --labels nvidia.com/gpu.present=true
```

#### Deploy Sample Model

```bash
# Create namespace first
export NAMESPACE=llm-d-test
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Copy pull secret from istio-system (created by infrastructure deployment)
kubectl get secret redhat-pull-secret -n istio-system -o yaml | \
  sed "s/namespace: istio-system/namespace: $NAMESPACE/" | \
  kubectl apply -f -

# Patch default ServiceAccount to use pull secret (all pods will inherit it)
kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

# Deploy Qwen2.5-7B model with scheduler
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen2-7b-instruct
spec:
  model:
    name: Qwen/Qwen2.5-7B-Instruct
    uri: hf://Qwen/Qwen2.5-7B-Instruct
  replicas: 1
  router:
    gateway: {}
    route: {}
    scheduler: {}   # Enable EPP scheduler for intelligent routing
  template:
    containers:
    - name: main
      resources:
        limits:
          cpu: "4"
          memory: 32Gi
          nvidia.com/gpu: "1"
        requests:
          cpu: "2"
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

# Watch deployment status
kubectl get llmisvc -n $NAMESPACE -w
```

#### Check Deployment Status

```bash
# Check pods
kubectl get pods -n $NAMESPACE

# Check events if pods are not starting
kubectl describe llmisvc qwen2-7b-instruct -n $NAMESPACE
```

#### Test Inference

```bash
# Get the service URL
SERVICE_URL=$(kubectl get llmisvc qwen2-7b-instruct -n $NAMESPACE -o jsonpath='{.status.url}')

# Test with curl (use external gateway IP)
curl -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 100
  }'
```

#### More Examples

| Example            | Description                       | Path                                                                              |
|--------------------|-----------------------------------|-----------------------------------------------------------------------------------|
| CPU (OPT-125M)     | Simple CPU deployment for testing | `docs/samples/llmisvc/opt-125m-cpu/`                                              |
| GPU with Scheduler | Intelligent request routing       | `docs/samples/llmisvc/single-node-gpu/`                                           |
| Prefill-Decode     | Disaggregated serving             | `docs/samples/llmisvc/single-node-gpu/llm-inference-service-pd-qwen2-7b-gpu.yaml` |
| Multi-node MoE     | DeepSeek with expert parallelism  | `docs/samples/llmisvc/dp-ep/`                                                     |

See more [KServe samples](https://github.com/red-hat-data-services/kserve/tree/rhoai-3.4/docs/samples/llmisvc).

---

## Usage

```bash
# Deploy
make deploy              # cert-manager + istio
make deploy-all          # cert-manager + istio + lws + kserve
make deploy-kserve       # Deploy KServe

# Undeploy
make undeploy            # Remove all infrastructure

# Test (ODH conformance)
make test NAMESPACE=llm-d-test      # Run conformance tests
make test PROFILE=kserve-gpu        # With specific profile

# Other
make status              # Show status
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
  enabled: true   # Required for multi-node LLM workloads
```

---

## KServe Controller Settings

The odh-xks overlay disables several OpenShift-specific features for vanilla Kubernetes (AKS/CoreWeave) compatibility:

```yaml
# Disabled by default in odh-xks overlay
- name: LLMISVC_MONITORING_DISABLED
  value: "true"              # No Prometheus Operator dependency
- name: LLMISVC_AUTH_DISABLED
  value: "true"              # No Kuadrant/RHCL dependency
- name: LLMISVC_SCC_DISABLED
  value: "true"              # No OpenShift SecurityContextConstraints
```

| Setting                       | Why Disabled on xKS                                              |
|-------------------------------|------------------------------------------------------------------|
| `LLMISVC_MONITORING_DISABLED` | Prometheus Operator not required for basic inference             |
| `LLMISVC_AUTH_DISABLED`       | Authorino/Kuadrant (Red Hat Connectivity Link) is OpenShift-only |
| `LLMISVC_SCC_DISABLED`        | SecurityContextConstraints are OpenShift-specific                |

### Enabling Monitoring

To enable Prometheus monitoring for KServe-managed workloads:

1. Deploy Prometheus Operator on your cluster (see [monitoring-stack/](./monitoring-stack/))

2. Patch the KServe controller to enable monitoring:

```bash
kubectl set env deployment/kserve-controller-manager \
  -n opendatahub \
  LLMISVC_MONITORING_DISABLED=false
```

This enables KServe to automatically create `PodMonitor` resources for vLLM pods.

---

## Collecting Debug Information

If you encounter issues, collect diagnostic information for troubleshooting or to share with Red Hat support:

```bash
./scripts/collect-debug-info.sh
```

This collects logs, status, and events from all components (cert-manager, Istio, LWS, KServe) into a single directory.
See the [Collecting Debug Information](./docs/collecting-debug-information.md) guide for details.

---

## Troubleshooting

### KServe Controller Issues

If the controller pod is stuck in `ContainerCreating` (waiting for certificate):

```bash
# Apply cert-manager resources separately first
kubectl apply -k "https://github.com/red-hat-data-services/kserve/config/overlays/odh-test/cert-manager?ref=rhoai-3.4"
kubectl wait --for=condition=Ready certificate/kserve-webhook-server -n opendatahub --timeout=120s

make deploy-kserve
```

### Gateway Issues

If Gateway pod has `ErrImagePull`:

```bash
# Copy pull secret to opendatahub namespace
kubectl get secret redhat-pull-secret -n istio-system -o yaml | \
  sed 's/namespace: istio-system/namespace: opendatahub/' | kubectl apply -f -

# Patch the gateway ServiceAccount
kubectl patch sa inference-gateway-istio -n opendatahub \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

# Delete the failing pod to trigger restart
kubectl delete pod -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

---

## Reinstalling Istio

If you need to do a clean reinstall of Istio:

```bash
# 1. Delete the Istio CR (triggers istiod cleanup)
kubectl delete istio default -n istio-system

# 2. Wait for istiod to be removed
kubectl wait --for=delete pod -l app=istiod -n istio-system --timeout=120s

# 3. Redeploy
make deploy-istio
```

---

## Architecture

### TLS Certificate Architecture

The odh-xks overlay creates an OpenDataHub-scoped CA:

1. Self-signed bootstrap issuer creates root CA in cert-manager namespace
2. ClusterIssuer (`opendatahub-ca-issuer`) uses this CA to sign certificates
3. KServe controller generates certificates for LLM workload mTLS automatically
4. Gateway needs CA bundle mounted at `/var/run/secrets/opendatahub/ca.crt`

### Key Differences from OpenShift (ODH) Overlay

| Component            | OpenShift (ODH)      | Vanilla K8s (odh-xks)    |
|----------------------|----------------------|--------------------------|
| Certificates         | OpenShift service-ca | cert-manager             |
| Security constraints | SCC included         | Removed                  |
| Traffic routing      | Istio VirtualService | Gateway API              |
| Webhook CA injection | Service annotations  | cert-manager annotations |
| Auth                 | Authorino/Kuadrant   | Disabled                 |
| Monitoring           | Prometheus included  | Disabled (optional)      |

---

## Structure

```
rhaii-on-xks/
├── helmfile.yaml.gotmpl
├── values.yaml
├── Makefile
├── README.md
├── charts/
│   ├── cert-manager-operator/    # cert-manager operator Helm chart
│   ├── sail-operator/            # Sail/Istio operator Helm chart
│   └── lws-operator/             # LWS operator Helm chart
│   └── kserve/                   # Kserve controller Helm chart
└── scripts/
    ├── cleanup.sh             # Cleanup infrastructure (helmfile destroy + finalizers)
    └── setup-gateway.sh       # Set up Gateway with CA bundle for mTLS
```

## Operator Charts

Operator Helm charts are included locally under `charts/`:

- `charts/cert-manager-operator/` — cert-manager operator
- `charts/sail-operator/` — Sail/Istio operator
- `charts/lws-operator/` — LeaderWorkerSet operator
- `charts/kserve/` — Kserve controller

The helmfile imports these local charts including presync hooks for CRD installation.
