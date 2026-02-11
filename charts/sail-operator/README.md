# Sail Operator Helm Chart

Deploy Red Hat Sail Operator (OSSM 3.x / Istio 1.27) on any Kubernetes cluster without OLM.

## Prerequisites

- `kubectl` configured for your cluster
- `helm` 3.17+ (for Server-Side Apply support)
- `helmfile` installed
- Red Hat account for pull secret

## Quick Start

This chart is part of the [rhaii-on-xks](https://github.com/opendatahub-io/rhaii-on-xks) monorepo and is deployed via the top-level helmfile:

```bash
# From the repo root
make deploy-istio

# Or selectively via helmfile
helmfile apply --selector name=sail-operator

# Verify
kubectl get pods -n istio-system
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

# Verify
podman pull registry.redhat.io/ubi8/ubi-minimal --quiet && echo "Auth works!"
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

#### Option C: Konflux (public, no auth)

```yaml
# environments/default.yaml
bundle:
  source: konflux
pullSecretFile: ""
```

### Using with KServe

When deploying alongside KServe, disable the Inference Extension CRDs since KServe installs them via its kustomize overlay (`config/llmisvc`):

```yaml
# environments/default.yaml
gatewayAPI:
  inferenceExtension:
    enabled: false  # KServe installs these CRDs
```

> **Note:** Gateway API CRDs are still installed by the sail-operator chart since KServe doesn't include them in its kustomize configuration.

## What Gets Deployed

**Presync hooks** (before Helm install):
- Namespace `istio-system`
- istiod ServiceAccount with `imagePullSecrets` (pre-created with operator's Helm annotations)
- Gateway API CRDs (v1.4.0) - from GitHub (required)
- Gateway API Inference Extension CRDs (v1.2.0) - from GitHub (optional, skip if using KServe)

**Helm install** (with Server-Side Apply):
- Sail Operator CRDs (19 Istio CRDs) - installed from `crds/` directory with SSA
- Pull secret `redhat-pull-secret`
- Sail Operator deployment + RBAC
- Istio CR with Gateway API enabled

> **Note:** Helm 3.17+ is required for Server-Side Apply (SSA) support. SSA handles large CRDs (some are 700KB+) that would fail with client-side apply.

**Post-install** (automatic):
- Operator deploys istiod (uses pre-created SA with `imagePullSecrets`)

> **Note:** CRDs are applied via presync hooks because they're too large for Helm (some are 700KB+) and require `--server-side` apply. The istiod ServiceAccount is also applied in presync with the operator's expected Helm annotations to avoid ownership conflicts.

## Version Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| Sail Operator | 3.1.4 / 3.2.1 | Red Hat Service Mesh 3.x |
| Istio | v1.26.6 / v1.27.3 | Depends on bundle version |
| Gateway API CRDs | v1.4.0 | Kubernetes SIG |
| Gateway API Inference Extension | v1.2.0 | For LLM inference routing |

**OLM Bundle:** `registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle` ([Red Hat Catalog](https://catalog.redhat.com/en/software/containers/openshift-service-mesh/istio-sail-operator-bundle/67ab6f5f9e87ae6cc720911a))

### Sail Operator vs InferencePool API Version

| Sail Operator | Istio Version | InferencePool API | KServe Compatibility |
|---------------|---------------|-------------------|----------------------|
| 3.1.x | v1.26.x | `inference.networking.x-k8s.io/v1alpha2` | KServe v0.15 (older builds using v1alpha2) |
| **3.2.x** | **v1.27.x** | `inference.networking.k8s.io/v1` | **KServe v0.15** (uses v1 API) |

> **Note:** KServe v0.15 now uses the stable `v1` InferencePool API (`inference.networking.k8s.io`).
> **Use OSSM 3.2.x (Istio v1.27.x) for KServe v0.15.**

### Bundle Version to Istio Version Mapping

| Bundle | Istio Version | `istioVersion` in values.yaml |
|--------|---------------|-------------------------------|
| 3.1.4 | v1.26.6 | `v1.26.6` |
| 3.2.1 | v1.27.3 | `v1.27.3` |

## Update to New Bundle Version

```bash
# Update chart manifests
./scripts/update-bundle.sh 3.3.0 redhat

# Redeploy
helmfile apply
```

### Clean Upgrade (Recommended for version changes)

When changing OSSM/Istio versions, do a clean upgrade to avoid stale resources:

```bash
# 1. Delete the Istio CR (triggers istiod cleanup)
kubectl delete istio default -n istio-system

# 2. Wait for istiod to be removed
kubectl wait --for=delete pod -l app=istiod -n istio-system --timeout=120s

# 3. Delete problematic CRDs (if switching major versions)
kubectl delete crd ztunnels.sailoperator.io --ignore-not-found

# 4. Update the bundle
./scripts/update-bundle.sh 3.1.4 redhat

# 5. Update istioVersion in values.yaml to match bundle
# OSSM 3.1.x -> v1.26.x, OSSM 3.2.x -> v1.27.x
# Linux (GNU sed):
sed -i 's/istioVersion: .*/istioVersion: "v1.26.6"/' values.yaml
# macOS (BSD sed):
# sed -i '' 's/istioVersion: .*/istioVersion: "v1.26.6"/' values.yaml

# 6. Redeploy
helmfile apply
```

> **Note:** The `istio-cr.yaml` template uses `{{ .Values.istioVersion }}` so you must update values.yaml when changing OSSM versions.

## Update Pull Secret

Red Hat pull secrets expire (typically yearly). To update:

```bash
# Option A: Using system podman auth (after re-login)
podman login registry.redhat.io
./scripts/update-pull-secret.sh

# Option B: Using pull secret file
./scripts/update-pull-secret.sh ~/new-pull-secret.txt

# Restart istiod to use new secret
kubectl rollout restart deployment/istiod -n istio-system
```

## Verify Installation

```bash
# Check operator
kubectl get pods -n istio-system

# Check CRDs
kubectl get crd | grep istio

# Check Istio CR
kubectl get istio -n istio-system

# Check istiod
kubectl get pods -n istio-system -l app=istiod
```

## Uninstall

```bash
# Remove Helm release and namespace (keeps CRDs)
./scripts/cleanup.sh

# Full cleanup including CRDs
./scripts/cleanup.sh --include-crds

# Clean cached images from nodes (optional, requires Eraser)
./scripts/cleanup-images.sh --install-eraser
```

---

## Post-Deployment: Pull Secret for Application Namespaces

When deploying applications that use Istio Gateway API (e.g., llm-d), Gateway pods are auto-provisioned in your application namespace and need the pull secret for `istio-proxyv2`.

```bash
# Use the helper script
./scripts/copy-pull-secret.sh <namespace> <gateway-sa-name>

# Example for llm-d:
./scripts/copy-pull-secret.sh llmd-pd infra-inference-scheduling-inference-gateway-istio
```

Or manually:

```bash
export APP_NAMESPACE=<your-namespace>
export GATEWAY_SA=<gateway-sa-name>  # Find with: kubectl get sa -n ${APP_NAMESPACE} | grep gateway

# Copy secret, patch SA, restart pod
kubectl get secret redhat-pull-secret -n istio-system -o yaml | \
  sed "s/namespace: istio-system/namespace: ${APP_NAMESPACE}/" | kubectl apply -f -
kubectl patch sa ${GATEWAY_SA} -n ${APP_NAMESPACE} -p '{"imagePullSecrets": [{"name": "redhat-pull-secret"}]}'
kubectl delete pod -n ${APP_NAMESPACE} -l gateway.istio.io/managed=istio.io-gateway-controller
```

---

## Known Issues

### Infinite Reconciliation Loop on Vanilla Kubernetes

**Problem:** On vanilla Kubernetes (non-OpenShift), the sail-operator may enter an infinite reconciliation loop where Helm chart revisions increment continuously (~1 every 2 seconds).

**Root Cause:** The sail-operator watches webhook configurations but doesn't filter out `caBundle` field changes. When istiod injects the CA certificate into the webhooks, it triggers a reconcile, which runs Helm upgrade, which resets the `caBundle`, creating a loop.

**Fix:** This chart includes an automatic workaround via a Helm post-install Job (`templates/job-fix-webhook-loop.yaml`) that adds the `sailoperator.io/ignore=true` annotation to both webhooks after deployment:
- `MutatingWebhookConfiguration/istio-sidecar-injector`
- `ValidatingWebhookConfiguration/istio-validator-istio-system`

The Job runs automatically and cleans up after success. To disable: set `fixWebhookLoop.enabled: false` in values.yaml.

**If you're already affected** (revisions keep increasing):

```bash
# Apply the workaround manually to both webhooks
kubectl annotate mutatingwebhookconfiguration istio-sidecar-injector sailoperator.io/ignore=true --overwrite
kubectl annotate validatingwebhookconfiguration istio-validator-istio-system sailoperator.io/ignore=true --overwrite

# Verify the loop stops
helm list -n istio-system  # Revision should stop incrementing
```

---

## File Structure

```
charts/sail-operator/
├── Chart.yaml
├── values.yaml                  # Default values
├── helmfile.yaml.gotmpl         # Deploy with: helmfile apply
├── .helmignore                  # Excludes large files from Helm
├── environments/
│   └── default.yaml             # User config (useSystemPodmanAuth)
├── crds/                        # 19 Istio CRDs (installed by Helm with SSA)
├── manifests-presync/           # Resources applied before Helm install
│   ├── namespace.yaml              # istio-system namespace
│   └── serviceaccount-istiod.yaml  # istiod SA with imagePullSecrets
├── templates/
│   ├── deployment-*.yaml           # Sail Operator deployment
│   ├── istio-cr.yaml               # Istio CR with Gateway API
│   ├── job-fix-webhook-loop.yaml   # Post-install hook to fix reconciliation loop
│   ├── pull-secret.yaml            # Registry pull secret
│   └── *.yaml                      # RBAC, ServiceAccount, etc.
└── scripts/
    ├── update-bundle.sh         # Update to new bundle version
    ├── update-pull-secret.sh    # Update expired pull secret
    ├── cleanup.sh               # Full uninstall
    ├── cleanup-images.sh        # Remove cached images from nodes (uses Eraser)
    ├── copy-pull-secret.sh      # Copy secret to app namespaces
    ├── fix-webhook-loop.sh      # Manual workaround for reconciliation loop (backup)
    └── post-install-message.sh  # Prints next steps after helmfile apply
```
