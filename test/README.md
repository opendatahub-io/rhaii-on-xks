# Sail Operator Tests

Tests to validate the Sail operator installation.

## Tests

- `run-operator-test.sh` - checks operator deployment, Istio CR, istiod, version
- `run-crd-test.sh` - verifies all required CRDs are installed
- `run-injection-test.sh` - tests sidecar injection works

## Usage

```bash
# run all tests
make test

# run individual tests
make test-operator
make test-crd
make test-injection
```

## What gets tested

### Operator test
1. servicemesh-operator3 deployment is running
2. Istio CR exists and is Healthy
3. istiod deployment is running
4. Istio version matches expected (optional: set EXPECTED_ISTIO_VERSION)

### CRD test

Checks these CRD groups are installed:

**Sail Operator CRDs:**
- istios.sailoperator.io
- istiorevisions.sailoperator.io
- istiocnis.sailoperator.io

**Istio API CRDs:**
- virtualservices.networking.istio.io
- destinationrules.networking.istio.io
- gateways.networking.istio.io
- serviceentries.networking.istio.io
- authorizationpolicies.security.istio.io
- peerauthentications.security.istio.io

**Gateway API CRDs:**
- gateways.gateway.networking.k8s.io
- httproutes.gateway.networking.k8s.io
- grpcroutes.gateway.networking.k8s.io

**Inference Extension CRDs (v1.2.0):**
- inferencepools.inference.networking.x-k8s.io

### Injection test
1. Creates test namespace with `istio-injection=enabled` label
2. Deploys nginx pod
3. Verifies istio-proxy sidecar is injected
4. Cleans up

## Troubleshooting

Operator not ready?
```bash
kubectl get pods -n istio-system
kubectl logs -n istio-system -l app.kubernetes.io/name=servicemesh-operator3
```

CRDs missing?
```bash
kubectl get crd | grep -E "istio|gateway|inference"
```

Injection not working?
```bash
kubectl get namespace <ns> --show-labels
kubectl get mutatingwebhookconfiguration | grep istio
```
