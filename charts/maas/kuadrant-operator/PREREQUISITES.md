# RHCL Operator - Prerequisites

## Critical Dependencies

The Kuadrant/RHCL operator has **STRICT prerequisite dependencies** that MUST be deployed in the correct order.

### Deployment Order

```text
1. Red Hat Authentication (podman login)
2. cert-manager (helmfile apply --selector name=cert-manager-operator)
3. Istio + Gateway API CRDs (helmfile apply --selector name=sail-operator)
4. RHCL Operator (helmfile apply --selector name=kuadrant-operator)
```

---

## Prerequisite #1: Red Hat Account

**Required:** Active Red Hat subscription with access to registry.redhat.io

```bash
podman login registry.redhat.io
# Username: <your-redhat-email>
# Password: <your-password>
```

**Verification:**
```bash
cat ~/.config/containers/auth.json | grep registry.redhat.io
```

**Why Required:**
- All RHCL images are in Red Hat registry (registry.redhat.io/rhcl-1)
- Without authentication, image pull will fail

---

## Prerequisite #2: cert-manager

**Required:** cert-manager v1.15+ must be deployed **BEFORE** Kuadrant operator

```bash
helmfile apply --selector name=cert-manager-operator

# Wait for cert-manager to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager \
 -n cert-manager --timeout=300s
```

**Why Required:**
1. Kuadrant operator uses `ValidatingWebhookConfiguration`
2. Webhook requires TLS certificates from cert-manager
3. Without cert-manager, operator pods will fail with webhook errors
4. TLSPolicy feature requires cert-manager integration

**What Gets Created:**
- `ValidatingWebhookConfiguration` (for policy validation)
- `MutatingWebhookConfiguration` (for policy defaulting)
- `Certificate` resources for webhook TLS

---

## Prerequisite #3: Gateway API CRDs

**Required:** Gateway API v1.4.0+ CRDs

**Recommended:** Deploy via sail-operator (automatically includes Gateway API CRDs)
```bash
helmfile apply --selector name=sail-operator
```

**Alternative:** Manual installation
```bash
kubectl apply -k https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.4.0
```

**Why Required:**
1. Kuadrant policies attach to Gateway API resources
2. `AuthPolicy` / `RateLimitPolicy` target: `Gateway`, `HTTPRoute`
3. `DNSPolicy` / `TLSPolicy` target: `Gateway`
4. Without Gateway API CRDs, policy resources cannot reference targets

**Critical CRDs:**
- `gateways.gateway.networking.k8s.io`
- `httproutes.gateway.networking.k8s.io`
- `gatewayclasses.gateway.networking.k8s.io`

---

## Prerequisite #4: Gateway Controller

**Required:** Istio or Envoy Gateway

**Recommended:** Istio via sail-operator
```bash
helmfile apply --selector name=sail-operator

# Wait for istiod to be ready
kubectl wait --for=condition=Ready pod -l app=istiod \
 -n istio-system --timeout=300s
```

**Verification:**
```bash
kubectl get gatewayclass istio
# OR
kubectl get gatewayclass envoy-gateway
```

**Why Required:**
1. Policies need an actual Gateway implementation to function
2. Gateway controller creates the ingress infrastructure
3. `AuthPolicy` / `RateLimitPolicy` are enforced by the Gateway
4. Without Gateway controller, policies have no effect

---

## Prerequisite #5: Kuadrant CRDs (Auto-Installed)

These CRDs are in `crds/` directory and installed automatically by Helm:

1. `kuadrants.kuadrant.io` - Main Kuadrant resource
2. `authpolicies.kuadrant.io` - API authentication policies
3. `ratelimitpolicies.kuadrant.io` - Rate limiting policies
4. `dnspolicies.kuadrant.io` - DNS management policies
5. `tlspolicies.kuadrant.io` - TLS certificate policies
6. `dnsrecords.kuadrant.io` - DNS records (managed by DNS operator)
7. `dnshealthcheckprobes.kuadrant.io` - DNS health checks
8. `authorinos.operator.authorino.kuadrant.io` - Authorino instances
9. `limitadors.limitador.kuadrant.io` - Limitador instances
10. `tokenratelimitpolicies.kuadrant.io` - Token rate limiting policies
11. `oidcpolicies.extensions.kuadrant.io` - OIDC authentication policies
12. `planpolicies.extensions.kuadrant.io` - Plan management policies
13. `telemetrypolicies.extensions.kuadrant.io` - Telemetry policies

**Note:** These are installed automatically during `helm install` with server-side apply.

---

## Automated Prerequisite Checks

The helmfile includes **presync hooks** that validate prerequisites before deployment:

### Hook 1: Gateway API CRDs Check
```bash
if ! kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
 echo "ERROR: Gateway API CRDs not found"
 exit 1
fi
```

### Hook 2: cert-manager Check
```bash
if ! kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
 echo "ERROR: cert-manager not found"
 exit 1
fi
```

### Hook 3: Gateway Controller Check
```bash
if kubectl get gatewayclass istio &>/dev/null; then
 echo "Gateway controller found: Istio"
elif kubectl get gatewayclass envoy-gateway &>/dev/null; then
 echo "Gateway controller found: Envoy Gateway"
else
 echo "ERROR: No Gateway controller found"
 exit 1
fi
```

---

## Complete Deployment Sequence

```bash
# Step 1: Authenticate with Red Hat registry
podman login registry.redhat.io

# Step 2: Deploy cert-manager
helmfile apply --selector name=cert-manager-operator
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager \
 -n cert-manager --timeout=300s

# Step 3: Deploy Istio (includes Gateway API CRDs)
helmfile apply --selector name=sail-operator
kubectl wait --for=condition=Ready pod -l app=istiod \
 -n istio-system --timeout=300s

# Step 4: Deploy RHCL Operator
helmfile apply --selector name=kuadrant-operator \
 --state-values-set useSystemPodmanAuth=true

# Step 5: Wait for Kuadrant to be ready
kubectl wait --for=condition=Ready kuadrant/kuadrant \
 -n kuadrant-system --timeout=300s
```

**OR** deploy all at once (if you trust the prerequisites):
```bash
make deploy-all
```

---

## Verification Checklist

Before deploying RHCL, verify:

- [ ] **Red Hat registry authentication configured**
 ```bash
 cat ~/.config/containers/auth.json | grep registry.redhat.io
 ```

- [ ] **cert-manager deployed and running**
 ```bash
 kubectl get deployment cert-manager -n cert-manager
 ```

- [ ] **Gateway API CRDs installed**
 ```bash
 kubectl get crd gateways.gateway.networking.k8s.io
 ```

- [ ] **Gateway controller deployed**
 ```bash
 kubectl get gatewayclass istio
 ```

- [ ] **All 13 Kuadrant CRDs present**
 ```bash
 ls -1 charts/maas/kuadrant-operator/crds/*.yaml | wc -l
 # Should output: 13
 ```

---

## Common Deployment Failures

### Error: ImagePullBackOff
```text
Failed to pull image "registry.redhat.io/rhcl-1/..."
Error: unauthorized: authentication required
```
**Cause:** Missing Red Hat registry authentication
**Fix:** `podman login registry.redhat.io`

---

### Error: Operator CrashLoopBackOff
```text
Error: webhook certificate not found
```
**Cause:** cert-manager not deployed or not ready
**Fix:** `helmfile apply --selector name=cert-manager-operator`

---

### Error: Policies Not Applying
```text
Status: TargetNotFound
```
**Cause:** Gateway API CRDs missing or Gateway resource doesn't exist
**Fix:** Deploy sail-operator and create Gateway resource

---

### Error: Policies Not Enforced
```text
Policy accepted but traffic not authenticated/rate-limited
```
**Cause:** No Gateway controller running (Istio/Envoy Gateway not deployed)
**Fix:** `helmfile apply --selector name=sail-operator`

---

### Error: No Matches for Kind Kuadrant
```text
Error: no matches for kind "Kuadrant" in version "kuadrant.io/v1beta1"
```
**Cause:** Kuadrant CRDs not installed (crds/ directory empty or missing)
**Fix:** Ensure `crds/` directory contains all 13 CRD YAML files

---

## After Deployment

Verify RHCL is running:

```bash
# Check all pods
kubectl get pods -n kuadrant-system

# Expected pods:
# kuadrant-operator-controller-manager-xxxxx  1/1 Running
# authorino-operator-xxxxx           1/1 Running
# limitador-operator-xxxxx           1/1 Running
# dns-operator-xxxxx              1/1 Running
# authorino-xxxxx                1/1 Running
# limitador-limitador-xxxxx           1/1 Running

# Check Kuadrant CR
kubectl get kuadrant -n kuadrant-system
# NAME    READY  AGE
# kuadrant  True  5m

# Check CRDs
kubectl get crd | grep kuadrant
```
