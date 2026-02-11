# cert-manager Operator Tests

This directory contains integration tests for the cert-manager operator.

## Prerequisites

- Kubernetes cluster with cert-manager operator deployed
- `kubectl` configured to access the cluster
- `openssl` for certificate verification

## Running Tests

### Run all tests
```bash
make test
```

### Run individual tests

**Self-signed certificate test:**
```bash
make test-selfsigned
```
Tests basic certificate issuance using a self-signed issuer.

**CA issuer test:**
```bash
make test-ca
```
Tests CA certificate creation and certificate chain issuance.

## Test Descriptions

### Self-Signed Test (`selfsigned-test.yaml`)
- Creates a namespace `cert-manager-test`
- Creates a self-signed Issuer
- Requests a Certificate with DNS names and IP SANs
- Verifies the certificate is issued and contains correct CN

### CA Test (`ca-test.yaml`)
- Creates a namespace `cert-manager-test`
- Bootstraps a CA using a self-signed certificate
- Creates a CA Issuer from the CA certificate
- Issues a leaf certificate from the CA
- Verifies the certificate chain is valid

## Cleanup

```bash
make clean-tests
```

This removes the test namespace and all test resources.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TEST_NAMESPACE` | `cert-manager-test` | Namespace for test resources |
| `TIMEOUT` | `120` | Timeout in seconds for waiting |
