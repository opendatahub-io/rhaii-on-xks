# Deploying Red Hat AI Inference Server on Managed Kubernetes

**Product:** Red Hat AI Inference Server (RHAIIS)
**Version:** 0.15
**Platforms:** Azure Kubernetes Service (AKS), CoreWeave Kubernetes Service (CKS)

---

## Executive Summary

This guide provides step-by-step instructions for deploying Red Hat AI Inference Server on managed Kubernetes platforms. Red Hat AI Inference Server enables enterprise-grade Large Language Model (LLM) inference with features including:

- **Intelligent request routing** using the Endpoint Picker Processor (EPP)
- **Disaggregated serving** with prefill-decode separation for optimal throughput
- **Multi-node inference** for large models using LeaderWorkerSet
- **Mutual TLS (mTLS)** for secure communication between components
- **Gateway API integration** for standard Kubernetes ingress

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture Overview](#2-architecture-overview)
3. [Deploying Infrastructure Components](#3-deploying-infrastructure-components)
4. [Deploying the Inference Controller](#4-deploying-the-inference-controller)
5. [Configuring the Inference Gateway](#5-configuring-the-inference-gateway)
6. [Deploying an LLM Inference Service](#6-deploying-an-llm-inference-service)
7. [Verifying the Deployment](#7-verifying-the-deployment)
8. [Optional: Enabling Monitoring](#8-optional-enabling-monitoring)
9. [Troubleshooting](#9-troubleshooting)
10. [Appendix: Component Versions](#appendix-component-versions)

---

## 1. Prerequisites

### 1.1 Kubernetes Cluster Requirements

| Requirement | Specification |
|-------------|---------------|
| Kubernetes Version | 1.28 or later |
| Supported Platforms | AKS, CKS (CoreWeave) |
| GPU Nodes | NVIDIA A10, A100, or H100 (for GPU workloads) |
| NVIDIA Device Plugin | Installed and configured |

### 1.2 Client Tools

Install the following tools on your workstation:

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.17+ | Helm package manager |
| `helmfile` | 0.160+ | Declarative Helm deployments |
| `kustomize` | 5.7+ | Kubernetes manifest customization |

### 1.3 Red Hat Registry Authentication

Red Hat AI Inference Server images are hosted on `registry.redhat.io` and require authentication.

**Procedure:**

1. Navigate to the Red Hat Registry Service Accounts page:
   https://access.redhat.com/terms-based-registry/

2. Click **New Service Account** and create a new service account.

3. Note the generated username (format: `12345678|account-name`) and password.

4. Authenticate with the registry:

   ```bash
   podman login registry.redhat.io
   ```

   Enter the service account username and password when prompted.

5. Verify authentication:

   ```bash
   # Verify access to Sail Operator image
   podman pull registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle:3.2

   # Verify access to RHAIIS vLLM image
   podman pull registry.redhat.io/rhaiis-tech-preview/vllm-openai-rhel9:latest
   ```

   Credentials are stored automatically in `~/.config/containers/auth.json` after successful login.

> **Note:** Registry Service Accounts do not expire and are recommended for production deployments.

### 1.4 GPU Node Pool Configuration

For GPU-accelerated inference, ensure your cluster has GPU nodes with the NVIDIA device plugin installed.

**Azure Kubernetes Service (AKS)**

For detailed AKS cluster setup including GPU node pools, see the [AKS Infrastructure Guide](https://llm-d.ai/docs/guide/InfraProviders/aks).

**CoreWeave Kubernetes Service (CKS)**

CoreWeave clusters come with GPU nodes pre-configured. Select the appropriate GPU type when provisioning your cluster:

| GPU Type | Use Case |
|----------|----------|
| NVIDIA A100 80GB | Large models (70B+), high throughput |
| NVIDIA A100 40GB | Medium models (7B-30B) |
| NVIDIA H100 80GB | Maximum performance, largest models |

CoreWeave GPU nodes include the NVIDIA device plugin by default.

**Verification:**

```bash
kubectl get nodes -l nvidia.com/gpu.present=true
kubectl describe nodes | grep -A5 "nvidia.com/gpu"
```

---

## 2. Architecture Overview

Red Hat AI Inference Server on managed Kubernetes consists of the following components:

| Component | Description |
|-----------|-------------|
| **cert-manager** | Manages TLS certificates for mTLS between components |
| **Istio (Sail Operator)** | Provides Gateway API implementation for inference routing |
| **LeaderWorkerSet (LWS)** | Enables multi-node inference for large models |
| **KServe Controller** | Manages LLMInferenceService lifecycle |
| **Inference Gateway** | Routes external traffic to inference endpoints |

### Component Interaction

```
                                    ┌─────────────────────────────────────┐
                                    │         Kubernetes Cluster          │
┌──────────┐    ┌──────────────┐    │  ┌─────────┐    ┌────────────────┐  │
│  Client  │───▶│   Gateway    │───▶│  │   EPP   │───▶│  vLLM Pods     │  │
│          │    │   (Istio)    │    │  │Scheduler│    │  (Model)       │  │
└──────────┘    └──────────────┘    │  └─────────┘    └────────────────┘  │
                                    │        ▲               ▲            │
                                    │        │    mTLS      │            │
                                    │        └───────────────┘            │
                                    │              cert-manager           │
                                    └─────────────────────────────────────┘
```

---

## 3. Deploying Infrastructure Components

### 3.1 Clone the Deployment Repository

```bash
git clone https://github.com/aneeshkp/llm-d-infra-xks.git
cd llm-d-infra-xks
```

### 3.2 Deploy Infrastructure

Deploy cert-manager, Istio (Sail Operator), and LeaderWorkerSet:

```bash
make deploy-all
```

### 3.3 Verify Infrastructure Deployment

```bash
make status
```

**Expected output:**

```
=== Deployment Status ===
cert-manager-operator:
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-operator-xxxxxxxxx-xxxxx      1/1     Running   0          5m

cert-manager:
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxx-xxxxx               1/1     Running   0          5m
cert-manager-cainjector-xxxxxxxxx-xxxxx    1/1     Running   0          5m
cert-manager-webhook-xxxxxxxxx-xxxxx       1/1     Running   0          5m

istio:
NAME                                       READY   STATUS    RESTARTS   AGE
istiod-xxxxxxxxx-xxxxx                     1/1     Running   0          5m

lws-operator:
NAME                                       READY   STATUS    RESTARTS   AGE
lws-controller-manager-xxxxxxxxx-xxxxx     1/1     Running   0          5m

=== API Versions ===
InferencePool API: v1 (inference.networking.k8s.io)
Istio version: v1.27.5
```

---

## 4. Deploying the Inference Controller

### 4.1 Deploy KServe Controller

```bash
make deploy-kserve
```

This command performs the following actions:
- Creates the `opendatahub` namespace
- Applies cert-manager PKI resources for webhook certificates
- Deploys the KServe controller with LLMInferenceService support
- Configures validating webhooks

### 4.2 Verify Controller Deployment

```bash
kubectl get pods -n opendatahub
```

**Expected output:**

```
NAME                                        READY   STATUS    RESTARTS   AGE
kserve-controller-manager-xxxxxxxxx-xxxxx   1/1     Running   0          2m
```

Verify the LLMInferenceServiceConfig templates are installed:

```bash
kubectl get llminferenceserviceconfig -n opendatahub
```

---

## 5. Configuring the Inference Gateway

### 5.1 Create the Gateway

Run the gateway setup script:

```bash
./scripts/setup-gateway.sh
```

This script:
1. Copies the CA bundle from cert-manager to the opendatahub namespace
2. Creates an Istio Gateway with the CA bundle mounted for mTLS
3. Configures the Gateway pod with registry authentication

### 5.2 Verify Gateway Deployment

```bash
kubectl get gateway -n opendatahub
```

**Expected output:**

```
NAME                CLASS   ADDRESS         PROGRAMMED   AGE
inference-gateway   istio   20.xx.xx.xx     True         1m
```

Verify the Gateway pod is running:

```bash
kubectl get pods -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

---

## 6. Deploying an LLM Inference Service

### 6.1 Create the Application Namespace

```bash
export NAMESPACE=llm-inference
kubectl create namespace $NAMESPACE
```

### 6.2 Configure Registry Authentication

Copy the pull secret to your application namespace:

```bash
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "'$NAMESPACE'"' | \
  kubectl create -f -
```

Configure the default ServiceAccount:

```bash
kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'
```

### 6.3 Deploy the LLMInferenceService

Create the LLMInferenceService resource:

```bash
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
    scheduler: {}
  template:
    spec:
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "present"
        effect: "NoSchedule"
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
```

### 6.4 Monitor Deployment Progress

Watch the LLMInferenceService status:

```bash
kubectl get llmisvc -n $NAMESPACE -w
```

The service is ready when the `READY` column shows `True`.

---

## 7. Verifying the Deployment

### 7.1 Check Service Status

```bash
kubectl get llmisvc -n $NAMESPACE
```

**Expected output:**

```
NAME                READY   URL                                    AGE
qwen2-7b-instruct   True    http://20.xx.xx.xx/llm-inference/...   5m
```

### 7.2 Check Pod Status

```bash
kubectl get pods -n $NAMESPACE
```

All pods should show `Running` status with `1/1` or `2/2` ready containers.

### 7.3 Test Inference

Retrieve the service URL:

```bash
SERVICE_URL=$(kubectl get llmisvc qwen2-7b-instruct -n $NAMESPACE -o jsonpath='{.status.url}')
echo $SERVICE_URL
```

Send a test request:

```bash
curl -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 100
  }'
```

---

## 8. Optional: Enabling Monitoring

Monitoring is disabled by default. Enable it if you need:
- Grafana dashboards for inference metrics
- Workload Variant Autoscaler (WVA) for auto-scaling

### 8.1 Prerequisites

Install Prometheus with ServiceMonitor/PodMonitor CRD support. See the [Monitoring Setup Guide](../monitoring-stack/) for platform-specific instructions.

### 8.2 Enable Monitoring in KServe

```bash
kubectl set env deployment/kserve-controller-manager \
  -n opendatahub \
  LLMISVC_MONITORING_DISABLED=false
```

When enabled, KServe automatically creates `PodMonitor` resources for vLLM pods.

### 8.3 Verify

```bash
# Check PodMonitors created by KServe
kubectl get podmonitors -n <llmisvc-namespace>
```

---

## 9. Troubleshooting

### 9.1 Controller Pod Stuck in ContainerCreating

**Symptom:** The `kserve-controller-manager` pod remains in `ContainerCreating` state.

**Cause:** The webhook certificate has not been issued by cert-manager.

**Resolution:**

```bash
kubectl apply -k "https://github.com/opendatahub-io/kserve/config/overlays/odh-test/cert-manager?ref=release-v0.15"
kubectl wait --for=condition=Ready certificate/kserve-webhook-server -n opendatahub --timeout=120s
```

### 9.2 Gateway Pod Shows ErrImagePull

**Symptom:** The Gateway pod fails with `ErrImagePull` or `ImagePullBackOff`.

**Cause:** The Gateway ServiceAccount does not have registry authentication configured.

**Resolution:**

```bash
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "opendatahub"' | \
  kubectl create -f -

kubectl patch sa inference-gateway-istio -n opendatahub \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

kubectl delete pod -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

### 9.3 LLMInferenceService Pod Shows FailedScheduling

**Symptom:** The inference pod shows `FailedScheduling` with message "Insufficient nvidia.com/gpu".

**Cause:** No GPU nodes are available or the pod lacks required tolerations.

**Resolution:**

1. Verify GPU nodes are available:
   ```bash
   kubectl get nodes -l nvidia.com/gpu.present=true
   ```

2. Check node taints:
   ```bash
   kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.taints}{"\n"}{end}'
   ```

3. Add matching tolerations to the LLMInferenceService spec (see Section 6.3).

### 9.4 Webhook Validation Errors During Deployment

**Symptom:** Deployment fails with "no endpoints available for service" webhook errors.

**Cause:** Webhooks are registered before the controller is ready.

**Resolution:**

```bash
kubectl delete validatingwebhookconfiguration \
  llminferenceservice.serving.kserve.io \
  llminferenceserviceconfig.serving.kserve.io \
  --ignore-not-found

make deploy-kserve
```

---

## Appendix: Component Versions

| Component | Version | Container Image |
|-----------|---------|-----------------|
| cert-manager Operator | 1.15.2 | `registry.redhat.io/cert-manager/cert-manager-operator-rhel9` |
| Sail Operator (Istio) | 3.2.1 | `registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle:3.2` |
| Istio | 1.27.x | Dynamic resolution via `v1.27-latest` |
| LeaderWorkerSet | 1.0 | `registry.k8s.io/lws/lws-controller` |
| KServe Controller | 0.15 | `quay.io/opendatahub/kserve-controller` |
| vLLM | Latest | `registry.redhat.io/rhaiis-tech-preview/vllm-openai-rhel9` |

### API Versions

| API | Group | Version | Status |
|-----|-------|---------|--------|
| InferencePool | `inference.networking.k8s.io` | v1 | GA |
| InferenceModel | `inference.networking.x-k8s.io` | v1alpha2 | Alpha |
| LLMInferenceService | `serving.kserve.io` | v1alpha1 | Alpha |
| Gateway | `gateway.networking.k8s.io` | v1 | GA |

---

## Support

For assistance with Red Hat AI Inference Server deployments, contact Red Hat Support or consult the product documentation.

**Additional Resources:**
- [Monitoring Setup Guide](../monitoring-stack/) - Optional Prometheus/Grafana configuration for dashboards and autoscaling
- [KServe LLMInferenceService Samples](https://github.com/opendatahub-io/kserve/tree/main/docs/samples/llmisvc)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Istio Documentation](https://istio.io/latest/docs/)
