# RHCL Troubleshooting Guide

## Decision Tree

```
Problem?
  │
  ├── Operators not starting ──────────────→ Section 1
  ├── Kuadrant CR not Ready ───────────────→ Section 2
  ├── Authorino/Limitador not created ─────→ Section 3
  ├── ImagePullBackOff ────────────────────→ Section 4
  ├── RBAC / permission errors ────────────→ Section 5
  ├── Policies not enforced ───────────────→ Section 6
  ├── Rate limiting not working ───────────→ Section 7
  ├── TLS / certificates not working ──────→ Section 8
  ├── Uninstall stuck / finalizers ────────→ Section 9
  └── CRD conflicts ──────────────────────→ Section 10
```

---

## 1. Operators Not Starting

### Symptoms
- Pods in `kuadrant-operators` are `Pending`, `CrashLoopBackOff`, or `ImagePullBackOff`
- `make validate` shows operator deployments not ready

### Diagnostic Commands

```bash
# Pod status
kubectl get pods -n kuadrant-operators

# Events
kubectl get events -n kuadrant-operators --sort-by='.lastTimestamp' | tail -20

# Describe failing pod
kubectl describe pod -l app.kubernetes.io/component=kuadrant-operator -n kuadrant-operators

# Operator logs
kubectl logs -l app.kubernetes.io/component=kuadrant-operator -n kuadrant-operators --tail=50
```

### Common Causes

| Cause | Solution |
|-------|----------|
| **ImagePullBackOff** | See Section 4 |
| **Pending (no nodes)** | Check node affinity — GPU-only clusters will reject pods with `sku NotIn gpu` affinity. Remove affinity or add non-GPU nodes. |
| **CrashLoopBackOff** | Check logs for RBAC errors (Section 5) or missing CRDs |
| **Insufficient resources** | Lower `resources.requests` in values.yaml or use `examples/values-development.yaml` |

---

## 2. Kuadrant CR Not Ready

### Symptoms
- `kubectl get kuadrant -n kuadrant-system` shows status != Ready
- `make validate` fails on Kuadrant instance check

### Diagnostic Commands

```bash
# Full status
kubectl describe kuadrant kuadrant -n kuadrant-system

# Check conditions
kubectl get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions}' | jq .

# Kuadrant operator logs
kubectl logs -l app.kubernetes.io/component=kuadrant-operator -n kuadrant-operators --tail=100
```

### Common Causes

| Cause | Solution |
|-------|----------|
| **Authorino operator not ready** | Wait longer — Kuadrant CR depends on sub-operators being available |
| **Limitador operator not ready** | Same — check `kubectl get deployment -n kuadrant-operators` |
| **Missing CRDs** | Run `make validate` to check CRD list. Run `make copy-crds && make install` to reinstall |
| **RBAC errors in operator logs** | See Section 5 |

---

## 3. Authorino/Limitador Not Created

### Symptoms
- `kubectl get authorino -n kuadrant-system` returns nothing
- `kubectl get limitador -n kuadrant-system` returns nothing

### Root Cause

The Kuadrant operator creates Authorino and Limitador CRs. If they don't appear:

1. Check Kuadrant CR exists: `kubectl get kuadrant -n kuadrant-system`
2. Check Kuadrant operator logs for errors
3. Verify Authorino/Limitador operator deployments are running

---

## 4. ImagePullBackOff

### Symptoms
- Pods stuck in `ImagePullBackOff` or `ErrImagePull`

### Diagnostic Commands

```bash
# Check events for pull errors
kubectl get events -n kuadrant-operators | grep -i pull

# Check pull secret exists
kubectl get secret redhat-pull-secret -n kuadrant-operators
kubectl get secret redhat-pull-secret -n kuadrant-system

# Check wasm-plugin-pull-secret in gateway namespace
kubectl get secret wasm-plugin-pull-secret -n ingress-gateway

# Verify auth.json
cat ~/.config/containers/auth.json | jq '.auths | keys'
```

### Solutions

| Issue | Fix |
|-------|-----|
| **No pull secret** | Ensure `~/.config/containers/auth.json` exists with `registry.redhat.io` entry. Re-run `make install`. |
| **Pull secret in wrong namespace** | Add namespace to `gatewayNamespaces` in values.yaml and re-deploy |
| **Expired credentials** | Download fresh pull secret from [Red Hat Hybrid Cloud Console](https://console.redhat.com/openshift/downloads#tool-pull-secret) |
| **ServiceAccount missing imagePullSecrets** | Check SA: `kubectl get sa kuadrant-operator-controller-manager -n kuadrant-operators -o yaml` |

---

## 5. RBAC / Permission Errors

### Symptoms
- Operator logs show `forbidden` or `cannot create/update/delete` errors
- Kuadrant CR stays in error state

### Diagnostic Commands

```bash
# Check ClusterRoles exist
kubectl get clusterrole | grep -E 'kuadrant|authorino|limitador'

# Check ClusterRoleBindings
kubectl get clusterrolebinding | grep -E 'kuadrant|authorino|limitador'

# Test permissions for a specific SA
kubectl auth can-i create authpolicies.kuadrant.io \
  --as=system:serviceaccount:kuadrant-operators:kuadrant-operator-controller-manager
```

### Solutions

| Issue | Fix |
|-------|-----|
| **ClusterRole missing** | Check `rbac.create: true` in values.yaml. Re-deploy with `make install`. |
| **ClusterRoleBinding missing** | Same — verify the binding references the correct namespace |
| **Authorino component RBAC missing** | The `authorino-manager-role` ClusterRole must exist before Authorino operator creates the binding. Check `kubectl get clusterrole authorino-manager-role`. |

---

## 6. Policies Not Enforced

### Symptoms
- AuthPolicy or RateLimitPolicy shows status != Enforced
- Requests bypass auth or rate limiting

### Diagnostic Commands

```bash
# Check policy status
kubectl get authpolicy -A
kubectl get ratelimitpolicy -A

# Check WasmPlugin in gateway namespace
kubectl get wasmplugin -n ingress-gateway

# Check EnvoyFilters
kubectl get envoyfilter -n ingress-gateway

# Check AuthConfig
kubectl get authconfig -n kuadrant-system

# Kuadrant operator logs
kubectl logs -l app.kubernetes.io/component=kuadrant-operator -n kuadrant-operators --tail=100 | grep -i error
```

### Common Causes

| Cause | Solution |
|-------|----------|
| **WasmPlugin not created** | Check `wasm-plugin-pull-secret` exists in gateway namespace. Add namespace to `gatewayNamespaces`. |
| **Gateway not found** | Verify Gateway exists and is programmed: `kubectl get gateway -A` |
| **HTTPRoute not attached** | Check HTTPRoute parentRefs match the Gateway name/namespace |
| **AuthConfig not created** | Check Kuadrant operator logs for reconciliation errors |

---

## 7. Rate Limiting Not Working

### Symptoms
- Requests never get 429 responses
- RateLimitPolicy shows Enforced but limits don't apply

### Diagnostic Commands

```bash
# Check Limitador CR limits
kubectl get limitador limitador -n kuadrant-system -o yaml | grep -A 20 'limits:'

# Check Limitador pod logs
kubectl logs -l limitador-resource=limitador -n kuadrant-system --tail=50

# Check limitador config
kubectl get configmap limitador-limits-config-limitador -n kuadrant-system -o yaml
```

### Common Causes

| Cause | Solution |
|-------|----------|
| **In-memory storage reset** | Limitador lost counters after pod restart. Expected behavior without Redis. |
| **Limitador not reachable** | Check service: `kubectl get svc limitador-limitador -n kuadrant-system` |
| **EnvoyFilter not applied** | Check `kubectl get envoyfilter -n ingress-gateway \| grep ratelimit` |

---

## 8. TLS / Certificates Not Working

### Symptoms
- TLSPolicy not enforced
- Certificate not issued
- HTTPS not working on Gateway

### Diagnostic Commands

```bash
# Check cert-manager
kubectl get certificate -A
kubectl get certificaterequest -A
kubectl get clusterissuer

# Check TLS secret
kubectl get secret -n ingress-gateway | grep tls
```

### Common Causes

| Cause | Solution |
|-------|----------|
| **cert-manager not installed** | Run `make check` to verify prerequisites |
| **ClusterIssuer missing** | Create the ClusterIssuer (e.g., `selfsigned` or Let's Encrypt) |
| **Certificate not issued** | Check `kubectl describe certificate -n ingress-gateway` and `kubectl describe certificaterequest -n ingress-gateway` |

---

## 9. Uninstall Stuck / Finalizers

### Symptoms
- Namespaces stuck in `Terminating`
- CRs stuck in `Terminating`
- `helmfile destroy` hangs

### Manual Cleanup

```bash
# Strip finalizers from all RHCL CRs
for res in kuadrant authorino limitador authconfig; do
  kubectl get $res --all-namespaces -o name 2>/dev/null | while read -r cr; do
    kubectl patch "$cr" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  done
done

# Force-delete stuck namespace
kubectl get namespace kuadrant-system -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/kuadrant-system/finalize" -f -

# Delete CRDs manually
make clean-crds
```

---

## 10. CRD Conflicts

### Symptoms
- `helm install` fails with "CRD already exists"
- Server-Side Apply conflicts

### Solutions

```bash
# Check existing CRDs
kubectl get crd | grep kuadrant

# If CRDs were installed by OLM (OpenShift), they conflict with Helm-managed CRDs
# Remove OLM-installed CRDs first, then re-deploy
kubectl delete crd authpolicies.kuadrant.io --ignore-not-found
# ... repeat for each conflicting CRD

# Or force Server-Side Apply
kubectl apply --server-side --force-conflicts -f charts/rhcl/crds/
```

---

## Useful Commands Quick Reference

```bash
# Overall status
make status

# Operator logs
make logs OPERATOR=kuadrant
make logs OPERATOR=authorino
make logs OPERATOR=limitador

# Full validation
make validate

# Pre-deploy checks
make check

# Events across RHCL namespaces
kubectl get events -n kuadrant-operators --sort-by='.lastTimestamp' | tail -10
kubectl get events -n kuadrant-system --sort-by='.lastTimestamp' | tail -10
```
