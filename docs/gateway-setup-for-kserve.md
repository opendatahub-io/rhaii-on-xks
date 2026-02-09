# Gateway Setup for KServe Integration

This guide explains how to set up the inference Gateway with CA bundle mounting
when using llm-d-infra-xks with KServe.

## Why is this needed?

KServe's LLMInferenceService uses mTLS between components (router ↔ scheduler ↔ vLLM),
which requires the CA bundle mounted at `/var/run/secrets/opendatahub/ca.crt`. The Gateway
needs this CA to trust the backend services it routes traffic to.

**Note:** This is only required for KServe integration. If you're using llm-d standalone
(which uses HTTP), you don't need the CA bundle mounting.

## Prerequisites

- llm-d-infra-xks deployed (`make deploy` or `make deploy-all`)
- cert-manager CA certificate issued (created automatically by llm-d-infra-xks)
- KServe deployed with odh-xks overlay

## Automated Setup

Use the provided script:

```bash
./scripts/setup-gateway.sh
```

With custom configuration:

```bash
KSERVE_NAMESPACE=opendatahub \
CERT_MANAGER_NAMESPACE=cert-manager \
CA_SECRET_NAME=opendatahub-ca \
GATEWAY_NAME=inference-gateway \
./scripts/setup-gateway.sh
```

## Manual Setup

### Step 1: Copy Pull Secret

The Gateway pod needs to pull Istio images from `registry.redhat.io`:

```bash
# Copy pull secret to opendatahub namespace
kubectl delete secret redhat-pull-secret -n opendatahub --ignore-not-found
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "opendatahub"' | \
  kubectl create -f -
```

### Step 2: Extract CA and Create ConfigMap

```bash
# Extract CA certificate from cert-manager secret
CA_CERT=$(kubectl get secret opendatahub-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null || \
  kubectl get secret opendatahub-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}')

if [[ -z "$CA_CERT" ]]; then
  echo "Error: Could not extract CA certificate"
  exit 1
fi

# Create CA bundle ConfigMap in KServe namespace
kubectl create configmap odh-ca-bundle \
  --from-literal=ca.crt="$(echo "$CA_CERT" | base64 -d)" \
  -n opendatahub \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 3: Create Gateway Configuration ConfigMap

This configures the Gateway pod to mount the CA bundle at the path expected by
LLM workloads (`/var/run/secrets/opendatahub/ca.crt`).

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: inference-gateway-config
  namespace: opendatahub
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
EOF
```

### Step 4: Create the Gateway

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway
  namespace: opendatahub
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

### Step 5: Patch ServiceAccount and Restart Pod

The Gateway ServiceAccount needs the pull secret to pull Istio images:

```bash
# Patch ServiceAccount with pull secret
kubectl patch serviceaccount inference-gateway-istio -n opendatahub \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

# Delete the pod to restart with pull secret
kubectl delete pod -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod \
  -l gateway.networking.k8s.io/gateway-name=inference-gateway \
  -n opendatahub --timeout=120s
```

### Step 6: Verify

```bash
# Check Gateway is programmed
kubectl get gateway inference-gateway -n opendatahub

# Should show PROGRAMMED=True
```

## How it Works

```
┌─────────────────────────────────────────────────────────────────┐
│  cert-manager namespace                                         │
│  ┌─────────────────────┐                                        │
│  │ Secret: opendatahub-ca │ ◄── Contains the CA cert            │
│  └──────────┬──────────┘                                        │
└─────────────┼───────────────────────────────────────────────────┘
              │ extract ca.crt
              ▼
┌─────────────────────────────────────────────────────────────────┐
│  opendatahub namespace (KServe)                                 │
│                                                                 │
│  ┌─────────────────────┐      ┌──────────────────────────────┐  │
│  │ ConfigMap:          │      │ ConfigMap:                   │  │
│  │ odh-ca-bundle       │      │ inference-gateway-config     │  │
│  │ (ca.crt data)       │      │ (volume mount spec)          │  │
│  └─────────────────────┘      └──────────────────────────────┘  │
│                                              │                  │
│  ┌───────────────────────────────────────────▼───────────────┐  │
│  │ Gateway: inference-gateway                                │  │
│  │   parametersRef → inference-gateway-config                │  │
│  │   Pod mounts: /var/run/secrets/opendatahub/ca.crt        │  │
│  └───────────────────────────────────────────────────────────┘  │
│                               │                                 │
│                               │ mTLS (trusts CA)                │
│                               ▼                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Router    │  │  Scheduler  │  │    vLLM     │             │
│  │ (has cert)  │  │ (has cert)  │  │ (has cert)  │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `KSERVE_NAMESPACE` | `opendatahub` | Namespace where KServe is deployed |
| `CERT_MANAGER_NAMESPACE` | `cert-manager` | Namespace where cert-manager is deployed |
| `CA_SECRET_NAME` | `opendatahub-ca` | Name of the CA secret |
| `GATEWAY_NAME` | `inference-gateway` | Name of the Gateway to create |
| `CA_BUNDLE_CONFIGMAP` | `odh-ca-bundle` | Name of the CA bundle ConfigMap |
| `CA_MOUNT_PATH` | `/var/run/secrets/opendatahub` | Mount path for CA bundle |

## Troubleshooting

### Gateway pod shows ErrImagePull

The Gateway pod needs to pull Istio images from `registry.redhat.io`:

```bash
# Copy pull secret to opendatahub namespace
kubectl delete secret redhat-pull-secret -n opendatahub --ignore-not-found
kubectl get secret redhat-pull-secret -n istio-system -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.labels) | .metadata.namespace = "opendatahub"' | \
  kubectl create -f -

# Patch ServiceAccount
kubectl patch sa inference-gateway-istio -n opendatahub \
  -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'

# Restart the pod
kubectl delete pod -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway
```

### Gateway not becoming Programmed

Check the GatewayClass exists:
```bash
kubectl get gatewayclass istio
```

### Certificate not found

Ensure cert-manager issued the CA certificate:
```bash
kubectl get certificate -n cert-manager
kubectl get secret opendatahub-ca -n cert-manager
```

If missing, apply the cert-manager resources:
```bash
kubectl apply -k config/overlays/odh-test/cert-manager  # from KServe repo
```

### Gateway pod not mounting CA

Check the Gateway pod has the volume:
```bash
kubectl get pods -n opendatahub -l gateway.networking.k8s.io/gateway-name=inference-gateway
kubectl describe pod <pod-name> -n opendatahub | grep -A5 "Volumes:"
```
