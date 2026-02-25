# Red Hat AI Inference on managed Kubernetes

Infrastructure Helm charts for deploying Red Hat AI Inference Server (KServe LLMInferenceService) on managed Kubernetes platforms (AKS, CoreWeave).

> **Getting started?** See the [Deploying Red Hat AI Inference Server on Managed Kubernetes](./docs/deploying-llm-d-on-managed-kubernetes.md) guide for step-by-step deployment instructions.

## Related Repositories

| Repository | Purpose |
|------------|---------|
| [llm-d-xks-aks](https://github.com/kwozyman/llm-d-xks-aks) | AKS cluster provisioning (creates cluster + GPU nodes + GPU Operator) |

## Overview

| Component | App Version | Description |
|-----------|-------------|-------------|
| cert-manager-operator | 1.15.2 | TLS certificate management |
| sail-operator (Istio) | 3.2.x | Gateway API for inference routing |
| lws-operator | 1.0 | LeaderWorkerSet controller for multi-node workloads |
| kserve | 3.4.0-ea.1 | KServe controller for LLMInferenceService lifecycle |

### Version Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| OSSM (Sail Operator) | 3.2.x | Gateway API for inference routing |
| Istio | v1.27.x | Service mesh |
| InferencePool API | v1 | `inference.networking.k8s.io/v1` |
| KServe | rhoai-3.4+ | LLMInferenceService controller |

## Prerequisites

- Kubernetes cluster (AKS or CoreWeave) - see [llm-d-xks-aks](https://github.com/kwozyman/llm-d-xks-aks) for AKS provisioning
- `kubectl`, `helm` (v3.17+), `helmfile`
- Red Hat account (for Sail Operator and vLLM images from `registry.redhat.io`)

**Cluster readiness check (optional):** Run `cd validation && make container && make run` to verify cloud provider, GPU availability, and instance types before deploying. CRD checks will pass only after operators are deployed. See [Preflight Validation](./validation/README.md).

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

```bash
git clone https://github.com/opendatahub-io/rhaii-on-xks.git
cd rhaii-on-xks

# 1. Deploy all components (cert-manager + Istio + LWS + KServe)
make deploy-all

# 2. Set up inference gateway
./scripts/setup-gateway.sh

# 3. Validate deployment
cd validation && make container && make run

# 4. Check status
make status
```

For deploying LLM inference services, GPU requirements, and testing inference, see the [full deployment guide](./docs/deploying-llm-d-on-managed-kubernetes.md).

---

## Usage

```bash
# Deploy
make deploy              # cert-manager + istio + lws
make deploy-all          # cert-manager + istio + lws + kserve
make deploy-kserve       # Deploy KServe

# Undeploy
make undeploy            # Remove all infrastructure
make undeploy-kserve     # Remove KServe

# Test (ODH conformance)
make test NAMESPACE=llm-d           # Run conformance tests
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

## Collecting Debug Information

If you encounter issues, collect diagnostic information for troubleshooting or to share with Red Hat support:

```bash
./scripts/collect-debug-info.sh
```

See the [Collecting Debug Information](./docs/collecting-debug-information.md) guide for details.

---

## Troubleshooting

For detailed troubleshooting steps (KServe controller issues, gateway errors, webhook problems, monitoring setup), see the [full deployment guide - Troubleshooting](./docs/deploying-llm-d-on-managed-kubernetes.md#9-troubleshooting).

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
│   ├── lws-operator/             # LWS operator Helm chart
│   └── kserve/                   # KServe controller Helm chart (auto-generated)
├── validation/                   # Preflight validation checks
│   ├── llmd_xks_checks.py       # Validation script
│   ├── Containerfile             # Container build
│   └── Makefile                  # Build and run helpers
└── scripts/
    ├── cleanup.sh             # Cleanup infrastructure (helmfile destroy + finalizers)
    └── setup-gateway.sh       # Set up Gateway with CA bundle for mTLS
```

## Charts

Helm charts are included locally under `charts/`:

- `charts/cert-manager-operator/` — cert-manager operator
- `charts/sail-operator/` — Sail/Istio operator
- `charts/lws-operator/` — LeaderWorkerSet operator
- `charts/kserve/` — KServe controller (auto-generated from Kustomize overlays, all images from `registry.redhat.io`)

The helmfile imports the infrastructure charts (cert-manager, sail-operator, lws-operator) including presync hooks for CRD installation. The KServe OCI chart is deployed via helmfile from `ghcr.io/opendatahub-io/kserve-rhaii-xks`.
