# Stage 1: End-to-end PVC model + LLMInferenceService on xKS

Deploy a model from a PVC-backed storage, expose it via KServe LLMInferenceService, send an inference request, and trace the request through the networking stack.

**Prerequisites:**
- rhaii-on-xks deployed (`make deploy-all`)
- Inference gateway configured (`./scripts/setup-gateway.sh`)

---

## Step 1: Create namespace

```bash
export NAMESPACE=llm-inference
kubectl create namespace $NAMESPACE
```

## Step 2: Create PVC

```bash
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qwen2-7b-model
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
EOF
```

## Step 3: Download model into PVC

Uses the KServe storage initializer image to download the model as flat files directly into the PVC.

> **Why flat files?** KServe mounts the PVC subpath at `/mnt/models` and runs `vllm serve /mnt/models`.
> The model files (`config.json`, `*.safetensors`) must be at the root of that path.
> HF cache format (`cache_dir`) nests files under `snapshots/<hash>/` with symlinks to `blobs/`,
> which vLLM cannot resolve as a model directory.

```bash
# Use the same storage initializer image configured for KServe (already mirrored for disconnected installs)
STORAGE_INIT_IMAGE=$(kubectl get configmap inferenceservice-config -n opendatahub \
  -o jsonpath='{.data.storageInitializer}' | python3 -c "import sys,json; print(json.load(sys.stdin)['image'])")

kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: qwen2-7b-downloader
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: storage-initializer
        image: $STORAGE_INIT_IMAGE
        args:
          - hf://Qwen/Qwen2.5-7B-Instruct
          - /mnt/models
        env:
          - name: HF_HOME
            value: /tmp/hf
          - name: HF_HUB_DISABLE_TELEMETRY
            value: "1"
        resources:
          requests:
            cpu: "1"
            memory: 4Gi
          limits:
            cpu: "2"
            memory: 20Gi
        volumeMounts:
        - name: model-storage
          mountPath: /mnt/models
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: qwen2-7b-model
EOF

# Watch progress
kubectl logs -n $NAMESPACE job/qwen2-7b-downloader -f

# Verify completion
kubectl get job qwen2-7b-downloader -n $NAMESPACE
```

## Step 4: Configure pull secret

```bash
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
      .metadata.annotations, .metadata.labels, .metadata.ownerReferences) |
      .metadata.namespace = "'$NAMESPACE'"' | \
  kubectl apply -f -

kubectl patch serviceaccount default -n $NAMESPACE \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'
```

## Step 5: Deploy LLMInferenceService

```bash
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen2-7b
spec:
  model:
    name: Qwen/Qwen2.5-7B-Instruct
    uri: pvc://qwen2-7b-model/Qwen2.5-7B-Instruct
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
          memory: 64Gi
          nvidia.com/gpu: "1"
        requests:
          cpu: "2"
          memory: 32Gi
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

# Watch until READY=True
kubectl get llmisvc -n $NAMESPACE -w
```

## Step 6: Send inference request

```bash
SERVICE_URL=$(kubectl get llmisvc qwen2-7b -n $NAMESPACE -o jsonpath='{.status.url}')
echo "Service URL: $SERVICE_URL"

curl -s -k -X POST "${SERVICE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 20
  }' | python3 -m json.tool
```

## Step 7: Trace request through the networking stack

```bash
# Gateway (ingress)
echo "=== Gateway ==="
kubectl get gateway -n opendatahub inference-gateway
kubectl logs -n opendatahub \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway \
  --tail=10

# HTTPRoute (created automatically by KServe)
echo ""
echo "=== HTTPRoute ==="
kubectl get httproute -n $NAMESPACE

# Router (routes to scheduler)
echo ""
echo "=== Router Logs ==="
kubectl logs -n $NAMESPACE \
  -l serving.kserve.io/llminferenceservice=qwen2-7b \
  -c router --tail=10

# Scheduler (picks best replica)
echo ""
echo "=== Scheduler Logs ==="
kubectl logs -n $NAMESPACE \
  -l serving.kserve.io/llminferenceservice=qwen2-7b \
  -c scheduler --tail=10

# vLLM (inference)
echo ""
echo "=== vLLM Logs ==="
kubectl logs -n $NAMESPACE \
  -l serving.kserve.io/llminferenceservice=qwen2-7b,serving.kserve.io/component=model \
  --tail=10
```

### Request flow

```
Client
  |
  v
Gateway (Istio, opendatahub/inference-gateway, port 80)
  |
  v
Router -> Scheduler (router-scheduler pod, mTLS)
  |
  v
vLLM Pod (GPU, serves model from PVC)
  |
  v
Response back: vLLM -> Scheduler -> Router -> Gateway -> Client
```
