# RHCL Helm Chart Architecture Design

> APPENG-4671: Design Helm Chart Architecture
> Describes the design decisions for the RHCL chart structure and deployment strategy.

---

## 1. Directory Structure

```
charts/rhcl/
├── Chart.yaml                    # Chart metadata (apiVersion v2, version 1.2.0)
├── values.yaml                   # All configurable parameters
├── .helmignore                   # Excludes scripts/test/docs from chart package
├── helmfile.yaml.gotmpl          # Three-phase orchestration (see HELMFILE-DESIGN.md)
│
├── templates/                    # Helm templates (rendered by helm install)
│   ├── _helpers.tpl              # Reusable template functions
│   ├── pull-secret.yaml          # Registry pull secrets (operator + instance + gateway NS)
│   ├── operators/                # One Deployment template per operator
│   │   ├── kuadrant-operator.yaml
│   │   ├── authorino-operator.yaml
│   │   ├── limitador-operator.yaml
│   │   └── dns-operator.yaml
│   ├── rbac/                     # ClusterRoles + ClusterRoleBindings
│   │   ├── kuadrant-operator-rbac.yaml
│   │   ├── authorino-operator-rbac.yaml
│   │   ├── authorino-component-rbac.yaml   # Pre-created for Authorino instance
│   │   ├── limitador-operator-rbac.yaml
│   │   ├── dns-operator-rbac.yaml
│   │   ├── metrics-reader-rbac.yaml        # Prometheus scraping
│   │   └── user-facing-rbac.yaml           # AuthConfig editor/viewer
│   ├── serviceaccounts/
│   │   └── component-serviceaccounts.yaml  # authorino-authorino SA
│   └── monitoring/
│       └── servicemonitors.yaml            # Optional (monitoring.enabled)
│
├── crds/                         # 14 CRD YAML files (flat, deduplicated)
│   ├── kuadrants.kuadrant.io.yaml
│   ├── authpolicies.kuadrant.io.yaml
│   ├── ...                       # (14 total)
│   └── limitadors.limitador.kuadrant.io.yaml
│
├── manifests-presync/            # Applied by helmfile BEFORE helm install
│   ├── namespaces.yaml           # kuadrant-operators, kuadrant-system
│   └── serviceaccounts.yaml      # 4 operator SAs with imagePullSecrets
│
├── manifests-postsync/           # Run by helmfile AFTER helm install
│   └── validate.sh               # Deployment health check
│
├── scripts/                      # Utility scripts (not part of chart package)
│   ├── update-bundle.sh          # Extract CRDs/manifests from OLM bundle (olm-extractor)
│   └── clean-crds.sh             # Strips runtime metadata from CRD files
│
# Tests and validation scripts live at the repo root (per repo convention):
#   validation/rhcl-pre-deploy-check.sh     — Pre-flight cluster validation
#   test/conformance/verify-rhcl-deployment.sh  — Integration tests
#   test/conformance/verify-rhcl-dns.sh         — DNS operator tests
│
├── docs/                         # Technical documentation
├── examples/                     # Example values files (dev, production)
├── README.md                     # User-facing documentation
├── ARCHITECTURE.md               # Technical architecture reference
└── Makefile                      # Automation targets
```

### Design Rationale

- **`crds/` is flat** (no subdirectories): Helm applies all YAML files in `crds/` via Server-Side Apply. Subdirectories are organizational only and caused confusion in mpaul's chart where CRDs were duplicated across `crds/kuadrant/`, `crds/authorino/`, etc.

- **`manifests-presync/` is separate from `templates/`**: These resources are applied by helmfile hooks BEFORE `helm install`, so they can't be Helm templates. Namespaces and ServiceAccounts must exist before operators can be deployed.

- **`templates/operators/` has one file per operator**: Each operator Deployment is independently toggleable via `operators.*.enabled`. This makes it easy to disable DNS operator without affecting others.

- **`templates/rbac/` separates operator from component RBAC**: Operator RBAC (created by chart, bound by chart) vs component RBAC (created by chart, bound by operator at runtime). This distinction is critical for the Authorino component ClusterRoles.

---

## 2. Meta-Operator Reconciliation Flow

The Kuadrant operator follows a **meta-operator pattern** where creating a single CR triggers a cascade of sub-operator reconciliation:

```
User creates Kuadrant CR
    │
    ▼
Kuadrant Operator sees Kuadrant CR
    ├── Creates Authorino CR ──→ Authorino Operator sees it
    │                               ├── Creates Authorino Deployment
    │                               ├── Creates 3 Services
    │                               ├── Creates leader-election Role/RoleBinding
    │                               └── Creates ClusterRoleBindings for component roles
    │
    └── Creates Limitador CR ──→ Limitador Operator sees it
                                    ├── Creates Limitador Deployment
                                    ├── Creates headless Service
                                    └── Creates limits ConfigMap
```

### Why the Kuadrant CR is NOT a Helm template

If the Kuadrant CR were a Helm template, it would be applied at the same time as operator Deployments. But operators need to be running FIRST to reconcile the CR. The postsync hook solves this by waiting for `condition=Available` on all operator Deployments before creating the CR.

---

## 3. RBAC Organization

Three categories of RBAC, each with different lifecycle management:

### Category 1: Operator RBAC (chart-managed, chart-bound)

| ClusterRole | Bound To | Created By | Lifecycle |
|-------------|----------|-----------|-----------|
| `kuadrant-operator-manager-role` | `kuadrant-operator-controller-manager` SA | Helm template | Installed/removed with chart |
| `authorino-operator-manager-role` | `authorino-operator` SA | Helm template | Installed/removed with chart |
| `limitador-operator-manager-role` | `limitador-operator-controller-manager` SA | Helm template | Installed/removed with chart |
| `dns-operator-manager-role` | `dns-operator-controller-manager` SA | Helm template | Conditional on `operators.dns.enabled` |

### Category 2: Component RBAC (chart-managed, operator-bound)

| ClusterRole | Bound By | Why Chart Creates It |
|-------------|----------|---------------------|
| `authorino-manager-role` | Authorino Operator (at runtime) | Must exist before operator creates the binding |
| `authorino-manager-k8s-auth-role` | Authorino Operator (at runtime) | Same |

### Category 3: Utility RBAC (chart-managed, not bound)

| ClusterRole | Purpose |
|-------------|---------|
| `limitador-operator-metrics-reader` | Allows Prometheus to scrape `/metrics` |
| `authorino-authconfig-editor-role` | Convenience: dev teams can edit AuthConfigs |
| `authorino-authconfig-viewer-role` | Convenience: dev teams can view AuthConfigs |

---

## 4. values.yaml Structure

```yaml
platform:           # openshift | kubernetes
namespaces:         # operators + instances namespace names
gatewayNamespaces:  # list of namespaces for wasm-plugin-pull-secret
images:
  registry:         # registry.redhat.io
  pullSecret:       # name, create flag, dockerConfigJson
  operators:        # 4 operator images with digest pins
  components:       # 3 component images with digest pins
operators:
  kuadrant:         # enabled, replicas, resources, affinity, env
  authorino:        # same structure
  limitador:        # same structure
  dns:              # same structure (default: disabled)
instance:
  kuadrant:         # enabled, name
rbac:
  create:           # master toggle for all RBAC
monitoring:
  enabled:          # ServiceMonitor creation toggle
prerequisites:      # cert-manager and Gateway API validation toggles
```

### Design Principles

- **Every image is digest-pinned**: No `:latest` or mutable tags. Ensures reproducible deployments.
- **Every operator has the same config shape**: `enabled`, `replicas`, `resources`, `affinity`, `tolerations`, `nodeSelector`, `env`, `podSecurityContext`. This makes the chart predictable.
- **GPU avoidance by default**: Azure xKS clusters have expensive GPU nodes. Operators don't need GPUs, so `affinity.nodeAffinity` excludes `sku=gpu` nodes.
- **`gatewayNamespaces` is a list**: Unlike mpaul's chart which only creates wasm-plugin-pull-secret in the instance namespace, we create it in every namespace where a Gateway proxy runs.

---

## 5. imagePullSecrets Strategy

Three layers of pull secret management:

| Layer | Where | What | How |
|-------|-------|------|-----|
| **Operator pods** | `kuadrant-operators` | Operators pulling their own images from `registry.redhat.io` | ServiceAccounts in `manifests-presync/serviceaccounts.yaml` have `imagePullSecrets: [redhat-pull-secret]` |
| **Component pods** | `kuadrant-system` | Authorino/Limitador pulling component images | `templates/pull-secret.yaml` creates secret in instance NS; `templates/serviceaccounts/component-serviceaccounts.yaml` pre-creates `authorino-authorino` SA with pull secret; postsync patches `default` SA for Limitador |
| **WASM shim** | Gateway namespace(s) | Envoy proxy pulling WASM shim image from `registry.access.redhat.com` | `templates/pull-secret.yaml` creates `wasm-plugin-pull-secret` in each `gatewayNamespaces` entry |

### Auth Source Priority (in helmfile.yaml.gotmpl)

1. `useSystemPodmanAuth: true` → reads `~/.config/containers/auth.json`
2. `images.pullSecret.dockerConfigJson` → inline value (for CI/CD)
3. `pullSecretFile` → reads file at given path (with HOME security validation)
4. `authFile` → same as pullSecretFile (alias)

---

## 6. Security Hardening

Every operator Deployment applies these security controls:

| Control | Value | Why |
|---------|-------|-----|
| `runAsNonRoot` | `true` | Prevents running as root |
| `readOnlyRootFilesystem` | `true` | Prevents filesystem writes |
| `allowPrivilegeEscalation` | `false` | Prevents gaining extra privileges |
| `capabilities.drop` | `["ALL"]` | Drops all Linux capabilities |
| `seccompProfile.type` | `RuntimeDefault` | Applies default seccomp profile |

All images use digest pinning (`@sha256:...`) instead of mutable tags for supply chain security.
