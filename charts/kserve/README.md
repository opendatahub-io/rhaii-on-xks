# KServe xKS Helm Chart

Helm chart for deploying KServe on xKS for Red Hat AI Inference.

## Overview

This chart is auto-generated from the [KServe](https://github.com/red-hat-data-services/kserve) Kustomize overlays with
RHOAI image replacements. All container images are sourced from `registry.redhat.io`.

## Prerequisites

* Install cert-manager in the `cert-manager` namespace (if not already installed)

### cert-manager PKI Setup

This chart requires cert-manager to be installed and a PKI chain to be configured. The chart expects
a `ClusterIssuer` named `opendatahub-ca-issuer` to issue webhook certificates.

Set up the PKI chain by applying the following resources:

```yaml
# This is the root ClusterIssuer to bootstrap the OpenDataHub CA.
# It can be replaced with a different ClusterIssuer (e.g., Vault)
# for production deployments.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: opendatahub-selfsigned-issuer
spec:
  selfSigned: { }
---
# This is the ClusterIssuer that OpenDataHub components should use to issue certificates.
# It uses the CA certificate created by ca-certificate.yaml.
# Being cluster-scoped, any namespace can request certificates from this issuer.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: opendatahub-ca-issuer # must be `opendatahub-ca-issuer`
spec:
  ca:
    secretName: opendatahub-ca
---
# This is the OpenDataHub CA certificate.
# It is issued by the selfsigned ClusterIssuer and used to sign workload certificates.
# The secret created (opendatahub-ca) contains tls.crt and tls.key.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: opendatahub-ca
  namespace: cert-manager
spec:
  secretName: opendatahub-ca # must be `opendatahub-ca`
  isCA: true
  commonName: opendatahub-ca
  duration: 87600h  # 10 years
  renewBefore: 2160h  # 90 days
  privateKey:
    algorithm: RSA
    size: 4096
  issuerRef:
    name: opendatahub-selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

This creates:

1. **opendatahub-selfsigned-issuer** (ClusterIssuer) - Bootstrap issuer for the CA
2. **opendatahub-ca** (Certificate in cert-manager namespace) - The CA certificate
3. **opendatahub-ca-issuer** (ClusterIssuer) - Issuer for workload certificates

For production deployments, replace the self-signed issuer with a proper CA (e.g., Vault, external PKI).

## Installation

### From OCI Registry

```bash
# Production version (e.g., 3.4.0-ea.1+abc1234)
helm install rhaii-xks-kserve oci://ghcr.io/<owner>/kserve-rhaii-xks:<version> \
  --namespace opendatahub \
  --create-namespace
```

Or use a development version (uses midstream kserve images):

```bash
# Dev version (e.g., 3.4.0-ea.1-dev+abc1234)
helm install rhaii-xks-kserve oci://ghcr.io/<owner>/kserve-rhaii-xks:<version>-dev+<sha> \
  --namespace opendatahub \
  --create-namespace
```

### From Local Clone

```bash
git clone https://github.com/<owner>/xks-kserve-chart.git
helm install kserve-xks ./xks-kserve-chart --namespace opendatahub --create-namespace
```

## Chart Generation

The chart resources are generated from Kustomize overlays using the `generate-chart.sh` script.

### Usage

```bash
./generate-chart.sh --overlay <path-to-kserve>/config/overlays/odh-xks [OPTIONS]
```

### Options

| Option            | Default      | Description                                  |
|-------------------|--------------|----------------------------------------------|
| `--overlay PATH`  | (required)   | Path to Kustomize overlay                    |
| `--tag TAG`       | `3.4.0-ea.1` | Image tag for quay.io replacements           |
| `--branch BRANCH` | `rhoai-3.4`  | RHOAI-Build-Config branch for image mappings |

### Example

```bash
./generate-chart.sh \
  --overlay ~/kserve/config/overlays/odh-xks \
  --branch rhoai-3.4 \
  --tag 3.4.0-ea.1
```

### Image Replacement Logic

1. **quay.io images** are replaced with `registry.redhat.io` equivalents using the specified tag
2. **registry.redhat.io images** are replaced with exact SHA references from the RHOAI-Build-Config
   ClusterServiceVersion

## CI/CD Workflows

### Update Chart (every 2 hours)

Automatically regenerates the chart from upstream KServe and creates a PR if changes are detected.

**Inputs:**

- `kserve_repo`: KServe repository (default: `red-hat-data-services/kserve`)
- `kserve_ref`: KServe branch/tag (default: `rhoai-3.4`)
- `rhoai_branch`: RHOAI-Build-Config branch (default: `rhoai-3.4`)
- `image_tag`: Image tag for quay.io replacements (default: `3.4.0-ea.1`)

### Release (on push to main)

Packages and releases the Helm chart:

- Creates GitHub release with `.tgz` artifact
- Pushes to OCI registry (`ghcr.io`)
- Version format: `{base_version}+{short_sha}`

### CI (on PR)

Validates the chart:

- Helm lint
- Template rendering
- Verifies all images are from `registry.redhat.io`

## Chart Structure

```
.
├── Chart.yaml              # Chart metadata
├── values.yaml             # (empty - static chart)
├── generate-chart.sh       # Regeneration script
├── crds/                   # CRDs installed first by Helm
├── files/
│   ├── resources.yaml      # Pre-rendered Kustomize manifests
│   └── webhooks.yaml       # Webhook configurations (raw)
└── templates/
    ├── resources.yaml      # Includes files via .Files.Get
    └── webhooks.yaml       # Webhooks with Helm hook annotations
```

## Notes

- This chart contains pre-rendered manifests with embedded Go templates (e.g., `{{ .Name }}`) that are passed through to
  the cluster unchanged
- The chart is static by design - customization happens at the Kustomize layer or via post-render scripts
- All images are verified to be from `registry.redhat.io` during generation

## License

Apache License 2.0