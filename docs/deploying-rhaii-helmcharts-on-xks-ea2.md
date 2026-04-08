# Deploying Red Hat AI Inference Server: Distributed Inference with llm-d (EA2)

**Product:** Red Hat AI Inference Server (RHAIIS)
**Version:** 3.4 EA2
**Platforms:** Azure Kubernetes Service (AKS), CoreWeave Kubernetes Service (CKS)

---

## Executive Summary

This guide provides step-by-step instructions for deploying Distributed Inference with llm-d for Red Hat AI Inference Server using the RHAII Helm chart (`rhai-on-xks-chart`). The Helm chart deploys the RHAI operator and a cloud-specific manager, which together automatically provision all required infrastructure including cert-manager, Istio, and LeaderWorkerSet.

Key capabilities:

- **Single-command installation** using Helm from OCI registry
- **Automatic infrastructure provisioning** via the cloud manager
- **Intelligent request routing** using the Endpoint Picker Processor (EPP)
- **Disaggregated serving** with prefill-decode separation
- **Cache-aware routing** for prefix KV cache optimization
- **Mutual TLS (mTLS)** for secure pod-to-pod communication
- **Gateway API integration** for standard Kubernetes ingress

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture Overview](#2-architecture-overview)
3. [Installing the RHAII Operator](#3-installing-the-rhaii-operator)
4. [Configuring the Inference Gateway](#4-configuring-the-inference-gateway)
5. [Deploying an LLM Inference Service](#5-deploying-an-llm-inference-service)
6. [Verifying the Deployment](#6-verifying-the-deployment)
7. [Sample Manifests](#7-sample-manifests)
8. [Troubleshooting](#8-troubleshooting)
9. [Uninstall](#9-uninstall)
10. [Appendix: Component Reference](#appendix-component-reference)

---

## 1. Prerequisites

### 1.1 Kubernetes Cluster Requirements

| Requirement | Specification |
|-------------|---------------|
| Kubernetes version | 1.28 or later |
| Supported platforms | AKS, CKS (CoreWeave) |
| GPU nodes | NVIDIA A10, A100, or H100 (for GPU workloads) |
| NVIDIA device plugin | Installed and configured |

### 1.2 Client Tools

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.17+ | Helm package manager |

### 1.3 Registry Authentication

RHAIIS images are hosted on `registry.redhat.io` and `quay.io/rhoai`. Both registries require authentication.

**Procedure:**

1. Create a pull secret file with credentials for all required registries:

   ```bash
   # Red Hat registry (for vLLM and dependency operator images)
   podman login registry.redhat.io --authfile ~/pull-secret.json

   # quay.io (for RHOAI operator and KServe component images)
   podman login quay.io --authfile ~/pull-secret.json
   ```

2. Verify the pull secret covers all required registries:

   ```bash
   cat ~/pull-secret.json | python3 -c \
     "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('auths',{}).keys()))"
   # Should include: quay.io, registry.redhat.io
   ```

3. Log in to the Helm OCI registry (required to pull the chart):

   ```bash
   helm registry login quay.io
   ```

> **Note:** Registry Service Accounts (from https://access.redhat.com/terms-based-registry/) do not expire and are recommended for production deployments.

### 1.4 GPU Node Pool Configuration

For GPU-accelerated inference, ensure your cluster has GPU nodes with the NVIDIA device plugin installed.

**Azure Kubernetes Service (AKS):**

For AKS cluster provisioning with GPU nodes, see the [AKS Infrastructure Guide](https://llm-d.ai/docs/guide/InfraProviders/aks).

**CoreWeave Kubernetes Service (CKS):**

CoreWeave clusters include the NVIDIA device plugin by default. Select the appropriate GPU type when provisioning your cluster.

**Verification:**

```bash
kubectl get nodes -l nvidia.com/gpu.present=true
kubectl describe nodes | grep -A5 "nvidia.com/gpu"
```

---

## 2. Architecture Overview

The RHAII Helm chart deploys the RHAI operator and a cloud-specific manager. The cloud manager automatically provisions infrastructure dependencies.

### 2.1 Deployed Components

| Component | Namespace | Description |
|-----------|-----------|-------------|
| RHAI Operator | `redhat-ods-operator` | Manages KServe controller and inference components |
| Cloud Manager | `rhai-cloudmanager-system` | Provisions infrastructure dependencies |
| KServe LLMISvc Controller | `redhat-ods-applications` | Manages LLMInferenceService lifecycle |
| cert-manager Operator | `cert-manager-operator` | cert-manager operator |
| cert-manager | `cert-manager` | TLS certificate management |
| Istio (Sail Operator) | `istio-system` | Gateway API implementation and mTLS |
| LWS Operator | `openshift-lws-operator` | Multi-node inference support |

### 2.2 Component Interaction

```text
                  +----------------------+
  Client -------- |   Inference Gateway  |
                  |   (Istio / Envoy)    |
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |   EPP Scheduler      |
                  |   (picks optimal     |
                  |    replica)           |
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |   vLLM Pod (GPU)     |
                  |   (serves model)     |
                  +----------------------+
```

### 2.3 Bootstrap Sequence

The cloud manager orchestrates the following bootstrap sequence automatically:

| Component | Action |
|-----------|--------|
| Cloud Manager | Starts provisioning dependencies |
| RHAI Operator | Waits for webhook certificate |
| cert-manager | Operator and controller start |
| Webhook certificate | Issued by cert-manager |
| RHAI Operator | Starts (certificate volume mounted) |
| Istio, LWS | Operators start |
| Serve LLMISvc Controller| Deployed by RHAI Operator |
| All components | Running |

> **Note:** The RHAI operator pods display `FailedMount` warnings during the first 60-90 seconds. This is expected behavior while cert-manager starts and issues the webhook certificate.

---

## 3. Installing the RHAII Operator

For detailed Helm chart configuration options, see the [RHAII Helm Chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md).

### 3.1 Create Values File

Create a `rhoai-values.yaml` with RHOAI EA2 image overrides:

```yaml
azure:
  enabled: true
  cloudManager:
    image: quay.io/rhoai/odh-rhel9-operator:rhoai-3.4-ea.2

coreweave:
  enabled: false
  cloudManager:
    image: quay.io/rhoai/odh-rhel9-operator:rhoai-3.4-ea.2

rhaiOperator:
  image: quay.io/rhoai/odh-rhel9-operator:rhoai-3.4-ea.2
  relatedImages:
  - name: RELATED_IMAGE_ODH_KSERVE_AGENT_IMAGE
    value: quay.io/rhoai/odh-kserve-agent-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_ODH_KSERVE_CONTROLLER_IMAGE
    value: quay.io/rhoai/odh-kserve-controller-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_ODH_KSERVE_LLMISVC_CONTROLLER_IMAGE
    value: quay.io/rhoai/odh-kserve-llmisvc-controller-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_ODH_KSERVE_ROUTER_IMAGE
    value: quay.io/rhoai/odh-kserve-router-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_ODH_KSERVE_STORAGE_INITIALIZER_IMAGE
    value: quay.io/rhoai/odh-kserve-storage-initializer-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_RHAIIS_VLLM_CUDA_IMAGE
    value: registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9:3.4.0-ea.2
  - name: RELATED_IMAGE_RHAIIS_VLLM_ROCM_IMAGE
    value: registry.redhat.io/rhaii-early-access/vllm-rocm-rhel9:3.4.0-ea.2
  - name: RELATED_IMAGE_RHAIIS_VLLM_SPYRE_IMAGE
    value: registry.redhat.io/rhaii-early-access/vllm-spyre-rhel9:3.4.0-ea.2
  - name: RELATED_IMAGE_ODH_LLM_D_INFERENCE_SCHEDULER_IMAGE
    value: quay.io/rhoai/odh-llm-d-inference-scheduler-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_ODH_LLM_D_ROUTING_SIDECAR_IMAGE
    value: quay.io/rhoai/odh-llm-d-routing-sidecar-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_OSE_KUBE_RBAC_PROXY_IMAGE
    value: quay.io/rhoai/odh-kube-auth-proxy-rhel9:rhoai-3.4-ea.2
  - name: RELATED_IMAGE_ODH_LLM_D_KV_CACHE_IMAGE
    value: quay.io/rhoai/odh-llm-d-kv-cache-rhel9:rhoai-3.4-ea.2
```

For CoreWeave, change `azure.enabled: true` to `azure.enabled: false` and add `coreweave.enabled: true`.

> **Note:** vLLM images use `registry.redhat.io/rhaii-early-access/` with tag format `3.4.0-ea.2`. All other RHOAI images use `quay.io/rhoai/` with tag format `rhoai-3.4-ea.2`.

### 3.2 Install on Azure Kubernetes Service

```bash
helm upgrade rhaii oci://quay.io/rhoai/rhai-on-xks-chart \
  --install --create-namespace \
  --namespace rhaii \
  -f rhoai-values.yaml \
  --set-file imagePullSecret.dockerConfigJson=~/pull-secret.json
```

### 3.3 Install on CoreWeave Kubernetes Service

```bash
helm upgrade rhaii oci://quay.io/rhoai/rhai-on-xks-chart \
  --install --create-namespace \
  --namespace rhaii \
  -f rhoai-values.yaml \
  --set coreweave.enabled=true --set azure.enabled=false \
  --set-file imagePullSecret.dockerConfigJson=~/pull-secret.json
```

> **Important:** Do NOT use `--wait`. The chart uses post-install hook Jobs that need CRDs to register first, and the RHAI operator depends on cert-manager to start. Using `--wait` may cause the installation to time out.

> **Important:** Always include `--set-file imagePullSecret.dockerConfigJson=...` in the initial install command. Running without it first and adding it later can cause image pull failures in dependency namespaces.

### 3.4 Verify Operator Deployment

Wait approximately 2 minutes for the bootstrap sequence to complete, then verify all components:

```bash
# RHAI Operator (3 replicas)
kubectl get pods -n redhat-ods-operator

# Cloud Manager
kubectl get pods -n rhai-cloudmanager-system

# KServe LLMISvc Controller
kubectl get pods -n redhat-ods-applications

# cert-manager
kubectl get pods -n cert-manager

# Istio
kubectl get pods -n istio-system

# LWS Operator
kubectl get pods -n openshift-lws-operator
```

All pods should show `Running` status with all containers ready.

Verify the RHOAI image versions:

```bash
# Operator image
kubectl get deploy rhai-operator -n redhat-ods-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# vLLM image env vars
kubectl get deploy rhai-operator -n redhat-ods-operator \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep VLLM
```

---

## 4. Configuring the Inference Gateway

The inference gateway provides external access to LLMInferenceService endpoints via the Gateway API.

### 4.1 Set Up CA Bundle

Extract the CA certificate from cert-manager and create a ConfigMap for mTLS trust between inference components:

```bash
# Extract CA cert from cert-manager secret
kubectl get secret opendatahub-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt

# Create CA bundle ConfigMap
kubectl create configmap odh-ca-bundle \
  --from-file=ca.crt=/tmp/ca.crt \
  -n redhat-ods-applications \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4.2 Create Gateway ConfigMap

Configure the gateway pod to mount the CA bundle for mTLS trust. The service annotation is AKS-specific — it switches the Azure Load Balancer health probe to TCP so it can reach the Istio gateway on port 80. Omit it on CoreWeave:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: inference-gateway-config
  namespace: redhat-ods-applications
data:
  deployment: |
    spec:
      template:
        spec:
          volumes:
          - name: odh-ca-bundle
            configMap:
              name: odh-ca-bundle
          containers:
          - name: istio-proxy
            volumeMounts:
            - name: odh-ca-bundle
              mountPath: /var/run/secrets/opendatahub
              readOnly: true
  service: |
    metadata:
      annotations:
        service.beta.kubernetes.io/port_80_health-probe_protocol: tcp
EOF
```

### 4.3 Create Gateway

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway  # DO NOT CHANGE THIS VALUE
  namespace: redhat-ods-applications
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
    parametersRef:
      group: ""
      kind: ConfigMap
      name: inference-gateway-config
EOF
```

> **Important:** The gateway must be named `inference-gateway`. This name is configured in the `LLMInferenceServiceConfig` templates and used by the controller when `router.gateway: {}` is empty.

### 4.4 Verify Gateway Deployment

```bash
kubectl get gateway -n redhat-ods-applications
```

Expected output:

```text
NAME                CLASS   ADDRESS         PROGRAMMED   AGE
inference-gateway   istio   20.xx.xx.xx     True         1m
```

Verify the gateway pod is running:

```bash
kubectl get pods -n redhat-ods-applications \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

> **Troubleshooting:** If the gateway shows `Programmed: False`, check istiod logs: `kubectl logs deploy/istiod -n istio-system | grep gateway`. A common cause is a missing ConfigMap referenced by `parametersRef`.

---

## 5. Deploying an LLM Inference Service

### 5.1 Create the Application Namespace

```bash
export NAMESPACE=llm-inference
kubectl create namespace $NAMESPACE
```

### 5.2 Copy Pull Secret to Application Namespace

The `rhaii-pull-secret` is only created in chart-managed namespaces. Copy it to your application namespace:

```bash
kubectl get secret rhaii-pull-secret -n redhat-ods-applications -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
      .metadata.annotations, .metadata.labels, .metadata.ownerReferences) |
      .metadata.namespace = "'$NAMESPACE'"' | \
  kubectl apply -f -
```

### 5.3 Deploy the LLMInferenceService

EA2 requires **container name stubs** in the scheduler template when providing `imagePullSecrets`. Without these stubs, the controller replaces the entire template and produces an empty containers list.

```bash
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: single-gpu
spec:
  model:
    uri: hf://Qwen/Qwen3-0.6B
    name: Qwen/Qwen3-0.6B
  replicas: 1
  router:
    scheduler:
      template:
        imagePullSecrets:
        - name: rhaii-pull-secret
        containers:
        - name: main        # scheduler (EPP)
        - name: tokenizer   # kv-cache / tokenizer sidecar
    route: {}
    gateway: {}
  template:
    imagePullSecrets:
    - name: rhaii-pull-secret
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

### 5.3 Monitor Deployment Progress

```bash
kubectl get llmisvc -n $NAMESPACE -w
```

The service is ready when the `READY` column shows `True`. Model download and loading typically takes 3-5 minutes depending on network speed and model size.

---

## 6. Verifying the Deployment

### 6.1 Check Service Status

```bash
kubectl get llmisvc -n $NAMESPACE
```

Expected output:

```text
NAME         URL                                                  READY   AGE
single-gpu   http://20.xx.xx.xx/llm-inference/single-gpu          True    5m
```

### 6.2 Check Pod Status

```bash
kubectl get pods -n $NAMESPACE
```

All pods should show `Running` status:

```text
NAME                                                          READY   STATUS    AGE
single-gpu-kserve-xxxxxxxxx-xxxxx                             1/1     Running   5m
single-gpu-kserve-router-scheduler-xxxxxxxxx-xxxxx            2/2     Running   5m
```

### 6.3 Test Inference

```bash
SERVICE_URL=$(kubectl get llmisvc single-gpu -n $NAMESPACE \
  -o jsonpath='{.status.url}')

curl -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 100
  }'
```

---

## 7. Sample Manifests

Ready-to-use LLMInferenceService manifests are available in the [llm-d-conformance-manifests](https://github.com/aneeshkp/llm-d-conformance-manifests/tree/3.4-ea2) repository (branch `3.4-ea2`).

### Available Manifests

| Manifest | Description | GPUs | Features |
|----------|-------------|------|----------|
| [`single-gpu.yaml`](https://github.com/aneeshkp/llm-d-conformance-manifests/blob/3.4-ea2/single-gpu.yaml) | Single GPU with EPP scheduler | 1 | Scheduler with container stubs |
| [`single-gpu-smoke.yaml`](https://github.com/aneeshkp/llm-d-conformance-manifests/blob/3.4-ea2/single-gpu-smoke.yaml) | Minimal smoke test | 1 | Low resource requests |
| [`single-gpu-no-scheduler.yaml`](https://github.com/aneeshkp/llm-d-conformance-manifests/blob/3.4-ea2/single-gpu-no-scheduler.yaml) | K8s native routing (no EPP) | 1 | No scheduler |
| [`cache-aware.yaml`](https://github.com/aneeshkp/llm-d-conformance-manifests/blob/3.4-ea2/cache-aware.yaml) | Prefix KV cache-aware routing | 2 | `scheduler.config.inline` with `precise-prefix-cache-scorer` |
| [`pd.yaml`](https://github.com/aneeshkp/llm-d-conformance-manifests/blob/3.4-ea2/pd.yaml) | Prefill/Decode disaggregation | 3+ | NixlConnector KV transfer |
| [`moe.yaml`](https://github.com/aneeshkp/llm-d-conformance-manifests/blob/3.4-ea2/moe.yaml) | MoE with DP/EP | 8 | RDMA/RoCE, multi-node |

### Quick Deploy

```bash
# Clone the manifests
git clone -b 3.4-ea2 https://github.com/aneeshkp/llm-d-conformance-manifests.git
cd llm-d-conformance-manifests

# Deploy single GPU test
kubectl apply -n $NAMESPACE -f single-gpu.yaml

# Or deploy smoke test (lower resources)
kubectl apply -n $NAMESPACE -f single-gpu-smoke.yaml
```

### EA2 Key Differences from EA1

| Feature | EA1 | EA2 |
|---------|-----|-----|
| Pull secret name | `redhat-pull-secret` | `rhaii-pull-secret` |
| Scheduler config | verbose `args[]` | `scheduler.config.inline` |
| Cache scorer plugin | `prefix-cache-scorer` | `precise-prefix-cache-scorer` |
| Scheduler template | Not required | Container stubs required with `imagePullSecrets` |

---

## 8. Troubleshooting

### 8.1 RHAI Operator Pods Stuck in ContainerCreating

**Symptom:** The `rhai-operator` pods remain in `ContainerCreating` state.

**Cause:** The operator mounts a webhook certificate secret that cert-manager issues. This is expected for 1-2 minutes during initial deployment.

**Resolution:**

Wait for cert-manager to start and issue the certificate:

```bash
kubectl get certificate -n redhat-ods-operator
```

If the certificate does not appear after 5 minutes, check the cloud manager logs:

```bash
kubectl logs deployment/azure-cloud-manager-operator \
  -n rhai-cloudmanager-system --tail=30
```

### 8.2 Dependency Pods Show ImagePullBackOff

**Symptom:** Pods in `openshift-lws-operator`, `cert-manager`, or `istio-system` show `ImagePullBackOff`.

**Cause:** The pull secret credentials are invalid or don't cover the required registries.

**Resolution:**

Verify the pull secret works locally:

```bash
podman pull registry.redhat.io/ubi9/ubi-minimal --authfile ~/pull-secret.json
```

If the credentials are invalid, update the pull secret and re-run `helm upgrade` to push the updated secret to all namespaces. Then restart failing pods.

### 8.3 Gateway Shows Programmed: False

**Symptom:** `kubectl get gateway -n redhat-ods-applications` shows `Programmed: False`.

**Cause:** Missing ConfigMap referenced by `parametersRef`, or the CA bundle ConfigMap does not exist.

**Resolution:**

Check istiod logs:

```bash
kubectl logs deploy/istiod -n istio-system | grep gateway
```

Ensure both ConfigMaps exist:

```bash
kubectl get configmap inference-gateway-config odh-ca-bundle \
  -n redhat-ods-applications
```

### 8.4 Scheduler Deployment Fails with "containers: Required value"

**Symptom:** The LLMInferenceService shows `SchedulerReconcileError` and the controller logs show:

```text
Deployment.apps "xxx-kserve-router-scheduler" is invalid: spec.template.spec.containers: Required value
```

**Cause:** The scheduler template in the LLMInferenceService spec has `imagePullSecrets` but no container name stubs. KServe replaces the entire template, resulting in empty containers.

**Resolution:**

Add container stubs to the scheduler template:

```yaml
router:
  scheduler:
    template:
      imagePullSecrets:
      - name: rhaii-pull-secret
      containers:
      - name: main        # scheduler (EPP)
      - name: tokenizer   # kv-cache / tokenizer sidecar
```

See the [conformance manifests](https://github.com/aneeshkp/llm-d-conformance-manifests/tree/3.4-ea2) for working examples.

### 8.5 LLMInferenceService Shows RefsInvalid

**Symptom:** The LLMInferenceService status shows `RefsInvalid` with message about non-existent gateway.

**Cause:** The gateway name does not match what the controller expects. When `router.gateway: {}` is empty, it defaults to `inference-gateway` in `redhat-ods-applications`.

**Resolution:**

Either create a gateway named `inference-gateway` (see Section 4), or specify the gateway explicitly:

```yaml
router:
  gateway:
    refs:
    - name: my-gateway-name
      namespace: redhat-ods-applications
```

---

## 9. Uninstall

### 9.1 Delete LLM Inference Services

```bash
kubectl delete llmisvc --all -n llm-inference
kubectl delete namespace llm-inference
```

### 9.2 Uninstall the RHAII Operator

```bash
helm uninstall rhaii -n rhaii
```

CRDs are not removed on uninstall. To remove them manually:

```bash
kubectl delete crd kserves.components.platform.opendatahub.io
kubectl delete crd azurekubernetesengines.infrastructure.opendatahub.io
kubectl delete crd llminferenceservices.serving.kserve.io
kubectl delete crd llminferenceserviceconfigs.serving.kserve.io
```

---

## Appendix: Component Reference

### Namespaces

| Namespace | Owner | Description |
|-----------|-------|-------------|
| `rhaii` | Helm | Helm release metadata |
| `redhat-ods-operator` | RHAI Operator | Operator deployment and webhooks |
| `redhat-ods-applications` | RHAI Operator | KServe controller, inference gateway |
| `rhai-cloudmanager-system` | Helm | Cloud manager operator |
| `cert-manager-operator` | Cloud Manager | cert-manager operator deployment |
| `cert-manager` | Cloud Manager | cert-manager controller and webhooks |
| `istio-system` | Cloud Manager | Istio control plane |
| `openshift-lws-operator` | Cloud Manager | LeaderWorkerSet operator |

### Image References

| Component | Image |
|-----------|-------|
| RHAI Operator | `quay.io/rhoai/odh-rhel9-operator:rhoai-3.4-ea.2` |
| KServe LLMISvc Controller | `quay.io/rhoai/odh-kserve-llmisvc-controller-rhel9:rhoai-3.4-ea.2` |
| KServe Router | `quay.io/rhoai/odh-kserve-router-rhel9:rhoai-3.4-ea.2` |
| EPP Scheduler | `quay.io/rhoai/odh-llm-d-inference-scheduler-rhel9:rhoai-3.4-ea.2` |
| vLLM (CUDA) | `registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9:3.4.0-ea.2` |
| vLLM (ROCm) | `registry.redhat.io/rhaii-early-access/vllm-rocm-rhel9:3.4.0-ea.2` |
| KV Cache / Tokenizer | `quay.io/rhoai/odh-llm-d-kv-cache-rhel9:rhoai-3.4-ea.2` |

### API Versions

| API | Group | Version | Status |
|-----|-------|---------|--------|
| LLMInferenceService | `serving.kserve.io` | v1alpha1 / v1alpha2 | Alpha |
| LLMInferenceServiceConfig | `serving.kserve.io` | v1alpha2 | Alpha |
| InferencePool | `inference.networking.k8s.io` | v1 | GA |
| Gateway | `gateway.networking.k8s.io` | v1 | GA |

---

## Support

For assistance with Red Hat AI Inference Server deployments, contact Red Hat Support or consult the product documentation.

**Additional Resources:**

* [RHAII Helm Chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md) — Helm chart configuration and values reference
* [LLM-D Conformance Manifests (EA2)](https://github.com/aneeshkp/llm-d-conformance-manifests/tree/3.4-ea2) — Ready-to-use LLMInferenceService manifests
* [Deploying on AKS/CoreWeave — EA1 (Helmfile)](./deploying-llm-d-on-managed-kubernetes.md) — EA1 deployment using helmfile with individual operator charts
* [KServe LLMInferenceService Samples](https://github.com/red-hat-data-services/kserve/tree/rhoai-3.4/docs/samples/llmisvc) — Example inference service configurations
