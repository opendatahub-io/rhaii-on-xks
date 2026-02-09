# llm-d Infrastructure on xKS: Architecture Overview

## Context

**Goal:** Deploy Red Hat AI Inference Server (LLMInferenceService) on xKS platforms (AKS, CoreWeave) for EA1 delivery.

**Challenge:** LLMInferenceService requires Red Hat-supported operators (cert-manager, sail-operator, lws-operator) that are normally deployed via OLM (Operator Lifecycle Manager) on OpenShift. OLM is not available on vanilla Kubernetes.

**Solution:** Extract operator manifests from OLM bundles and deploy using Helm/Helmfile.

---

## Components

| Component | Version | Purpose | OLM Bundle Source |
|-----------|---------|---------|-------------------|
| cert-manager-operator | v1.15.2 | TLS certificate management | `registry.redhat.io/cert-manager/cert-manager-operator-bundle` |
| sail-operator (Istio) | 3.2.1 | Gateway API for inference routing | `registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle` |
| lws-operator | 1.0 | LeaderWorkerSet for distributed inference | `registry.redhat.io/leader-worker-set/lws-operator-bundle` |

**Note:** We use Istio only for Gateway API (inference routing), not as a service mesh.

---

## Why Helm Charts?

| On OpenShift | On xKS (AKS/CKS) |
|--------------|------------------|
| OLM manages operator lifecycle | No OLM available |
| `Subscription` CR triggers install | Need alternative deployment method |
| Automatic upgrades via OLM | Manual upgrades via Helm |

**Helm provides:**
- Declarative deployment
- Version control
- Rollback capability
- Integration with GitOps (ArgoCD, Flux)

---

## How We Extract OLM Bundles

### Tool: olm-extractor

We use [olm-extractor](https://github.com/lburgazzoli/olm-extractor) to convert OLM bundles to Kubernetes manifests.

```bash
# Example: Extract sail-operator bundle
podman run --rm \
  -v ~/.config/containers/auth.json:/root/.docker/config.json:z \
  quay.io/lburgazzoli/olm-extractor:main \
  run "registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle:3.2.1" \
  -n istio-system \
  --exclude '.kind == "ConsoleCLIDownload"'
```

**What olm-extractor does:**
1. Pulls the OLM bundle image
2. Reads the ClusterServiceVersion (CSV)
3. Extracts deployment, RBAC, CRDs
4. Outputs Kubernetes YAML manifests

### Post-Processing

After extraction, we:
1. Split into CRDs and templates
2. Templatize namespace references
3. Add `imagePullSecrets` for Red Hat registry
4. Apply CRDs with `--server-side` (some are 700KB+)

---

## Why This Approach?

### Red Hat Supported Components

We use Red Hat-supported operator bundles because:
- **Support:** Covered under Red Hat subscription
- **Tested:** Validated on OpenShift, compatible with Kubernetes
- **Security:** Regular CVE patches
- **Compliance:** Required for enterprise customers


---

## Implementation Details

### Repository Structure

```
llm-d-infra-xks/                    # Main orchestrator
├── helmfile.yaml.gotmpl            # Imports operator charts
├── values.yaml                     # Configuration
└── Makefile                        # make deploy, make status

cert-manager-operator-chart/        # Extracted operator
├── manifests-crds/                 # CRDs (applied via presync)
├── templates/                      # Operator deployment, RBAC
├── scripts/update-bundle.sh        # Re-extract from newer bundle
└── helmfile.yaml.gotmpl

sail-operator-chart/                # Extracted operator
├── manifests-crds/                 # 19 Istio CRDs
├── manifests-presync/              # Namespace, ServiceAccounts
├── templates/                      # Operator deployment, Istio CR
├── scripts/update-bundle.sh
└── helmfile.yaml.gotmpl

lws-operator-chart/                 # Extracted operator
├── manifests-crds/
├── templates/
├── scripts/update-bundle.sh
└── helmfile.yaml.gotmpl
```

### Deployment Flow

```
User runs: make deploy
    │
    ├── helmfile apply (llm-d-infra-xks)
    │       │
    │       ├── Import cert-manager-operator-chart
    │       │       ├── presync: Apply CRDs
    │       │       └── install: Deploy operator
    │       │
    │       ├── Import sail-operator-chart
    │       │       ├── presync: Apply Gateway API CRDs
    │       │       ├── presync: Apply Istio CRDs
    │       │       ├── install: Deploy operator + Istio CR
    │       │       └── postsync: Fix webhook loop workaround
    │       │
    │       └── Import lws-operator-chart
    │               ├── presync: Apply CRDs
    │               └── install: Deploy operator
    │
    └── Operators reconcile and deploy operands
            ├── cert-manager controller
            ├── istiod (Gateway API controller)
            └── lws controller
```

### Authentication

Red Hat registry requires authentication:

```yaml
# values.yaml
useSystemPodmanAuth: true  # Uses ~/.config/containers/auth.json
```

Pull secret is created in each operator namespace and attached to ServiceAccounts.

---

## Known Issues & Workarounds

### Sail-Operator Reconciliation Loop

**Issue:** On vanilla Kubernetes, sail-operator enters infinite reconciliation loop due to MutatingWebhookConfiguration caBundle updates.

**Workaround:** Applied automatically via postsync hook:
```bash
kubectl annotate mutatingwebhookconfiguration istio-sidecar-injector \
  sailoperator.io/ignore=true
```

---

## EA1 Usage

### For EA1 Delivery

1. Customer provisions xKS cluster (AKS or CoreWeave)
2. Customer obtains Red Hat pull secret
3. Deploy infrastructure:
   ```bash
   git clone https://github.com/aneeshkp/llm-d-infra-xks
   cd llm-d-infra-xks
   make deploy-all
   ```
4. Deploy KServe controller:
   ```bash
   make deploy-kserve
   ```
5. Set up Gateway and deploy LLMInferenceService (see [Deployment Guide](./deploying-llm-d-on-managed-kubernetes.md))

### Upgrade Path

When new operator versions are released:
```bash
# Update each chart
cd cert-manager-operator-chart
./scripts/update-bundle.sh v1.16.0

cd sail-operator-chart
./scripts/update-bundle.sh 3.3.0

# Redeploy
cd llm-d-infra-xks
make deploy
```

---

## Summary

- **What:** Deploy Red Hat operators on xKS without OLM
- **How:** Extract OLM bundles → Helm charts via olm-extractor
- **Why:** Red Hat support + no OLM on vanilla K8s
- **Result:** LLMInferenceService runs on AKS and CoreWeave with supported components
