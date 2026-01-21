# llm-d-infra-xks

Infrastructure Helm charts for deploying llm-d on xKS platforms (AKS, EKS, GKE).

## Overview

| Component | App Version | Description |
|-----------|-------------|-------------|
| cert-manager-operator | 1.15.2 | TLS certificate management |
| sail-operator (Istio) | 3.2.1 | Service mesh & gateway |
| lws-operator | 1.0 | LeaderWorkerSet controller |

## Prerequisites

- Kubernetes cluster (AKS, EKS, GKE)
- `kubectl`, `helm`, `helmfile`
- Red Hat pull secret

```bash
# Configure pull secret
mkdir -p ~/.config/containers
cp ~/pull-secret.txt ~/.config/containers/auth.json
```

## Quick Start

```bash
git clone https://github.com/aneeshkp/llm-d-infra-xks.git
cd llm-d-infra-xks

# Deploy cert-manager + istio
make deploy

# Or deploy all including lws
make deploy-all

# Check status
make status
```

## Usage

```bash
# Deploy
make deploy              # cert-manager + istio
make deploy-all          # cert-manager + istio + lws

# Deploy individual
make deploy-cert-manager
make deploy-istio
make deploy-lws

# Undeploy
make undeploy            # Remove all
make undeploy-cert-manager
make undeploy-istio
make undeploy-lws

# Other
make status              # Show status
make test                # Run tests
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
  enabled: true   # Set false if not needed
```

## Structure

```
llm-d-infra-xks/
├── helmfile.yaml.gotmpl
├── values.yaml
├── Makefile
├── README.md
└── scripts/
    └── copy-pull-secret.sh
```

## Source Repositories

Operator helmfiles are imported from:

- https://github.com/aneeshkp/cert-manager-operator-chart
- https://github.com/aneeshkp/sail-operator-chart
- https://github.com/aneeshkp/lws-operator-chart

This approach imports the full helmfiles including presync hooks for CRD installation.

## Next Steps

After deploying infrastructure, follow the [llm-d guides](https://github.com/llm-d/llm-d/tree/main/guides) to deploy llm-d.

Use `scripts/copy-pull-secret.sh <namespace>` to fix gateway pull secret issues.
