#!/bin/bash
# Deploy a mock vLLM model as an LLMInferenceService for e2e testing.
# No GPU required — uses a lightweight mock image that serves OpenAI-compatible endpoints.
# KServe handles TLS certificates, routing, and pod lifecycle.
# No model download — uses a no-op storage initializer for the local:// URI scheme.
#
# Usage: ./test/deploy-model.sh [--timeout SECONDS] [--image IMAGE]
#
# Prerequisites:
#   - KServe controller running (EA1 or EA2)
#   - Build and push the mock image:
#     cd test/mock-vllm && podman build -t ghcr.io/opendatahub-io/rhaii-on-xks/vllm-mock:latest . && podman push ...

set -euo pipefail

NAMESPACE="mock-vllm-test"
MODEL_NAME="mock-model"
MOCK_IMAGE="${MOCK_IMAGE:-ghcr.io/opendatahub-io/rhaii-on-xks/vllm-mock:latest}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Always}"
TIMEOUT="${TIMEOUT:-180}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --image)   MOCK_IMAGE="$2"; shift 2 ;;
        *) echo "Usage: $0 [--timeout SECONDS] [--image IMAGE]"; exit 1 ;;
    esac
done

echo "=== Deploy Mock vLLM (LLMInferenceService) ==="
echo "  Namespace: $NAMESPACE | Image: $MOCK_IMAGE"

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Verify KServe CRD is available
if ! kubectl get crd llminferenceservices.serving.kserve.io &>/dev/null; then
    echo "[FAIL] LLMInferenceService CRD not found. Deploy KServe first."
    exit 1
fi

# Create a no-op ClusterStorageContainer for local:// URIs (no model download)
# This avoids downloading any model — the mock server serves canned responses.
if kubectl get crd clusterstoragecontainers.serving.kserve.io &>/dev/null; then
    echo "[INFO] Creating no-op storage initializer for local:// scheme..."
    kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterStorageContainer
metadata:
  name: local-noop
spec:
  container:
    name: storage-initializer
    image: $MOCK_IMAGE
    command: ["python3", "-c", "print('No-op storage initializer for local:// URI')"]
    resources:
      limits:
        cpu: 100m
        memory: 32Mi
      requests:
        cpu: 10m
        memory: 16Mi
  supportedUriFormats:
  - prefix: local://
  workloadType: initContainer
EOF
    MODEL_URI="local://mock-model"
else
    echo "[INFO] ClusterStorageContainer CRD not available — creating empty PVC for mock model"
    kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mock-model-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Mi
EOF
    MODEL_URI="pvc://mock-model-pvc"
fi

# Deploy LLMInferenceService with mock image
echo "[INFO] Deploying LLMInferenceService..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: $MODEL_NAME
spec:
  model:
    name: $MODEL_NAME
    uri: $MODEL_URI
  replicas: 1
  router:
    gateway: {}
    route: {}
    scheduler: {}
  template:
    containers:
    - name: main
      image: $MOCK_IMAGE
      imagePullPolicy: $IMAGE_PULL_POLICY
      command: ["python3"]
      args: ["/app/server.py"]
      resources:
        limits:
          cpu: "500m"
          memory: 128Mi
        requests:
          cpu: "100m"
          memory: 64Mi
EOF

# Wait for LLMInferenceService to be ready
echo "[WAIT] Waiting for LLMInferenceService to be ready (timeout: ${TIMEOUT}s)..."
elapsed=0
while [[ $elapsed -lt $TIMEOUT ]]; do
    ready=$(kubectl get llmisvc "$MODEL_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$ready" == "true" || "$ready" == "True" ]]; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
done
echo ""

ready=$(kubectl get llmisvc "$MODEL_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$ready" != "True" ]]; then
    echo "[FAIL] LLMInferenceService not ready after ${TIMEOUT}s"
    kubectl get llmisvc,pods -n "$NAMESPACE"
    exit 1
fi

echo "[PASS] LLMInferenceService is ready"
kubectl get llmisvc -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE"

# Test inference via the service URL
SERVICE_URL=$(kubectl get llmisvc "$MODEL_NAME" -n "$NAMESPACE" -o jsonpath='{.status.url}')
echo ""
echo "[INFO] Testing inference at $SERVICE_URL ..."

RESPONSE=$(curl -s -k --max-time 30 -X POST "${SERVICE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"mock-model","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}')

if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('[PASS] Response:', d['choices'][0]['message']['content'])" 2>/dev/null; then
    echo ""
    echo "=== Mock model deployed successfully ==="
    echo "  LLMInferenceService: $MODEL_NAME"
    echo "  Namespace:           $NAMESPACE"
    echo "  URL:                 $SERVICE_URL"
    echo "  Cleanup:             make clean-mock-model"
else
    echo "[WARN] Inference test via gateway failed (gateway may not be configured)"
    echo "  Response: $RESPONSE"
    echo ""
    echo "=== Mock model deployed (inference via gateway not verified) ==="
    echo "  LLMInferenceService: $MODEL_NAME"
    echo "  Namespace:           $NAMESPACE"
    echo "  Cleanup:             make clean-mock-model"
fi
