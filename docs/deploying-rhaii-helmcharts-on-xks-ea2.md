# Deploying Red Hat AI Inference Server on Managed Kubernetes

**Product:** Red Hat AI Inference Server (RHAIIS)
**Version:** 3.4 EA2
**Platforms:** Azure Kubernetes Service (AKS), CoreWeave Kubernetes Service (CKS)

---

## Executive Summary

This guide provides step-by-step instructions for deploying Red Hat AI Inference Server on managed Kubernetes platforms using the RHAII Helm chart. The Helm chart deploys the RHAI operator and a cloud-specific manager, which together automatically provision all required infrastructure including cert-manager, Istio, and LeaderWorkerSet.

Key capabilities:

- **Single-command installation** using Helm
- **Automatic infrastructure provisioning** via the cloud manager
- **Intelligent request routing** using the Endpoint Picker Processor (EPP)
- **Mutual TLS (mTLS)** for secure pod-to-pod communication
- **Gateway API integration** for standard Kubernetes ingress

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture Overview](#2-architecture-overview)
3. [Installing the RHAII Operator](#3-installing-the-rhaii-operator)
4. [Deploying an LLM Inference Service](#4-deploying-an-llm-inference-service)
5. [Verifying the Deployment](#5-verifying-the-deployment)
6. [Troubleshooting](#6-troubleshooting)
7. [Uninstall](#7-uninstall)
8. [Appendix: Component Reference](#appendix-component-reference)

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

Install the following tools on your workstation:

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.17+ | Helm package manager |

### 1.3 Red Hat Registry Authentication

Red Hat AI Inference Server images are hosted on `registry.redhat.io` and require authentication.

**Procedure:**

1. Navigate to the [Red Hat Registry Service Accounts](https://access.redhat.com/terms-based-registry/) page.

2. Click **New Service Account** and create a new service account.

3. Note the generated username (format: `12345678|account-name`) and password.

4. Authenticate with the registry:

   ```bash
   podman login registry.redhat.io
   ```

   Enter the service account username and password when prompted.

5. Save the pull secret for Helm installation:

   ```bash
   mkdir -p ~/.config/containers
   cp ~/.config/containers/auth.json ~/pull-secret.json
   ```

6. Verify authentication:

   ```bash
   podman pull registry.redhat.io/rhaiis/vllm-cuda-rhel9:latest
   ```

> **Note:** Registry Service Accounts do not expire and are recommended for production deployments.

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
| KServe Controller | `redhat-ods-applications` | Manages LLMInferenceService lifecycle |
| cert-manager Operator | `cert-manager-operator` | cert-manager operator |
| cert-manager | `cert-manager` | TLS certificate management |
| Istio (Sail Operator) | `istio-system` | Gateway API implementation and mTLS |
| LWS Operator | `openshift-lws-operator` | Multi-node inference support |

### 2.2 Component Interaction

```text
                  ┌──────────────────────┐
  Client ──────── │   Inference Gateway  │
                  │   (Istio / Envoy)    │
                  └──────────┬───────────┘
                             │
                  ┌──────────▼───────────┐
                  │   EPP Scheduler      │
                  │   (picks optimal     │
                  │    replica)           │
                  └──────────┬───────────┘
                             │
                  ┌──────────▼───────────┐
                  │   vLLM Pod (GPU)     │
                  │   (serves model)     │
                  └──────────────────────┘
```

### 2.3 Bootstrap Sequence

The cloud manager orchestrates the following bootstrap sequence automatically:

| Time | Component | Action |
|------|-----------|--------|
| T+0s | Cloud Manager | Starts provisioning dependencies |
| T+0s | RHAI Operator | Waits for webhook certificate |
| T+~30s | cert-manager | Operator and controller start |
| T+~60s | Webhook certificate | Issued by cert-manager |
| T+~60s | RHAI Operator | Starts (certificate volume mounted) |
| T+~90s | Istio, LWS | Operators start |
| T+~120s | KServe Controller | Deployed by RHAI Operator |
| T+~2 min | All components | Running |

> **Note:** The RHAI operator pods display `FailedMount` warnings during the first 60-90 seconds. This is expected behavior while cert-manager starts and issues the webhook certificate.

---

## 3. Installing the RHAII Operator

For detailed Helm chart configuration options, see the [RHAII Helm Chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md).

### 3.1 Install on Azure Kubernetes Service

```bash
helm upgrade rhaii ./charts/rhai-on-xks-chart/ \
  --install --create-namespace \
  --namespace rhaii \
  --set azure.enabled=true \
  --set-file imagePullSecret.dockerConfigJson=~/pull-secret.json
```

### 3.2 Install on CoreWeave Kubernetes Service

```bash
helm upgrade rhaii ./charts/rhai-on-xks-chart/ \
  --install --create-namespace \
  --namespace rhaii \
  --set coreweave.enabled=true \
  --set-file imagePullSecret.dockerConfigJson=~/pull-secret.json
```

> **Important:** Always include `--set-file imagePullSecret.dockerConfigJson=...` in the initial install command. Running without it first and adding it later can cause image pull failures in dependency namespaces.

### 3.3 Verify Operator Deployment

Wait approximately 2 minutes for the bootstrap sequence to complete, then verify all components:

```bash
# RHAI Operator (3 replicas)
kubectl get pods -n redhat-ods-operator

# Cloud Manager
kubectl get pods -n rhai-cloudmanager-system

# KServe Controller
kubectl get pods -n redhat-ods-applications

# cert-manager
kubectl get pods -n cert-manager

# Istio
kubectl get pods -n istio-system

# LWS Operator
kubectl get pods -n openshift-lws-operator
```

All pods should show `Running` status with all containers ready.

Verify the inference gateway is programmed:

```bash
kubectl get gateway -n redhat-ods-applications
```

Expected output:

```text
NAME                CLASS   ADDRESS         PROGRAMMED   AGE
inference-gateway   istio   20.xx.xx.xx     True         1m
```

---

## 4. Deploying an LLM Inference Service

### 4.1 Create the Application Namespace

```bash
export NAMESPACE=llm-inference
kubectl create namespace $NAMESPACE
```

### 4.2 Configure Registry Authentication

Copy the pull secret to the application namespace:

```bash
kubectl get secret rhaii-pull-secret -n redhat-ods-applications -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
      .metadata.annotations, .metadata.labels, .metadata.ownerReferences) |
      .metadata.namespace = "'$NAMESPACE'"' | \
  kubectl apply -f -
```

Configure the default ServiceAccount:

```bash
kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "rhaii-pull-secret"}]}'
```

### 4.3 Deploy the LLMInferenceService

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

### 4.4 Monitor Deployment Progress

Watch the LLMInferenceService status:

```bash
kubectl get llmisvc -n $NAMESPACE -w
```

The service is ready when the `READY` column shows `True`. Model download and loading typically takes 3-5 minutes depending on network speed and model size.

---

## 5. Verifying the Deployment

### 5.1 Check Service Status

```bash
kubectl get llmisvc -n $NAMESPACE
```

Expected output:

```text
NAME                 URL                                                     READY   AGE
qwen2-7b-instruct   http://20.xx.xx.xx/llm-inference/qwen2-7b-instruct      True    5m
```

### 5.2 Check Pod Status

```bash
kubectl get pods -n $NAMESPACE
```

All pods should show `Running` status:

```text
NAME                                                          READY   STATUS    AGE
qwen2-7b-instruct-kserve-xxxxxxxxx-xxxxx                     1/1     Running   5m
qwen2-7b-instruct-kserve-router-scheduler-xxxxxxxxx-xxxxx    2/2     Running   5m
```

### 5.3 Test Inference

Retrieve the service URL:

```bash
SERVICE_URL=$(kubectl get llmisvc qwen2-7b-instruct -n $NAMESPACE \
  -o jsonpath='{.status.url}')
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

Expected response:

```json
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Kubernetes, often referred to as \"K8s,\" is an open-source container orchestration system..."
      },
      "finish_reason": "length"
    }
  ],
  "model": "Qwen/Qwen2.5-7B-Instruct",
  "usage": {
    "prompt_tokens": 33,
    "completion_tokens": 100,
    "total_tokens": 133
  }
}
```

---

## 6. Troubleshooting

### 6.1 RHAI Operator Pods Stuck in ContainerCreating

**Symptom:** The `rhods-operator` pods remain in `ContainerCreating` state.

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

### 6.2 Dependency Pods Show ImagePullBackOff

**Symptom:** Pods in `openshift-lws-operator` or `istio-system` show `ImagePullBackOff`.

**Cause:** The pull secret was not distributed to dependency namespaces. This can occur if the initial `helm upgrade` was run without `--set-file imagePullSecret.dockerConfigJson=...`.

**Resolution:**

Copy the pull secret manually:

```bash
kubectl create secret docker-registry rhaii-pull-secret \
  --namespace <failing-namespace> \
  --from-file=.dockerconfigjson=~/pull-secret.json
```

Then restart the affected deployments:

```bash
# Restart only the affected deployment (preferred)
kubectl rollout restart deployment -n <failing-namespace> <affected-deployment>

# Or delete only the failing pods by label
kubectl delete pod -n <failing-namespace> -l app=<affected-app>
```

### 6.3 Gateway Shows No External IP

**Symptom:** `kubectl get gateway -n redhat-ods-applications` shows no ADDRESS.

**Cause:** The gateway pod may have failed to start, or the cloud load balancer is still provisioning.

**Resolution:**

Check the gateway pod status:

```bash
kubectl get pods -n redhat-ods-applications \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway

kubectl describe pod -n redhat-ods-applications \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

If the pod shows `ErrImagePull`, verify the pull secret is available in the `redhat-ods-applications` namespace.

### 6.4 LLMInferenceService Stuck on Not Ready

**Symptom:** The LLMInferenceService remains in a not-ready state.

**Cause:** The vLLM pod may be downloading the model, waiting for GPU scheduling, or missing the pull secret.

**Resolution:**

```bash
# Check pod status
kubectl get pods -n $NAMESPACE

# Check pod events
kubectl describe pod -n $NAMESPACE -l serving.kserve.io/llminferenceservice=qwen2-7b-instruct

# Check vLLM logs
kubectl logs -n $NAMESPACE -l serving.kserve.io/llminferenceservice=qwen2-7b-instruct
```

---

## 7. Uninstall

### 7.1 Delete LLM Inference Services

```bash
kubectl delete llmisvc --all -n llm-inference
kubectl delete namespace llm-inference
```

### 7.2 Uninstall the RHAII Operator

```bash
helm uninstall rhaii -n rhaii
```

CRDs are not removed on uninstall. To remove them manually:

```bash
kubectl get crd -o name | grep -E "opendatahub.io|serving.kserve.io|inference.networking" | xargs -r kubectl delete
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

### API Versions

| API | Group | Version | Status |
|-----|-------|---------|--------|
| LLMInferenceService | `serving.kserve.io` | v1alpha1 | Alpha |
| Gateway | `gateway.networking.k8s.io` | v1 | GA |

---

## Support

For assistance with Red Hat AI Inference Server deployments, contact Red Hat Support or consult the product documentation.

**Additional Resources:**

* [RHAII Helm Chart README](https://github.com/opendatahub-io/odh-gitops/blob/main/charts/rhai-on-xks-chart/README.md) — Helm chart configuration and installation
* [KServe LLMInferenceService Samples](https://github.com/red-hat-data-services/kserve/tree/rhoai-3.4/docs/samples/llmisvc) — Example inference service configurations
