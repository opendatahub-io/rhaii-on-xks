# LoRA Adapter POC

This example demonstrates serving multiple LoRA adapters on a single base model using vLLM and KServe's LLMInferenceService.

## What is LoRA?

LoRA (Low-Rank Adaptation) enables fine-tuning large models by training only a small set of adapter weights instead of the full model. At serving time, vLLM loads the base model once and dynamically attaches multiple LoRA adapters. Each adapter is typically tens of MBs compared to the base model's GBs.

## Setup

| Component | Details |
|-----------|---------|
| Base model | `Qwen/Qwen2.5-7B-Instruct` (non-gated, ~15GB) |
| Adapter 1 | `k8s-lora` — Kubernetes QA specialist ([cimendev/kubernetes-qa-qwen2.5-7b-lora](https://huggingface.co/cimendev/kubernetes-qa-qwen2.5-7b-lora), rank=64) |
| Adapter 2 | `finance-lora` — Finance domain specialist ([Max1690/qwen2.5-7b-finance-lora](https://huggingface.co/Max1690/qwen2.5-7b-finance-lora), rank=16) |
| Replicas | 2 (each replica has the same base model + adapters on its own GPU) |
| GPU | 1x NVIDIA A100 (80GB) per replica |

## Prerequisites

- rhaii-on-xks deployed (`make deploy-all`)
- Gateway configured (`./scripts/setup-gateway.sh`)
- At least 2 GPU nodes available (for 2 replicas)

## Deploy

```bash
# Create namespace
export NAMESPACE=llm-inference
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Copy pull secret and patch default ServiceAccount
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "'$NAMESPACE'"' | \
  kubectl apply -f -

kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

# Deploy the LLMInferenceService with LoRA adapters
kubectl apply -n $NAMESPACE -f examples/lora-poc/llmisvc-lora.yaml

# Watch until READY=True (model download + adapter loading takes ~5 minutes)
kubectl get llmisvc -n $NAMESPACE -w
```

## Test

Get the service URL:

```bash
SERVICE_URL=$(kubectl get llmisvc qwen2-lora -n $NAMESPACE -o jsonpath='{.status.url}')
```

### Base model (no adapter)

```bash
curl -s -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 100
  }' | jq .
```

### Kubernetes QA adapter

```bash
curl -s -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "k8s-lora",
    "messages": [{"role": "user", "content": "How do I debug a CrashLoopBackOff pod?"}],
    "max_tokens": 200
  }' | jq .
```

### Finance adapter

```bash
curl -s -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "finance-lora",
    "messages": [{"role": "user", "content": "Explain stock options vs RSUs"}],
    "max_tokens": 200
  }' | jq .
```

## How it works

```text
                         ┌─────────────────────────┐
                         │     EPP Scheduler        │
              ┌──────────┤  (picks optimal replica) ├──────────┐
              │          └─────────────────────────┘           │
              ▼                                                ▼
┌──────────────────────────────┐         ┌──────────────────────────────┐
│   Replica 1 (GPU Node 1)     │         │   Replica 2 (GPU Node 2)     │
│                              │         │                              │
│  ┌────────────────────────┐  │         │  ┌────────────────────────┐  │
│  │ Base: Qwen2.5-7B       │  │         │  │ Base: Qwen2.5-7B       │  │
│  │ (loaded once, ~15GB)   │  │         │  │ (loaded once, ~15GB)   │  │
│  └────────────────────────┘  │         │  └────────────────────────┘  │
│    │            │            │         │    │            │            │
│  ┌─┴──────┐ ┌──┴───────┐    │         │  ┌─┴──────┐ ┌──┴───────┐    │
│  │k8s-lora│ │finance-  │    │         │  │k8s-lora│ │finance-  │    │
│  │(~50MB) │ │lora(~20MB│    │         │  │(~50MB) │ │lora(~20MB│    │
│  └────────┘ └──────────┘    │         │  └────────┘ └──────────┘    │
└──────────────────────────────┘         └──────────────────────────────┘
```

- Both replicas have the same base model and the same set of LoRA adapters
- Requests come in via OpenAI API with `"model"` set to base or any adapter name
- The EPP scheduler selects the optimal replica based on load, KV cache state, etc.
- The request is routed to the selected pod, which serves it using the appropriate adapter

## Key configuration

### Environment variables

| Env | Purpose |
|-----|---------|
| `HF_HUB_OFFLINE=false` | Required so vLLM can download LoRA adapters from HuggingFace at startup. For production, pre-download adapters to a PVC or bake them into the image. |
| `VLLM_ADDITIONAL_ARGS` | Passes extra flags to the vLLM `serve` command |

### vLLM args (via VLLM_ADDITIONAL_ARGS)

| Arg | Purpose |
|-----|---------|
| `--enable-lora` | Enable LoRA adapter support |
| `--max-lora-rank=64` | Maximum LoRA rank to support (must be >= highest adapter rank) |
| `--max-loras=2` | Maximum number of LoRA adapters loaded simultaneously in GPU memory |
| `--max-cpu-loras=2` | Maximum number of LoRA adapters stored in CPU memory (for offloading) |
| `--lora-modules name=repo` | Register a LoRA adapter by name from HuggingFace |

> **Note:** The LLMInferenceService CRD has a `spec.model.lora.adapters` field, but the KServe controller does not yet reconcile it into vLLM args. Once controller support lands, migrate from `VLLM_ADDITIONAL_ARGS` to the native API.

## Verifying scheduler routing

To see which pod the scheduler routes each request to, check the Istio gateway access logs:

```bash
kubectl logs -l gateway.networking.k8s.io/gateway-name=inference-gateway -n opendatahub --tail=10 | grep "qwen2-lora"
```

Each log line contains the upstream pod IP that handled the request. Map it to pods using:

```bash
kubectl get pods -n $NAMESPACE -o wide
```

Example log output — the IP before `outbound|` is the pod that served the request:

```text
"POST ... HTTP/1.1" 200 ... "10.224.0.144:8000" outbound|...  ← Replica 1
"POST ... HTTP/1.1" 200 ... "10.224.0.125:8000" outbound|...  ← Replica 2
```

The scheduler uses `prefix-cache-scorer` (weight=2) and `load-aware-scorer` (weight=1) to pick the optimal replica per request.

## Cleanup

```bash
kubectl delete llmisvc qwen2-lora -n $NAMESPACE
kubectl delete namespace $NAMESPACE
```
