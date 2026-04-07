# RHCL Helmfile Design

> APPENG-4671: Design Helm Chart Architecture
> Describes the three-phase helmfile orchestration for RHCL deployment.

---

## Why Helmfile?

Standard `helm install` can't handle the RHCL deployment because:

1. **Namespaces must exist before Helm deploys into them** — Helm's `createNamespace` only creates the release namespace, not additional namespaces like `kuadrant-system`.

2. **ServiceAccounts need imagePullSecrets before pods start** — if SAs are created by Helm templates at the same time as Deployments, there's a race condition where pods start before SAs have pull secrets.

3. **The Kuadrant CR must be created AFTER operators are running** — if created simultaneously with operator Deployments, the CR has nothing to reconcile it.

4. **CRD deletion requires manual handling** — Helm deliberately does not delete CRDs on `helm uninstall` to prevent data loss.

Helmfile wraps `helm install` with **hooks** that run before and after, solving all four problems.

---

## Three-Phase Install

```
┌─────────────────────────────────────────────────────────┐
│                    helmfile apply                        │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   PRESYNC    │→ │ HELM INSTALL │→ │   POSTSYNC   │  │
│  │              │  │              │  │              │  │
│  │ Namespaces   │  │ CRDs (SSA)   │  │ Wait for     │  │
│  │ ServiceAccts │  │ Deployments  │  │ operators    │  │
│  │              │  │ RBAC         │  │              │  │
│  │              │  │ Pull secrets │  │ Create       │  │
│  │              │  │              │  │ Kuadrant CR  │  │
│  │              │  │              │  │              │  │
│  │              │  │              │  │ Patch SAs    │  │
│  │              │  │              │  │              │  │
│  │              │  │              │  │ Validate     │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Phase 1: PRESYNC

**Hooks**: 3 presync events in `helmfile.yaml.gotmpl`

| Step | Command | Purpose |
|------|---------|---------|
| 1 | `kubectl create namespace kuadrant-operators --dry-run=client -o yaml \| kubectl apply -f -` | Create operator namespace (idempotent) |
| 2 | `kubectl create namespace kuadrant-system --dry-run=client -o yaml \| kubectl apply -f -` | Create instance namespace (idempotent) |
| 3 | `kubectl apply --server-side --force-conflicts -f manifests-presync/` | Create 4 operator ServiceAccounts with imagePullSecrets |

**Why `--dry-run=client | apply`**: Makes namespace creation idempotent. If namespace exists, it's a no-op. If not, it creates it.

**Why `--server-side --force-conflicts`**: ServiceAccounts may already exist from a previous install. SSA with force-conflicts updates them cleanly.

### Phase 2: HELM INSTALL

Standard `helm install` / `helm upgrade --install` with these features:

| Feature | How |
|---------|-----|
| CRDs | Helm auto-applies all files in `crds/` via Server-Side Apply before rendering templates |
| Deployments | 4 operator Deployments from `templates/operators/` |
| RBAC | 7 ClusterRoles + 4 ClusterRoleBindings + 2 user-facing roles |
| Pull secrets | Secrets in operator NS, instance NS, and each gateway NS |
| ServiceAccount | `authorino-authorino` component SA with imagePullSecrets |
| ServiceMonitors | Optional (if `monitoring.enabled`) |

### Phase 3: POSTSYNC

**Hooks**: 5 postsync events in `helmfile.yaml.gotmpl`

| Step | Timeout | Purpose |
|------|---------|---------|
| 1 | 300s | `kubectl wait --for=condition=Available` on 3 required operator Deployments (+ DNS if enabled) |
| 2 | — | Create Kuadrant CR via `kubectl apply` (triggers sub-operator reconciliation) |
| 3 | 120s | Patch imagePullSecrets on `default` SA and Limitador CR in instance NS |
| 4 | 300s | `kubectl wait --for=condition=Ready` on Kuadrant CR |
| 5 | — | Verify Authorino and Limitador CRs exist |

**Error handling**: If Kuadrant CR doesn't become Ready within 300s, the hook runs `kubectl describe` to print the full CR status for debugging, then exits with code 1.

---

## Three-Phase Uninstall

```
┌─────────────────────────────────────────────────────────┐
│                   helmfile destroy                       │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ PREUNINSTALL │→ │HELM UNINSTALL│→ │POSTUNINSTALL │  │
│  │              │  │              │  │              │  │
│  │ Delete       │  │ Remove       │  │ Delete       │  │
│  │ Kuadrant CR  │  │ Deployments  │  │ namespaces   │  │
│  │              │  │ RBAC         │  │              │  │
│  │ Wait for     │  │ Secrets      │  │ Strip        │  │
│  │ sub-instance │  │ SAs          │  │ finalizers   │  │
│  │ deletion     │  │              │  │              │  │
│  │              │  │ (NOT CRDs)   │  │ Delete CRDs  │  │
│  │ Strip        │  │              │  │              │  │
│  │ finalizers   │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### PREUNINSTALL

Deletes the Kuadrant CR first because:
- Kuadrant CR owns Authorino CR + Limitador CR (via ownerReferences)
- Deleting it cascades to delete sub-instances
- Sub-instances own their Deployments/Services, so those get cleaned up automatically

Waits up to 60s for sub-instances to be deleted. If stuck, strips finalizers to force deletion.

### HELM UNINSTALL

Standard `helm uninstall`. Removes:
- Operator Deployments
- ClusterRoles and ClusterRoleBindings
- Pull Secrets
- ServiceAccounts (from templates)

Does NOT remove:
- CRDs (Helm never deletes CRDs by design)
- Namespaces (not Helm-managed)

### POSTUNINSTALL

Cleans up what Helm leaves behind:

1. **Delete namespaces**: `kuadrant-system`, `kuadrant-operators` (with polling wait)
2. **Strip orphaned finalizers**: Any remaining Kuadrant/Authorino/Limitador/AuthConfig/DNSRecord CRs
3. **Delete CRDs**: All CRDs matching `*.kuadrant.io`, `*.authorino.kuadrant.io`, `*.limitador.kuadrant.io`

---

## Auth Handling

The helmfile supports 4 methods for providing Red Hat registry credentials, checked in priority order:

```
┌────────────────────────────────────────────┐
│ useSystemPodmanAuth: true (default)        │
│   Reads: ~/.config/containers/auth.json    │
├────────────────────────────────────────────┤
│ images.pullSecret.dockerConfigJson         │
│   Inline value (for CI/CD pipelines)       │
├────────────────────────────────────────────┤
│ pullSecretFile: ~/path/to/pull-secret.txt  │
│   Reads file (validated under $HOME)       │
├────────────────────────────────────────────┤
│ authFile: ~/path/to/auth.json              │
│   Same as pullSecretFile (alias)           │
└────────────────────────────────────────────┘
```

### Security: Path Validation

For `pullSecretFile` and `authFile`, the helmfile validates:
1. `$HOME` environment variable is set
2. The resolved path (`realpath -e`) exists
3. The resolved path is under `$HOME` (prevents path traversal attacks like `/etc/shadow`)

---

## Timeout Configuration

| Operation | Timeout | Configurable? |
|-----------|---------|---------------|
| Operator readiness (Available condition) | 300s (5 min) | Hardcoded in helmfile |
| Kuadrant CR readiness (Ready condition) | 300s (5 min) | Hardcoded in helmfile |
| Limitador CR wait | 120s (2 min) | Hardcoded in helmfile |
| Helmfile overall | 600s (10 min) | `helmDefaults.timeout` in helmfile |
| Sub-instance deletion (preuninstall) | 60s (1 min) | Hardcoded in helmfile |
| Namespace deletion (postuninstall) | 60s (1 min) | Hardcoded in helmfile |
| CRD deletion | 30s per CRD | Hardcoded in helmfile |

---

## Idempotency

All helmfile operations are designed to be idempotent (safe to run multiple times):

| Operation | Idempotent? | How |
|-----------|-------------|-----|
| Presync namespace creation | Yes | `--dry-run=client \| kubectl apply` |
| Presync ServiceAccount creation | Yes | `--server-side --force-conflicts` |
| Helm install | Yes | `helmfile apply` uses `helm upgrade --install` |
| Postsync Kuadrant CR | Yes | `kubectl apply` (update if exists) |
| Postsync imagePullSecrets patch | Yes | `kubectl patch` (merge) |

This means you can safely run `make install` multiple times without breaking anything.
