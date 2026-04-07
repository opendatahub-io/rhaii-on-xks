# Deploying Red Hat AI Inference Server: Distributed Inference with llm-d on OpenShift

**Product:** Red Hat AI Inference Server (RHAIIS)
**Version:** 3.4
**Platform:** OpenShift 4.19+

---

## Overview

This guide covers deploying the inference-only stack (KServe + distributed inference with llm-d) on OpenShift using OLM (Operator Lifecycle Manager) via the [odh-gitops](https://github.com/opendatahub-io/odh-gitops) Helm chart. This installs only model serving capabilities without the full RHOAI/ODH platform.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [What Gets Installed](#2-what-gets-installed)
3. [Installation](#3-installation)
4. [Enabling Authorino TLS](#4-enabling-authorino-tls)
5. [Verification](#5-verification)
6. [Deploying an LLM Inference Service](#6-deploying-an-llm-inference-service)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Prerequisites

### 1.1 Cluster Requirements

| Requirement | Specification |
|-------------|---------------|
| OpenShift Version | 4.19 or later |
| GPU Nodes | Supported NVIDIA/AMD GPU nodes |
| GPU Operator | [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html) installed |

### 1.2 Client Tools

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) or [`kubectl`](https://kubernetes.io/docs/tasks/tools/) | 1.33+ | Kubernetes / OpenShift CLI |
| [`helm`](https://helm.sh/docs/intro/install/) | 3.17+ | Helm package manager |

### 1.3 Permissions

Cluster admin permissions are required to install OLM operators and create cluster-scoped resources.

---

## 2. What Gets Installed

The inference-only stack installs a minimal set of operators via OLM:

| Operator | Purpose | Namespace |
|----------|---------|-----------|
| cert-manager | Certificate management and TLS provisioning | `cert-manager-operator` |
| Leader Worker Set | Distributed inference workflows | `openshift-lws-operator` |
| Red Hat Connectivity Link (RHCL) | API management (Kuadrant/Authorino) | `kuadrant-system` |
| ODH/RHOAI Operator | KServe controller and LLMInferenceService lifecycle | `redhat-ods-applications` |

The Helm chart also creates:
- **DSCInitialization** (DSCI) with monitoring disabled
- **DataScienceCluster** (DSC) with only KServe set to `Managed`
- **GatewayClass** (`openshift-default`) for OpenShift's gateway controller

All other platform components (AI Pipelines, Dashboard, Feast, Kueue, Model Registry, Ray, Trainer, Training Operator, TrustyAI, Workbenches, MLflow, LlamaStack) are set to `Removed`.

---

## 3. Installation

### 3.1 Clone the Repository

```bash
git clone https://github.com/opendatahub-io/odh-gitops.git
cd odh-gitops
```

### 3.2 Install Operators (First Helm Run)

The first run installs OLM subscriptions (Namespace, OperatorGroup, Subscription). CRs are skipped because their CRDs do not exist yet.

```bash
helm upgrade --install rhoai ./chart \
  -f docs/examples/values-inference-only.yaml \
  -n opendatahub-gitops --create-namespace
```

### 3.3 Wait for CRDs

Wait for the operators to install and register their CRDs:

```bash
kubectl wait --for=condition=Established \
  crd/leaderworkersetoperators.operator.openshift.io --timeout=300s

kubectl wait --for=condition=Established \
  crd/kuadrants.kuadrant.io --timeout=300s

kubectl wait --for=condition=Established \
  crd/datascienceclusters.datasciencecluster.opendatahub.io --timeout=300s

kubectl wait --for=condition=Established \
  crd/dscinitializations.dscinitialization.opendatahub.io --timeout=300s
```

### 3.4 Create CRs (Second Helm Run)

Now that CRDs exist, the second run creates the CR resources (DSCInitialization, DataScienceCluster, Kuadrant, LeaderWorkerSetOperator, etc.):

```bash
helm upgrade --install rhoai ./chart \
  -f docs/examples/values-inference-only.yaml \
  -n opendatahub-gitops
```

---

## 4. Enabling Authorino TLS

> **Warning:** This step is required for KServe to function correctly. It must be run after the Kuadrant operator creates the Authorino resource.

```bash
KUSTOMIZE_MODE=false ./scripts/prepare-authorino-tls.sh
```

This script:
1. Waits for the Authorino service to be created
2. Annotates the service to trigger TLS certificate generation
3. Waits for the TLS certificate secret
4. Patches the Authorino CR to enable TLS

---

## 5. Verification

### 5.1 Check Operator CSVs

Verify all operators are installed and in `Succeeded` phase:

```bash
oc get csv -A | grep -E "(cert-manager|leader-worker|rhcl|opendatahub|rhods)"
```

### 5.2 Check Authorino TLS

```bash
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='{.spec.listener.tls}'
```

### 5.3 Check DataScienceCluster Status

```bash
oc get datasciencecluster -o jsonpath='{.items[0].status.phase}'
```

### 5.4 Check KServe Pods

```bash
oc get pods -n redhat-ods-applications
```

Expected output:

```text
NAME                                         READY   STATUS    RESTARTS   AGE
kserve-controller-manager-xxxxxxxxx-xxxxx    1/1     Running   0          5m
odh-model-controller-xxxxxxxxx-xxxxx         1/1     Running   0          5m
```

### 5.5 Comprehensive Verification

Use the provided verification script for a full check of all operator subscriptions and pod readiness:

```bash
./scripts/verify-dependencies.sh
```

---

## 6. Deploying an LLM Inference Service

### 6.1 Create the Application Namespace

```bash
export NAMESPACE=llm-inference
oc new-project $NAMESPACE
```

### 6.2 Deploy the LLMInferenceService

Create the LLMInferenceService resource:

```bash
oc apply -n $NAMESPACE -f - <<'EOF'
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

### 6.3 Monitor Deployment Progress

Watch the LLMInferenceService status:

```bash
oc get llmisvc -n $NAMESPACE -w
```

The service is ready when the `READY` column shows `True`.

### 6.4 Test Inference

Retrieve the service URL:

```bash
SERVICE_URL=$(oc get llmisvc qwen2-7b-instruct -n $NAMESPACE -o jsonpath='{.status.url}')
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

## 7. Troubleshooting

### 7.1 CRs Not Being Created

If CR resources (DataScienceCluster, Kuadrant, LeaderWorkerSetOperator) are not created after the Helm install:

1. Verify the CRDs exist:

   ```bash
   kubectl get crd datascienceclusters.datasciencecluster.opendatahub.io
   kubectl get crd kuadrants.kuadrant.io
   ```

2. Run `helm upgrade` again — CRs are skipped until their CRDs exist:

   ```bash
   helm upgrade --install rhoai ./chart \
     -f docs/examples/values-inference-only.yaml \
     -n opendatahub-gitops
   ```

### 7.2 Authorino TLS Issues

1. Check the service annotation:

   ```bash
   kubectl get svc authorino-authorino-authorization -n kuadrant-system \
     -o jsonpath='{.metadata.annotations}'
   ```

2. Check the TLS secret:

   ```bash
   kubectl get secret authorino-server-cert -n kuadrant-system
   ```

3. Verify Authorino CR has TLS enabled:

   ```bash
   kubectl get authorino authorino -n kuadrant-system \
     -o jsonpath='{.spec.listener.tls}'
   ```

4. If the secret does not exist, re-run:

   ```bash
   KUSTOMIZE_MODE=false ./scripts/prepare-authorino-tls.sh
   ```

### 7.3 Dependencies Not Being Installed

1. Verify the component requiring it has `managementState: Managed` (not `Removed`)
2. Check that the dependency is not explicitly set to `false` in the component's `dependencies`
3. Verify the top-level `dependencies.<name>.enabled` is not set to `false`

---

## Additional Resources

- [odh-gitops Repository](https://github.com/opendatahub-io/odh-gitops) — Full GitOps deployment for RHOAI/ODH
- [Inference Only Stack Guide](https://github.com/opendatahub-io/odh-gitops/pull/34) — Example Helm values and installation details
- [Main Deployment Guide](./deploying-llm-d-on-managed-kubernetes.md) — Deploying on AKS, CoreWeave, and other Kubernetes platforms
