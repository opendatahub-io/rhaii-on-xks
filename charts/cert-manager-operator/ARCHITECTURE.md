# cert-manager Operator Helm Chart - Architecture

Deploy Red Hat cert-manager Operator on vanilla Kubernetes (AKS, EKS, GKE) without OLM.

## Source Repositories

| Repo | Purpose |
|------|---------|
| [openshift/cert-manager-operator](https://github.com/openshift/cert-manager-operator) | Operator code |
| [openshift/jetstack-cert-manager](https://github.com/openshift/jetstack-cert-manager) | Operand (Red Hat fork) |
| [lburgazzoli/olm-extractor](https://github.com/lburgazzoli/olm-extractor) | Extract OLM bundles for non-OLM clusters |

**OLM Bundle:** `registry.redhat.io/cert-manager/cert-manager-operator-bundle`
- [Red Hat Catalog](https://catalog.redhat.com/en/software/container-stacks/detail/64f1ad6f3af5362f09c9ce16)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Helm Chart                                │
├─────────────────────────────────────────────────────────────────┤
│  Presync (helmfile)                                             │
│  ├── CRDs (server-side apply)                                   │
│  ├── Infrastructure CRD/CR stub                                 │
│  ├── cert-manager namespace                                     │
│  └── CertManager CR                                             │
├─────────────────────────────────────────────────────────────────┤
│  Helm Install                                                   │
│  ├── cert-manager-operator namespace                            │
│  ├── Pull secrets (both namespaces)                             │
│  ├── ServiceAccounts with imagePullSecrets                      │
│  │   ├── cert-manager                                           │
│  │   ├── cert-manager-cainjector                                │
│  │   └── cert-manager-webhook                                   │
│  └── Operator deployment + RBAC                                 │
├─────────────────────────────────────────────────────────────────┤
│  Operator (post-install)                                        │
│  ├── Reconciles ServiceAccounts (preserves imagePullSecrets)    │
│  └── Deploys cert-manager components                            │
│      ├── controller                                             │
│      ├── cainjector                                             │
│      └── webhook                                                │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Namespaces
- `cert-manager-operator` - Operator namespace
- `cert-manager` - Operand namespace (where cert-manager runs)

### Images (registry.redhat.io)

| Component | Image |
|-----------|-------|
| Operator | `registry.redhat.io/cert-manager/cert-manager-operator-rhel9` |
| Controller | `registry.redhat.io/cert-manager/jetstack-cert-manager-rhel9` |
| CA Injector | `registry.redhat.io/cert-manager/jetstack-cert-manager-cainjector-rhel9` |
| Webhook | `registry.redhat.io/cert-manager/jetstack-cert-manager-webhook-rhel9` |
| ACME Solver | `registry.redhat.io/cert-manager/jetstack-cert-manager-acmesolver-rhel9` |

### CRDs
- `certificates.cert-manager.io`
- `certificaterequests.cert-manager.io`
- `issuers.cert-manager.io`
- `clusterissuers.cert-manager.io`
- `orders.acme.cert-manager.io`
- `challenges.acme.cert-manager.io`
- `certmanagers.operator.openshift.io` (Operator CR)
- `infrastructures.config.openshift.io` (Stub for non-OpenShift)

## Non-OpenShift Adaptations

| OpenShift Feature | Problem | Solution |
|-------------------|---------|----------|
| OLM (Subscription, OperatorGroup) | Not available on vanilla K8s | Use Helm + helmfile |
| `olm.targetNamespaces` annotation | Dynamic namespace injection | olm-extractor `--watch-namespace=""` |
| Infrastructure API | Operator requires this CRD | Stub CRD + minimal CR |
| Global pull secret | Node-level registry auth | Pre-create SAs with `imagePullSecrets` |
| Console Plugin | OpenShift console integration | Excluded via olm-extractor |
| Routes | OpenShift routing | Excluded (use Ingress if needed) |
| SecurityContextConstraints | OpenShift SCC | Excluded (use PodSecurityStandards) |

## olm-extractor Integration

The `scripts/update-bundle.sh` uses [olm-extractor](https://github.com/lburgazzoli/olm-extractor) to extract manifests from Red Hat's OLM bundle:

```bash
podman run --rm \
  quay.io/lburgazzoli/olm-extractor:main \
  run "$BUNDLE_IMAGE" \
  -n cert-manager-operator \
  --watch-namespace="" \
  --exclude '.kind == "ConsoleCLIDownload"' \
  --exclude '.kind == "ConsolePlugin"' \
  --exclude '.kind == "Route"' \
  --exclude '.kind == "SecurityContextConstraints"' \
  --exclude '.kind == "ConsoleYAMLSample"'
```

Key flags:
- `--watch-namespace=""` - Replaces OLM's `olm.targetNamespaces` with empty value (cluster-wide)
- `--exclude` - Removes OpenShift-specific resources

## ServiceAccount imagePullSecrets

On OpenShift, the global pull secret is distributed to nodes via Machine Config Operator. On vanilla Kubernetes (AKS, GKE, EKS), this doesn't exist.

**Solution**: Pre-create the cert-manager ServiceAccounts with `imagePullSecrets` before the operator starts:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager
  namespace: cert-manager
imagePullSecrets:
  - name: redhat-pull-secret
```

The operator uses **strategic merge patch** when reconciling, so it:
1. Adds its labels (`app.kubernetes.io/*`)
2. Preserves existing `imagePullSecrets`

## File Structure

```
cert-manager-operator-chart/
├── Chart.yaml                             # Helm chart metadata
├── values.yaml                            # Default values
├── helmfile.yaml.gotmpl                   # Helmfile for deployment
├── environments/
│   └── default.yaml                       # Environment config
├── manifests-crds/                        # CRDs (applied with --server-side)
│   ├── customresourcedefinition-*.yaml    # cert-manager CRDs
│   └── customresourcedefinition-infrastructures-*.yaml  # Stub CRD
├── templates/
│   ├── deployment-*.yaml                  # Operator deployment
│   ├── serviceaccount-*.yaml              # Operator SA
│   ├── serviceaccounts-cert-manager.yaml  # Operand SAs with imagePullSecrets
│   ├── pull-secret.yaml                   # Registry pull secrets
│   ├── *role*.yaml                        # RBAC
│   └── service-*.yaml                     # Metrics service
└── scripts/
    ├── update-bundle.sh                   # Extract new bundle version
    ├── update-pull-secret.sh              # Update expired pull secret
    ├── cleanup.sh                         # Uninstall and delete CRDs
    └── post-install-message.sh            # Post-install hook
```

## Upgrade Process

```bash
# Update to new bundle version
./scripts/update-bundle.sh v1.18.0

# Review changes
git diff

# Deploy
helmfile apply
```

The update script:
1. Extracts manifests from Red Hat's OLM bundle
2. Applies olm-extractor transformations
3. Templatizes namespace references
4. Preserves custom templates (pull-secret, serviceaccounts-cert-manager)
