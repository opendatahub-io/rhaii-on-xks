# LWS Operator Helm Chart

Deploy Red Hat Leader Worker Set (LWS) Operator on any Kubernetes cluster without OLM.

## Overview

This chart uses **olm-extractor** to extract manifests directly from Red Hat's OLM bundle, enabling deployment on non-OLM Kubernetes clusters (AKS, EKS, GKE) while:

- **Minimizing OCP team burden** - Uses exact manifests from Red Hat's OLM bundles
- **Easy upgrades** - Update bundle with `./scripts/update-bundle.sh <version>`, then `make deploy`
- **No breaking changes** - Only minimal patches for non-OLM environments

## What is Leader Worker Set?

LWS provides an API for deploying a group of pods as a unit of replication, designed for:
- **AI/ML inference workloads** - Especially multi-host inference where LLMs are sharded across multiple nodes
- **Distributed training** - Coordinated pod groups with leader/worker topology
- **Gang scheduling** - All-or-nothing pod group scheduling

## Prerequisites

- `kubectl` configured for your cluster
- `helm` 3.17+ (for Server-Side Apply support)
- `helmfile` installed
- Red Hat account for pull secret

## Quick Start

This chart is part of the [rhaii-on-xks](https://github.com/opendatahub-io/rhaii-on-xks) monorepo and is deployed via the top-level helmfile:

```bash
# From the repo root
make deploy-lws

# Or selectively via helmfile
helmfile apply --selector name=lws-operator

# Verify
kubectl get pods -n openshift-lws-operator
kubectl get leaderworkersetoperator cluster
```

## Configuration

### Step 1: Get Red Hat Pull Secret

1. Go to: https://console.redhat.com/openshift/install/pull-secret
2. Login and download pull secret
3. Save as `~/pull-secret.txt`

### Step 2: Setup Auth (Choose ONE)

#### Option A: Persistent Podman Auth (Recommended)

```bash
# Copy pull secret to persistent location
mkdir -p ~/.config/containers
cp ~/pull-secret.txt ~/.config/containers/auth.json
```

Then in `environments/default.yaml`:
```yaml
useSystemPodmanAuth: true
```

#### Option B: Pull Secret File

```bash
# Verify pull secret works
podman pull --authfile ~/pull-secret.txt registry.redhat.io/ubi8/ubi-minimal --quiet && echo "Auth works!"
```

Then in `environments/default.yaml`:
```yaml
pullSecretFile: ~/pull-secret.txt
```

### Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Operator namespace | `openshift-lws-operator` |
| `bundle.version` | OLM bundle version | `1.0` |
| `pullSecret.name` | Pull secret name | `redhat-pull-secret` |
| `pullSecret.dockerConfigJson` | Docker config (set by helmfile) | `""` |
| `lwsOperator.enabled` | Create LeaderWorkerSetOperator CR | `true` |
| `lwsOperator.name` | LeaderWorkerSetOperator CR name | `cluster` |

## What Gets Deployed

**Presync hooks** (before Helm install):
- Operator namespace (`openshift-lws-operator`)
- LWS controller ServiceAccount with `imagePullSecrets`

**Helm install** (with Server-Side Apply):
- LeaderWorkerSetOperator CRD - installed from `crds/` directory with SSA
- Pull secret (`redhat-pull-secret`)
- LWS Operator ServiceAccount with `imagePullSecrets`
- LWS Operator deployment + RBAC
- RoleBinding in `kube-system` for API server auth (required for non-OpenShift clusters)

> **Note:** Helm 3.17+ is required for Server-Side Apply (SSA) support.

**Post-install** (automatic):
- LeaderWorkerSetOperator CR (`cluster`)
- Operator deploys LeaderWorkerSet CRD and webhooks

## Version Compatibility

| Component | Version |
|-----------|---------|
| LWS Operator | 1.0 |
| LeaderWorkerSet API | v1 |

**OLM Bundle:** `registry.redhat.io/leader-worker-set/lws-operator-bundle` ([Red Hat Catalog](https://catalog.redhat.com/en/software/containers/leader-worker-set/lws-operator-bundle/67ff5cf98d6d1a868448873b))

## Verify Installation

```bash
# Check operator
kubectl get pods -n openshift-lws-operator

# Check LeaderWorkerSetOperator CR
kubectl get leaderworkersetoperator cluster

# Check LeaderWorkerSet CRD is available
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io
```

## Create a LeaderWorkerSet

```bash
kubectl apply -f - <<EOF
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: my-lws
spec:
  replicas: 2
  leaderWorkerTemplate:
    size: 3
    leaderTemplate:
      metadata:
        labels:
          role: leader
      spec:
        containers:
        - name: main
          image: nginx
    workerTemplate:
      spec:
        containers:
        - name: main
          image: nginx
EOF
```

## Uninstall

```bash
./scripts/cleanup.sh
```

## Upgrade

```bash
# (Optional) Update to a new bundle version
./scripts/update-bundle.sh <version>

# Deploy
make deploy
```

## Update Pull Secret

Red Hat pull secrets expire (typically yearly). To update:

```bash
# Option A: Using system podman auth (after re-login)
podman login registry.redhat.io
./scripts/update-pull-secret.sh

# Option B: Using pull secret file
./scripts/update-pull-secret.sh ~/new-pull-secret.txt

# Restart operator to use new secret
kubectl rollout restart deployment/openshift-lws-operator -n openshift-lws-operator
```

## Testing

After installing the operator, you can validate it using the test manifests in the `test/` directory.

### Available Tests

| Test | File | Purpose |
|------|------|---------|
| Ring Test | `test/lws-ring-test.yaml` | Basic LWS validation - leader/worker topology and connectivity |
| Network Test | `test/lws-network-test.yaml` | Network bandwidth test with iperf3/ping |

### Run Tests

```bash
# Deploy a test
kubectl apply -f test/lws-network-test.yaml

# Watch pods come up
kubectl get pods -n lws-test -w

# Check test results (network test - view worker logs for iperf3 results)
kubectl logs -n lws-test network-test-0-1

# Cleanup
kubectl delete -f test/lws-network-test.yaml
```

See `test/README.md` for detailed test documentation.

## File Structure

```
charts/lws-operator/
├── Chart.yaml
├── Makefile                     # make deploy, make test, etc.
├── values.yaml                  # Default values
├── helmfile.yaml.gotmpl         # Deploy with: helmfile apply
├── .helmignore
├── environments/
│   └── default.yaml             # User config
├── crds/                        # LeaderWorkerSetOperator CRD (installed by Helm with SSA)
├── manifests-presync/           # Resources applied before Helm install
├── templates/
│   ├── deployment-*.yaml        # Operator deployment
│   ├── pull-secret.yaml         # Registry pull secret
│   └── *.yaml                   # RBAC, ServiceAccount, etc.
├── scripts/
│   ├── update-bundle.sh         # Update to new bundle version
│   ├── update-pull-secret.sh    # Update expired pull secret
│   ├── cleanup.sh               # Uninstall
│   └── post-install-message.sh  # Post-install instructions
└── test/
    ├── README.md                # Test documentation
    ├── lws-ring-test.yaml       # Ring topology test
    └── lws-network-test.yaml    # Network bandwidth test
```

## Makefile

For convenience, a Makefile is provided:

```bash
make deploy        # Deploy LWS operator (helmfile apply)
make undeploy      # Remove LWS operator (scripts/cleanup.sh)
make update-bundle # Update bundle (VERSION=1.1)
make list-versions # List available bundle versions
make test          # Run all tests (ring + network)
make test-ring     # Run ring topology test
make test-network  # Run network bandwidth test
make clean         # Full cleanup (operator + tests)
make clean-tests   # Cleanup test resources only
```
