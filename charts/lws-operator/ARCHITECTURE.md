# LWS Operator Helm Chart - Architecture

Deploy Red Hat Leader Worker Set (LWS) Operator on vanilla Kubernetes (AKS, EKS, GKE) without OLM.

## Source Repositories

| Repo | Purpose |
|------|---------|
| [kubernetes-sigs/lws](https://github.com/kubernetes-sigs/lws) | Upstream LWS project |
| [lburgazzoli/olm-extractor](https://github.com/lburgazzoli/olm-extractor) | Extract OLM bundles for non-OLM clusters |

**OLM Bundle:** `registry.redhat.io/leader-worker-set/lws-operator-bundle`
- [Red Hat Catalog](https://catalog.redhat.com/en/software/containers/leader-worker-set/lws-operator-bundle/67ff5cf98d6d1a868448873b)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Helm Chart                                │
├─────────────────────────────────────────────────────────────────┤
│  Presync (helmfile)                                             │
│  └── openshift-lws-operator namespace                           │
├─────────────────────────────────────────────────────────────────┤
│  Helm Install (with Server-Side Apply)                          │
│  ├── LeaderWorkerSetOperator CRD from crds/ (Helm SSA, 3.17+)  │
│  ├── Pull secret (redhat-pull-secret)                           │
│  ├── LWS Operator ServiceAccount with imagePullSecrets          │
│  ├── LWS Operator deployment + RBAC                             │
│  └── RoleBinding in kube-system (for API server auth)           │
├─────────────────────────────────────────────────────────────────┤
│  Postsync (helmfile)                                            │
│  └── LeaderWorkerSetOperator CR (cluster)                       │
├─────────────────────────────────────────────────────────────────┤
│  Operator (post-install)                                        │
│  └── Deploys LeaderWorkerSet components                         │
│      ├── LeaderWorkerSet CRD                                    │
│      ├── Webhooks (validating/mutating)                         │
│      └── Operand deployment                                     │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Namespace
- `openshift-lws-operator` - Operator and operand namespace

### Images (registry.redhat.io)

| Component | Image |
|-----------|-------|
| LWS Operator | `registry.redhat.io/leader-worker-set/lws-rhel9-operator` |
| LWS Operand | `registry.redhat.io/leader-worker-set/lws-rhel9` |

### CRDs

**Operator CRD:**
- `leaderworkersetoperators.operator.openshift.io` - Operator CR

**Operand CRD (created by operator):**
- `leaderworkersets.leaderworkerset.x-k8s.io` - LeaderWorkerSet workloads

## LeaderWorkerSet Concept

```
┌─────────────────────────────────────────┐
│           LeaderWorkerSet               │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ Replica Group 0                  │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐│   │
│  │  │ Leader │ │ Worker │ │ Worker ││   │
│  │  │  Pod   │ │  Pod   │ │  Pod   ││   │
│  │  └────────┘ └────────┘ └────────┘│   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ Replica Group 1                  │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐│   │
│  │  │ Leader │ │ Worker │ │ Worker ││   │
│  │  │  Pod   │ │  Pod   │ │  Pod   ││   │
│  │  └────────┘ └────────┘ └────────┘│   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

**Use Cases:**
- Multi-host LLM inference (model sharding)
- Distributed training workloads
- Gang scheduling requirements
- Leader-election based workloads

## Non-OpenShift Adaptations

| OpenShift Feature | Problem | Solution |
|-------------------|---------|----------|
| OLM (Subscription, OperatorGroup) | Not available on vanilla K8s | Use Helm + helmfile |
| Global pull secret | Node-level registry auth | ServiceAccount with `imagePullSecrets` |
| API server auth config | Operator can't read `extension-apiserver-authentication` configmap | RoleBinding in `kube-system` to `extension-apiserver-authentication-reader` Role |

## olm-extractor Integration

The `scripts/update-bundle.sh` uses [olm-extractor](https://github.com/lburgazzoli/olm-extractor) to extract manifests from Red Hat's OLM bundle:

```bash
# Pull bundle image
podman pull registry.redhat.io/leader-worker-set/lws-operator-bundle:1.0

# Extract contents
podman cp <container>:/manifests /tmp/bundle/
podman cp <container>:/metadata /tmp/bundle/

# Process with olm-extractor
podman run --rm -v /tmp/bundle:/bundle:z \
  quay.io/lburgazzoli/olm-extractor:main run \
  -n openshift-lws-operator \
  /bundle
```

## ServiceAccount imagePullSecrets

The operator ServiceAccount is pre-configured with `imagePullSecrets`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openshift-lws-operator
  namespace: openshift-lws-operator
imagePullSecrets:
  - name: redhat-pull-secret
```

## File Structure

```
charts/lws-operator/
├── Chart.yaml                             # Helm chart metadata
├── values.yaml                            # Default values
├── helmfile.yaml.gotmpl                   # Helmfile for deployment
├── .helmignore
├── environments/
│   └── default.yaml                       # Environment config
├── crds/
│   └── customresourcedefinition-*.yaml    # LeaderWorkerSetOperator CRD (installed by Helm with SSA)
├── templates/
│   ├── deployment-*.yaml                  # Operator deployment
│   ├── serviceaccount-*.yaml              # Operator SA with imagePullSecrets
│   ├── pull-secret.yaml                   # Registry pull secret
│   └── *role*.yaml                        # RBAC
└── scripts/
    ├── update-bundle.sh                   # Extract new bundle version
    ├── update-pull-secret.sh              # Update expired pull secret
    ├── cleanup.sh                         # Uninstall
    └── post-install-message.sh            # Post-install instructions
```

## Upgrade Process

```bash
# (Optional) Update to a new bundle version
./scripts/update-bundle.sh <version>

# Deploy
make deploy
```
