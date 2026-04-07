# RHCL Test Suite

## Prerequisites

- RHCL operators deployed and running (`make install` from `charts/rhcl/`)
- Istio / Service Mesh installed and healthy
- Gateway API CRDs installed
- cert-manager installed (for TLSPolicy tests)
- `kubectl` configured and connected to the cluster

## Running Tests

### From the chart directory

```bash
cd charts/rhcl/

# Run integration test (Gateway + AuthPolicy + RateLimitPolicy)
make test

# Run DNS operator test (requires operators.dns.enabled=true)
make test-dns

# Run post-deploy validation (operators, instances, CRDs, RBAC)
make validate
```

### Directly

```bash
# Integration test
bash test/conformance/verify-rhcl-deployment.sh

# DNS operator test
bash test/conformance/verify-rhcl-dns.sh
```

## Test Descriptions

### Integration Test (`verify-rhcl-deployment.sh`)

Deploys a complete RHCL stack exercise:

1. Creates `rhcl-test` and `rhcl-test-gateway` namespaces
2. Deploys an echo-server workload
3. Creates an Istio Gateway (HTTP on port 80)
4. Creates an HTTPRoute pointing to the echo server
5. Creates an API key Secret in `kuadrant-system`
6. Creates an AuthPolicy (API key auth on the HTTPRoute)
7. Creates a RateLimitPolicy (5 req/10s on the Gateway)
8. Validates:
   - Echo server is running
   - Gateway is programmed and has an address
   - Policies are enforced
   - Unauthenticated requests are rejected (401/403)
   - Authenticated requests succeed (200)
   - Rate limiting triggers (429 after threshold)
   - AuthConfig CR is created by Kuadrant
   - WasmPlugin is injected into gateway namespace
9. Cleans up all test resources on exit (including on failure)

**Test resources**: `test/test-rhcl-deployment.yaml`

### DNS Operator Test (`verify-rhcl-dns.sh`)

Validates the DNS operator installation without requiring cloud DNS credentials:

1. Checks DNS operator deployment is running
2. Validates DNS CRDs are installed (dnspolicies, dnsrecords, dnshealthcheckprobes)
3. Creates a test DNSPolicy and DNSRecord
4. Verifies CRs are created and the operator reconciles them
5. Cleans up test resources

**Prerequisite**: Deploy RHCL with `--set operators.dns.enabled=true`

**Test resources**: `test/test-dns-operator.yaml`

### Post-Deploy Validation (`validate.sh`)

Comprehensive health check of the entire RHCL deployment:

- Operator deployments (3 required + 1 optional DNS)
- Kuadrant instance (Ready condition)
- Authorino instance (deployment + 3 services)
- Limitador instance (Ready condition + service)
- All 14 CRDs installed
- All 6 expected ClusterRoles present

Color-coded output: GREEN = pass, RED = fail, YELLOW = warning.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPERATOR_NAMESPACE` | `kuadrant-operators` | Namespace where operators run |
| `INSTANCE_NAMESPACE` | `kuadrant-system` | Namespace where Kuadrant instance runs |
| `TIMEOUT` | `300` | Timeout in seconds for wait operations |

## Troubleshooting

- **Gateway has no address**: Check that Istio is installed and the `istio` GatewayClass exists
- **AuthPolicy not enforced**: Check Authorino logs (`make logs OPERATOR=authorino`) and ensure the API key secret has the label `authorino.kuadrant.io/managed-by: authorino`
- **Rate limiting not working**: Check Limitador logs and ensure the WasmPlugin exists in the gateway namespace
- **Connection refused on HTTP requests**: The Gateway LoadBalancer may take 1-2 minutes to get an external IP on cloud providers
