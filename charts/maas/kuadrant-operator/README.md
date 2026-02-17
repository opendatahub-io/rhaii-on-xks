# Red Hat Connectivity Link (RHCL) Helm Chart

Red Hat Connectivity Link (RHCL) 1.3.1 for Kubernetes - API Gateway policy management

## Overview

This Helm chart deploys Red Hat Connectivity Link (RHCL) 1.3.1 and its component operators:

- **Authorino Operator 1.2.4** - API Authentication & Authorization
- **Limitador Operator 1.2.0** - Rate Limiting & Quotas
- **DNS Operator 1.2.0** - Multi-cluster DNS Management

## Components

| Component | Version | Image Registry |
|-----------|---------|----------------|
| RHCL Operator | 1.3.1 | registry.redhat.io/rhcl-1/rhcl-rhel9-operator |
| Authorino Operator | 1.2.4 | registry.redhat.io/rhcl-1/authorino-rhel9-operator |
| Authorino | 1.3.1 | registry.redhat.io/rhcl-1/authorino-rhel9 |
| Limitador Operator | 1.2.0 | registry.redhat.io/rhcl-1/limitador-rhel9-operator |
| Limitador | 2.1.0 | registry.redhat.io/rhcl-1/limitador-rhel9 |
| DNS Operator | 1.2.0 | registry.redhat.io/rhcl-1/dns-rhel9-operator |
| WASM Shim | 0.11.0 | registry.redhat.io/rhcl-1/wasm-shim-rhel9 |

## Prerequisites

### CRITICAL - Deploy in Order

RHCL has strict prerequisite dependencies that must be deployed in sequence:

**1. Red Hat Account** with access to registry.redhat.io
  ```bash
  podman login registry.redhat.io
  # Username: <your-redhat-email>
  # Password: <your-password>
  ```

**2. cert-manager** (v1.15+) - REQUIRED FIRST
  ```bash
  helmfile apply --selector name=cert-manager-operator
  ```

  Why: Kuadrant operator needs cert-manager for webhook certificates

**3. Gateway API CRDs** (v1.4.0+) - REQUIRED SECOND
  ```bash
  kubectl apply -k https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.4.0
  ```
  Or deployed automatically by sail-operator

**4. Gateway Controller** (Istio or Envoy Gateway) - REQUIRED THIRD
  ```bash
  helmfile apply --selector name=sail-operator
  ```

  Why: Kuadrant policies attach to Gateway/HTTPRoute resources managed by a Gateway controller

**5. Verify Prerequisites**
  ```bash
  # Check cert-manager
  kubectl get deployment cert-manager -n cert-manager

  # Check Gateway API CRDs
  kubectl get crd gateways.gateway.networking.k8s.io

  # Check Gateway controller
  kubectl get gatewayclass istio # or 'envoy-gateway'
  ```

### What Gets Installed

The chart includes 13 CRDs in `crds/` directory:
- `kuadrants.kuadrant.io` - Main Kuadrant resource
- `authpolicies.kuadrant.io` - API authentication policies
- `ratelimitpolicies.kuadrant.io` - Rate limiting policies
- `dnspolicies.kuadrant.io` - DNS management policies
- `tlspolicies.kuadrant.io` - TLS certificate policies
- `dnsrecords.kuadrant.io` - DNS records managed by DNS operator
- `dnshealthcheckprobes.kuadrant.io` - DNS health checks
- `authorinos.operator.authorino.kuadrant.io` - Authorino instances
- `limitadors.limitador.kuadrant.io` - Limitador instances
- `tokenratelimitpolicies.kuadrant.io` - Token rate limiting policies
- `oidcpolicies.extensions.kuadrant.io` - OIDC authentication policies
- `planpolicies.extensions.kuadrant.io` - Plan management policies
- `telemetrypolicies.extensions.kuadrant.io` - Telemetry policies

These CRDs are installed automatically by Helm using server-side apply.

## Installation

### Via Helmfile (Recommended)

From rhaii-on-xks root directory:

```bash
helmfile apply --selector name=kuadrant-operator \
 --state-values-set useSystemPodmanAuth=true
```

### Direct Helm Install

```bash
# Create namespace
kubectl create namespace kuadrant-system

# Create pull secret
kubectl create secret docker-registry redhat-pull-secret \
 --docker-server=registry.redhat.io \
 --docker-username=<your-redhat-email> \
 --docker-password=<your-password> \
 --namespace=kuadrant-system

# Install chart
helm install kuadrant-operator ./charts/maas/kuadrant-operator \
 --namespace kuadrant-system
```

## Verification

```bash
# Check pods
kubectl get pods -n kuadrant-system

# Check Kuadrant CR
kubectl get kuadrant -n kuadrant-system

# Check policy CRDs
kubectl get crd | grep kuadrant
```

Expected output:
```text
NAME                        READY  STATUS
kuadrant-operator-controller-manager-xxxxx     1/1   Running
authorino-operator-xxxxx              1/1   Running
limitador-operator-xxxxx              1/1   Running
dns-operator-xxxxx                 1/1   Running
```

## Usage

### AuthPolicy Example

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
 name: my-api-auth
 namespace: default
spec:
 targetRef:
  group: gateway.networking.k8s.io
  kind: HTTPRoute
  name: my-api-route
 rules:
  authentication:
   "api-key":
    apiKey:
     selector:
      matchLabels:
       app: my-api
```

### RateLimitPolicy Example

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
 name: my-api-ratelimit
 namespace: default
spec:
 targetRef:
  group: gateway.networking.k8s.io
  kind: HTTPRoute
  name: my-api-route
 limits:
  "global-limit":
    rates:
    - limit: 1000
      window: 60s
```

## Configuration

See `values.yaml` for all configuration options.

Key values:

```yaml
operator:
 image:
  registry: registry.redhat.io
  repository: rhcl-1/rhcl-rhel9-operator
  tag: "1.3.1"

components:
 authorino:
  enabled: true
 limitador:
  enabled: true
 dns:
  enabled: true
```

## Support

- Documentation: https://access.redhat.com/documentation/en-us/red_hat_connectivity_link/
- Red Hat Support: https://access.redhat.com/support
