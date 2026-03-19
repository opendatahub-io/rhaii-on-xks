# Red Hat Connectivity Link (RHCL) Helm Chart

Deploys the [Kuadrant](https://kuadrant.io/) operator stack on OpenShift (ARO on Azure / xKS), providing API gateway authentication, authorization, rate limiting, and TLS policy management.

## What This Chart Deploys

| Component | Description | Default |
|-----------|-------------|---------|
| **Kuadrant Operator** | Meta-operator that orchestrates Authorino and Limitador | Enabled |
| **Authorino Operator** | Manages Authorino instances for API auth/authz (gRPC ext_authz) | Enabled |
| **Limitador Operator** | Manages Limitador instances for rate limiting | Enabled |
| **DNS Operator** | Manages DNS records for multi-cluster routing | Disabled |
| **14 CRDs** | Kuadrant policy CRDs (AuthPolicy, RateLimitPolicy, TLSPolicy, etc.) | Installed |
| **RBAC** | 7 ClusterRoles + ClusterRoleBindings for operators and components | Created |

After deployment, the Kuadrant operator automatically creates:
- Authorino instance (auth server) with 3 services
- Limitador instance (rate limiter) with headless service
- AuthConfig CRs from AuthPolicy resources
- WasmPlugin + EnvoyFilter resources in gateway namespaces

## Prerequisites

- OpenShift 4.16+ (ARO on Azure recommended)
- [cert-manager](../cert-manager-operator/) installed and healthy
- [Istio / Service Mesh](../sail-operator/) installed (Gateway API provider)
- [Gateway API CRDs](https://gateway-api.sigs.k8s.io/) v1.0.0+ installed
- `kubectl` / `oc` CLI configured
- `helmfile` installed
- Red Hat registry credentials (`~/.config/containers/auth.json`)

Run `make check` to validate all prerequisites.

## Quick Start

```bash
cd charts/rhcl/

# 1. Check prerequisites
make check

# 2. Copy CRDs (first time only)
make copy-crds

# 3. Lint the chart
make lint

# 4. Deploy
make install

# 5. Validate
make validate

# 6. Check status
make status
```

### Deploy from root helmfile

```bash
# Deploy all operators (cert-manager, sail, lws, rhcl, kserve)
helmfile apply

# Deploy only RHCL
helmfile apply --selector name=rhcl
```

## Configuration

### Key Values

| Parameter | Default | Description |
|-----------|---------|-------------|
| `platform.type` | `openshift` | Platform type (`openshift` or `kubernetes`) |
| `namespaces.operators` | `kuadrant-operators` | Namespace for operator deployments |
| `namespaces.instances` | `kuadrant-system` | Namespace for Kuadrant instance and components |
| `gatewayNamespaces` | `[]` | Namespace(s) where `wasm-plugin-pull-secret` should be created |
| `images.registry` | `registry.redhat.io` | Container image registry |
| `images.pullSecret.create` | `true` | Create pull secrets for Red Hat registry |
| `operators.kuadrant.enabled` | `true` | Deploy Kuadrant operator |
| `operators.authorino.enabled` | `true` | Deploy Authorino operator |
| `operators.limitador.enabled` | `true` | Deploy Limitador operator |
| `operators.dns.enabled` | `false` | Deploy DNS operator |
| `operators.*.resources` | See values.yaml | CPU/memory requests and limits |
| `operators.*.affinity` | GPU avoidance | Node affinity rules (Azure `sku!=gpu`) |
| `instance.kuadrant.enabled` | `true` | Create Kuadrant CR in postsync |
| `rbac.create` | `true` | Create ClusterRoles and ClusterRoleBindings |
| `monitoring.enabled` | `false` | Create ServiceMonitor resources |

### Image Configuration

All images are digest-pinned for reproducibility. The chart uses 7 images:

| Image | Type | Registry |
|-------|------|----------|
| `rhcl-1/rhcl-rhel9-operator` | Kuadrant operator | `registry.redhat.io` |
| `rhcl-1/authorino-rhel9-operator` | Authorino operator | `registry.redhat.io` |
| `rhcl-1/limitador-rhel9-operator` | Limitador operator | `registry.redhat.io` |
| `rhcl-1/dns-rhel9-operator` | DNS operator | `registry.redhat.io` |
| `rhcl-1/authorino-rhel9` | Authorino component | `registry.redhat.io` |
| `rhcl-1/limitador-rhel9` | Limitador component | `registry.redhat.io` |
| `rhcl-1/wasm-shim-rhel9` | WASM Envoy filter | `registry.access.redhat.com` |

### Gateway Namespace Configuration

The `wasm-plugin-pull-secret` must exist in every namespace where a Gateway proxy runs, so the Envoy sidecar can pull the WASM shim image. Configure this in `values.yaml`:

```yaml
gatewayNamespaces:
  - ingress-gateway
  - my-other-gateway-ns
```

### Example Configurations

- **Development**: `examples/values-development.yaml` (minimal resources, no monitoring)
- **Production**: `examples/values-production.yaml` (higher resources, monitoring, Redis notes)

## Deployment Lifecycle

The chart uses Helmfile with a three-phase deployment:

```
1. PRESYNC     Create namespaces, pre-create ServiceAccounts with imagePullSecrets
2. HELM INSTALL  CRDs (Server-Side Apply) + operator Deployments + RBAC + pull secrets
3. POSTSYNC    Wait for operators -> create Kuadrant CR -> validate Authorino/Limitador
```

Uninstall is also multi-phase:

```
1. PREUNINSTALL   Delete Kuadrant CR, strip finalizers, wait for cleanup
2. HELM UNINSTALL Remove Deployments, RBAC, Secrets
3. POSTUNINSTALL  Delete namespaces, delete CRDs
```

## Testing

```bash
# Run integration test (deploys Gateway + AuthPolicy + RateLimitPolicy)
make test

# Run DNS operator test (requires operators.dns.enabled=true)
make test-dns

# Run post-deploy health check
make validate
```

See `test/README.md` for detailed test documentation.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make help` | Show all available targets |
| `make check` | Pre-deployment prerequisite checks |
| `make copy-crds` | Copy and deduplicate CRDs from source |
| `make lint` | Run `helm lint` |
| `make template` | Render templates to stdout |
| `make install` | Deploy via `helmfile apply` |
| `make validate` | Post-deploy health check |
| `make status` | Show operator/instance/CRD status |
| `make logs` | Tail operator logs (`OPERATOR=kuadrant\|authorino\|limitador\|dns`) |
| `make test` | Run integration tests |
| `make test-dns` | Run DNS operator tests |
| `make destroy` | Remove via `helmfile destroy` |
| `make clean-crds` | Remove all RHCL CRDs from cluster |

## Troubleshooting

### Operators not starting

```bash
# Check operator pod status
kubectl get pods -n kuadrant-operators

# Check events
kubectl get events -n kuadrant-operators --sort-by='.lastTimestamp'

# Check operator logs
make logs OPERATOR=kuadrant
```

### Kuadrant CR not Ready

```bash
kubectl describe kuadrant kuadrant -n kuadrant-system
```

Common causes:
- Authorino or Limitador operator not ready yet (wait longer)
- RBAC missing (check ClusterRoles exist: `kubectl get clusterrole | grep kuadrant`)

### ImagePullBackOff

```bash
kubectl get events -n kuadrant-operators | grep -i pull
```

Solutions:
- Verify `~/.config/containers/auth.json` contains `registry.redhat.io` credentials
- Check `wasm-plugin-pull-secret` exists in gateway namespace: `kubectl get secret wasm-plugin-pull-secret -n ingress-gateway`

### Finalizer stuck resources

During uninstall, resources may get stuck in `Terminating` state:

```bash
# Strip finalizers manually
kubectl patch kuadrant kuadrant -n kuadrant-system -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl patch authorino authorino -n kuadrant-system -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl patch limitador limitador -n kuadrant-system -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### Policies not enforced

1. Check WasmPlugin exists in gateway namespace: `kubectl get wasmplugin -n ingress-gateway`
2. Check EnvoyFilters: `kubectl get envoyfilter -n ingress-gateway`
3. Check AuthConfig: `kubectl get authconfig -n kuadrant-system`
4. Verify the `wasm-plugin-pull-secret` exists in the gateway namespace

## Known Limitations

| Limitation | Severity | Notes |
|------------|----------|-------|
| **Limitador uses in-memory storage** | Medium | Rate limit counters lost on pod restart. Configure Redis for persistence (see `examples/values-production.yaml`). |
| **Single-replica operators** | Low | Operators use leader election; multi-replica is safe but untested in this chart. |
| **DNS operator disabled** | Low | Requires cloud DNS credentials (AWS/Azure/GCP). Enable with `operators.dns.enabled=true`. |
| **WASM shim pull secret** | Medium | Must be present in each gateway namespace. Configure `gatewayNamespaces` in values.yaml. |

## Uninstall

```bash
# Via Makefile
make destroy

# Via helmfile directly
cd charts/rhcl/ && helmfile destroy

# Manual CRD cleanup (if needed after uninstall)
make clean-crds
```

## References

- [Kuadrant documentation](https://docs.kuadrant.io/)
- [Red Hat Connectivity Link documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/)
- [Authorino operator](https://github.com/Kuadrant/authorino-operator)
- [Limitador operator](https://github.com/Kuadrant/limitador-operator)
- [Pattern repo (mpaul)](https://github.com/mpaulgreen/rhaii-on-xks/tree/rhcl-integration/charts/rhcl)
