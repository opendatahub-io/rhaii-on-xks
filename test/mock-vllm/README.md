# Mock vLLM Server

A lightweight mock server implementing the OpenAI-compatible API for e2e testing of the KServe LLMInferenceService control plane — without GPUs, model downloads, or real inference workloads.

## How It Works

The mock server deploys as a proper `LLMInferenceService`, exercising the full KServe control plane:

- **TLS certificates** — KServe auto-generates and mounts certs; the mock server uses them for HTTPS
- **HTTPRoute / InferencePool** — created by the KServe controller
- **EPP router/scheduler** — deployed alongside the mock pod
- **Gateway routing** — traffic flows through the Istio gateway to the mock

A no-op `ClusterStorageContainer` is registered for the `local://` URI scheme, so no model is downloaded. The mock image serves as both the init container (exits immediately) and the main container (serves the API).

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (always returns 200) |
| `/v1/models` | GET | Lists the mock model |
| `/v1/chat/completions` | POST | Returns a mock chat response |
| `/v1/completions` | POST | Returns a mock completion response |
| `/metrics` | GET | Mock Prometheus metrics |

## HTTPS Support

The server automatically detects TLS certificates at the KServe default path (`/var/run/kserve/tls/tls.crt`). Override via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `SSL_CERTFILE` | `/var/run/kserve/tls/tls.crt` | TLS certificate path |
| `SSL_KEYFILE` | `/var/run/kserve/tls/tls.key` | TLS private key path |
| `PORT` | `8000` | Listen port |

If no certs are found, the server falls back to plain HTTP.

## Build and Push

```bash
cd test/mock-vllm
podman build -t quay.io/<personal-org>/vllm-mock:latest .
podman push quay.io/<personal-org>/vllm-mock:latest
```

## Deploy as LLMInferenceService

```bash
make deploy-mock-model
```

This creates:
1. A `ClusterStorageContainer` (`local-noop`) for the `local://` URI scheme — no model download
2. An `LLMInferenceService` using the mock image with KServe-managed TLS

## Run Conformance Tests

```bash
make test NAMESPACE=mock-vllm-test
```

## Clean Up

```bash
make clean-mock-model
```

## Local Test (standalone, no Kubernetes)

```bash
podman run -p 8000:8000 quay.io/<personal-org>/vllm-mock:latest

curl http://localhost:8000/health
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mock-model","messages":[{"role":"user","content":"Hello"}]}'
```
