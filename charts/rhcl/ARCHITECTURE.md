# RHCL Architecture

Technical architecture documentation for the Red Hat Connectivity Link (RHCL) Helm chart.

## Meta-Operator Pattern

RHCL uses a **meta-operator pattern** where one top-level operator (Kuadrant) orchestrates multiple sub-operators:

```
                    ┌─────────────────────────────────┐
                    │         Kuadrant Operator         │
                    │     (meta-operator / orchestrator)│
                    └────────┬───────────┬─────────────┘
                             │           │
                    ┌────────▼──┐   ┌────▼──────────┐
                    │ Authorino  │   │   Limitador    │
                    │ Operator   │   │   Operator     │
                    └────────┬──┘   └────┬──────────┘
                             │           │
                    ┌────────▼──┐   ┌────▼──────────┐
                    │ Authorino  │   │   Limitador    │
                    │ (auth      │   │   (rate        │
                    │  server)   │   │    limiter)    │
                    └───────────┘   └───────────────┘
```

### How It Works

1. The Helm chart deploys **operator Deployments** in `kuadrant-operators` namespace
2. A **Kuadrant CR** is created in `kuadrant-system` via postsync hook
3. The Kuadrant operator sees the CR and creates **Authorino CR** + **Limitador CR**
4. The Authorino operator sees its CR and creates the **Authorino Deployment** + Services
5. The Limitador operator sees its CR and creates the **Limitador Deployment** + Service + ConfigMap

### Ownership Chain

```
Kuadrant CR (kuadrant-system/kuadrant)
  │  ownerRef: none (user-created via postsync)
  │
  ├── Authorino CR (kuadrant-system/authorino)
  │     ownerRef: Kuadrant/kuadrant
  │     │
  │     ├── Deployment (kuadrant-system/authorino)
  │     │     ownerRef: Authorino/authorino
  │     │
  │     ├── Service (authorino-authorino-authorization)
  │     │     ports: 50051 (gRPC ext_authz), 5001 (HTTP)
  │     │
  │     ├── Service (authorino-authorino-oidc)
  │     │     ports: 8083 (OIDC discovery)
  │     │
  │     ├── Service (authorino-controller-metrics)
  │     │     ports: 8080 (Prometheus metrics)
  │     │
  │     ├── Role (authorino-leader-election-role)
  │     ├── RoleBinding (authorino-authorino-leader-election)
  │     ├── ClusterRoleBinding (authorino → authorino-manager-role)
  │     └── ClusterRoleBinding (authorino-k8s-auth → authorino-manager-k8s-auth-role)
  │
  └── Limitador CR (kuadrant-system/limitador)
        ownerRef: Kuadrant/kuadrant
        │
        ├── Deployment (kuadrant-system/limitador-limitador)
        │     ownerRef: Limitador/limitador
        │
        ├── Service (limitador-limitador)
        │     ClusterIP: None (headless)
        │     ports: 8080 (HTTP), 8081 (gRPC)
        │
        └── ConfigMap (limitador-limits-config-limitador)
              Updated by Kuadrant operator when RateLimitPolicy resources change
```

## Three-Phase Deployment

The Helmfile orchestrates deployment in three phases to handle ordering dependencies.

```
Phase 1: PRESYNC                Phase 2: HELM INSTALL           Phase 3: POSTSYNC
─────────────────               ─────────────────────           ─────────────────
                                                                
Create namespaces:              Apply CRDs (SSA)                Wait for operators:
  kuadrant-operators              14 Kuadrant CRDs                kubectl wait
  kuadrant-system                                                 --for=condition=Available
                                Deploy operators:                 deployment/kuadrant-op
Pre-create ServiceAccounts        Kuadrant Deployment             deployment/authorino-op
  with imagePullSecrets           Authorino Deployment            deployment/limitador-op
                                  Limitador Deployment
Apply manifests-presync/          (DNS if enabled)              Create Kuadrant CR:
                                                                  apiVersion: kuadrant.io/v1beta1
                                Create RBAC:                      kind: Kuadrant
                                  7 ClusterRoles                  spec: {}
                                  4 ClusterRoleBindings
                                                                Patch imagePullSecrets
                                Create pull secrets:              on component SAs
                                  operator NS
                                  instance NS                   Wait for Kuadrant Ready
                                  gateway NS(es)
                                                                Validate Authorino +
                                                                Limitador instances exist
```

### Why Three Phases?

- **CRDs must exist before CRs** — Helm installs CRDs before templates, but the Kuadrant CR needs operators running first
- **Operators must be ready before Kuadrant CR** — if the CR is created before operators start, reconciliation fails
- **imagePullSecrets must be patched** — the Limitador operator creates a default ServiceAccount that doesn't have pull secrets

### Uninstall Phases

```
Phase 1: PREUNINSTALL           Phase 2: HELM UNINSTALL         Phase 3: POSTUNINSTALL
─────────────────────           ────────────────────────         ──────────────────────

Delete Kuadrant CR              Remove Deployments              Delete namespaces:
  → cascades to                 Remove RBAC                       kuadrant-system
    Authorino CR                Remove Secrets                    kuadrant-operators
    Limitador CR                Remove ServiceAccounts
                                                                Delete CRDs:
Wait for sub-instances                                            *.kuadrant.io
to be deleted                                                     *.authorino.kuadrant.io
                                                                  *.limitador.kuadrant.io
Strip finalizers if stuck
```

## RBAC Model

The chart creates two categories of RBAC:

### Operator RBAC (chart-managed)

Created by Helm templates, one per operator. These allow operators to manage their CRDs, create sub-resources, and perform leader election.

| ClusterRole | Bound To | Rules |
|-------------|----------|-------|
| `kuadrant-operator-manager-role` | SA `kuadrant-operator-controller-manager` | ~50 rules: all Kuadrant CRDs, Gateway API, cert-manager, Istio, Envoy Gateway |
| `authorino-operator-manager-role` | SA `authorino-operator` | ~20 rules: AuthConfig, Authorino CRDs, RBAC management, Deployments |
| `limitador-operator-manager-role` | SA `limitador-operator-controller-manager` | ~20 rules: Limitador CRD, PVC, PDB, monitoring, Deployments |
| `dns-operator-manager-role` | SA `dns-operator-controller-manager` | ~15 rules: DNS CRDs, Gateway API (read), endpoints |

### Component RBAC (chart-managed, operator-bound)

Pre-created by Helm but ClusterRoleBindings are created by the Authorino operator at runtime when it deploys the Authorino instance.

| ClusterRole | Bound By | Purpose |
|-------------|----------|---------|
| `authorino-manager-role` | Authorino Operator (runtime) | AuthConfig CRUD, Secret read, lease management |
| `authorino-manager-k8s-auth-role` | Authorino Operator (runtime) | TokenReview, SubjectAccessReview for K8s-native auth |

### Utility RBAC (chart-managed)

| ClusterRole | Purpose |
|-------------|---------|
| `limitador-operator-metrics-reader` | Allows Prometheus to scrape `/metrics` on operator |
| `authorino-authconfig-editor-role` | Convenience: teams can edit AuthConfig resources |
| `authorino-authconfig-viewer-role` | Convenience: teams can view AuthConfig resources |

## CRD Organization

14 unique CRDs in a flat `crds/` directory (Helm applies all files via Server-Side Apply):

| CRD | Owner | Purpose |
|-----|-------|---------|
| `kuadrants.kuadrant.io` | Kuadrant | Main instance CR |
| `authpolicies.kuadrant.io` | Kuadrant | Auth/authz policies targeting Gateway/HTTPRoute |
| `ratelimitpolicies.kuadrant.io` | Kuadrant | Rate limiting policies |
| `tokenratelimitpolicies.kuadrant.io` | Kuadrant | Token-based rate limits (alpha) |
| `tlspolicies.kuadrant.io` | Kuadrant | TLS certificate management via cert-manager |
| `dnspolicies.kuadrant.io` | Kuadrant | DNS routing policies |
| `dnsrecords.kuadrant.io` | Kuadrant | DNS record management |
| `dnshealthcheckprobes.kuadrant.io` | Kuadrant | DNS health probes |
| `oidcpolicies.extensions.kuadrant.io` | Kuadrant | OIDC integration (extension) |
| `planpolicies.extensions.kuadrant.io` | Kuadrant | Plan/tier policies (extension) |
| `telemetrypolicies.extensions.kuadrant.io` | Kuadrant | Telemetry policies (extension) |
| `authconfigs.authorino.kuadrant.io` | Authorino | Auth configurations (created by Kuadrant from AuthPolicy) |
| `authorinos.operator.authorino.kuadrant.io` | Authorino | Authorino instance CR |
| `limitadors.limitador.kuadrant.io` | Limitador | Limitador instance CR |

## Image Management

### Operator Images

Operators are deployed with digest-pinned images from `registry.redhat.io`. The digest is specified in `values.yaml` and rendered into Deployment templates.

### Component Images

Component images (Authorino server, Limitador server, WASM shim) are NOT deployed directly by the chart. Instead, operators deploy them using `RELATED_IMAGE_*` environment variables:

```
Kuadrant Operator
  env: RELATED_IMAGE_WASMSHIM → registry.access.redhat.com/rhcl-1/wasm-shim-rhel9@sha256:...

Authorino Operator
  env: RELATED_IMAGE_AUTHORINO → registry.redhat.io/rhcl-1/authorino-rhel9@sha256:...

Limitador Operator
  env: RELATED_IMAGE_LIMITADOR → registry.redhat.io/rhcl-1/limitador-rhel9@sha256:...
```

This pattern ensures operators always use the correct component version without direct chart management.

### Pull Secrets

Three categories of pull secrets:

| Secret | Namespace | Purpose |
|--------|-----------|---------|
| `redhat-pull-secret` | `kuadrant-operators` | Operator image pulls |
| `redhat-pull-secret` | `kuadrant-system` | Component image pulls |
| `wasm-plugin-pull-secret` | `kuadrant-system` + each `gatewayNamespaces` entry | WASM shim image pull by Envoy proxy |

## Data Flow: Request Processing

When a client makes an HTTP request through the Kuadrant-protected gateway:

```
Client
  │
  ▼
AWS/Azure Load Balancer
  │
  ▼
Gateway Proxy (Envoy, in ingress-gateway namespace)
  │
  ├──── WasmPlugin (kuadrant-prod-web)
  │       Injected by Kuadrant operator
  │       Routes decisions to Authorino + Limitador
  │
  ├──── EnvoyFilter (kuadrant-auth-prod-web)
  │       │
  │       ▼
  │     Authorino (kuadrant-system, gRPC :50051)
  │       Checks AuthConfig rules:
  │         - API key validation (from Secrets)
  │         - JWT validation (from OIDC provider)
  │         - OPA policies
  │       Returns: ALLOW or DENY (401/403)
  │
  ├──── EnvoyFilter (kuadrant-ratelimiting-prod-web)
  │       │
  │       ▼
  │     Limitador (kuadrant-system, gRPC :8081)
  │       Checks rate limit counters:
  │         - Per-route limits from RateLimitPolicy
  │         - In-memory or Redis-backed
  │       Returns: ALLOW or DENY (429)
  │
  ▼
Backend Service (e.g., node-api:8080)
```

## Namespace Layout

```
kuadrant-operators (operator deployments)
  ├── kuadrant-operator-controller-manager
  ├── authorino-operator
  ├── limitador-operator-controller-manager
  └── dns-operator-controller-manager (optional)

kuadrant-system (instances + components)
  ├── Kuadrant CR
  ├── Authorino CR → Authorino Deployment + Services
  ├── Limitador CR → Limitador Deployment + Service
  ├── AuthConfig CRs (created by Kuadrant from AuthPolicy)
  ├── API key Secrets (user-created)
  └── limitador-limits-config ConfigMap

ingress-gateway (or user-configured gateway namespace)
  ├── Gateway CR (user-created)
  ├── WasmPlugin (kuadrant-prod-web, created by Kuadrant)
  ├── EnvoyFilter (kuadrant-auth-*, created by Kuadrant)
  ├── EnvoyFilter (kuadrant-ratelimiting-*, created by Kuadrant)
  ├── wasm-plugin-pull-secret (chart-created)
  └── Gateway proxy Deployment (created by Istio)
```

## OpenShift vs Kubernetes Differences

| Feature | OpenShift (`platform.type: openshift`) | Kubernetes |
|---------|---------------------------------------|------------|
| Gateway controller | `ISTIO_GATEWAY_CONTROLLER_NAMES=openshift.io/gateway-controller/v1` | Not set (uses default Istio controller) |
| Security contexts | SCC-compatible (runAsNonRoot, drop ALL) | Same |
| Pull secrets | Same auth.json format | Same |
| ServiceAccounts | OpenShift auto-creates builder/deployer/default SAs | Only default SA |

## Chart vs Operator Responsibilities

Understanding what the chart manages vs what operators manage is critical:

| Responsibility | Managed By |
|---------------|-----------|
| Operator Deployments | Chart (Helm templates) |
| CRDs | Chart (Helm `crds/` directory) |
| Operator RBAC (ClusterRoles) | Chart (Helm templates) |
| Pull Secrets | Chart (Helm templates) |
| Kuadrant CR | Chart (Helmfile postsync) |
| Authorino/Limitador CRs | Kuadrant Operator (from Kuadrant CR) |
| Authorino Deployment + Services | Authorino Operator (from Authorino CR) |
| Limitador Deployment + Service | Limitador Operator (from Limitador CR) |
| Component ClusterRoleBindings | Authorino Operator (runtime) |
| AuthConfig CRs | Kuadrant Operator (from AuthPolicy) |
| WasmPlugin + EnvoyFilters | Kuadrant Operator (from policies) |
| Gateway proxy Deployment | Istio (from Gateway CR) |
| Certificates + TLS Secrets | cert-manager (from TLSPolicy) |
