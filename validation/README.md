# LLM-D xKS Preflight Validation Checks

A CLI application for running validation checks against Kubernetes clusters in the context of Red Hat AI Inference Server (KServe LLMInferenceService) on managed Kubernetes platforms (AKS, GKE, CoreWeave, etc.). The tool connects to a running Kubernetes cluster, detects the cloud provider, and executes a series of validation tests to ensure the cluster is properly configured and ready for use.

## Features

- **Cloud Provider Detection**: Automatically detects cloud provider (Azure, GCP, AWS) or allows manual specification
- **Multi-Cloud Support**: Extensible architecture supports Azure AKS and Google Cloud GKE
- **TPU Support**: Validates Google Cloud TPU availability and zone compatibility (GKE)
- **Configurable Logging**: Adjustable log levels for debugging and monitoring
- **Flexible Configuration**: Supports command-line arguments, config files, and environment variables
- **Test Framework**: Extensible test execution framework for preflight validations
- **Test Reporting**: Detailed test results with suggested actions for failures

## Supported cloud Kubernetes Services

| Cloud provider | Managed K8s Service |
| -------------- | ------------------- |
| [Azure](https://azure.microsoft.com) | [AKS](https://azure.microsoft.com/en-us/products/kubernetes-service) |
| [Google Cloud](https://cloud.google.com) | [GKE](https://cloud.google.com/kubernetes-engine) |


## Container image build

This tool can be packaged and run as a container image and a Containerfile is provided, along with scripts to ease the build process.

In order to build a container locally:

```bash
make container
```

By default, the container is built on top of latest Fedora container image. If you have an **entitled Red Hat Enterprise Linux system**, you can use UBI9 (Universal Basic Image) as the base:

```bash
FROM=registry.access.redhat.com/ubi9:latest make container
```

Notes:
  * currently, only UBI version 9 (based on Red Hat Enterprise Linux 9) is supported
  * while the base image itself can be pulled without registration, the container image will not build without a valid Red Hat entitlement -- if you are running a registered RHEL system, the entitlement is automatically passed to the container at build time

Regardless of base image, the resulting container image repository (name) and tag can be customized by using `CONTAINER_REPO` and `CONTAINER_TAG` environment variables:

```bash
CONTAINER_REPO=quay.io/myusername/llm-d-xks-preflight CONTAINER_TAG=mytag make container
FROM=registry.access.redhat.com/ubi9:latest CONTAINER_REPO=quay.io/myusername/llm-d-xks-preflight CONTAINER_TAG=mytag make container
```

## Container image run

After building the container image as described above, a helper script to run the validations against a Kubernetes cluster is available:

```bash
# using defaults
make run
# if the image name and tag have been customized
CONTAINER_REPO=quay.io/myusername/llm-d-xks-preflight CONTAINER_TAG=mytag make run
```

If the path to the cluster credentials Kube config is not the standard `~/.kube/config`, the environment variable `HOST_KUBECONFIG` can be used to designate the correct path:

```bash
HOST_KUBECONFIG=/path/to/kube/config make run
```

## Validations

Suite: cluster -- Cluster readiness tests

| Test name | Meaning |
| --------- | ------- |
| `cloud_provider` | The validation script tries to determine the cloud provider the cluster is running on. Can be overridden with `--cloud-provider` |
| `instance_type` | At least one supported instance type must be present as a cluster node. See below for details. |
| `gpu_availability` | At least one supported GPU must be available on a cluster node. Availability is determined by driver presence and node labels |

Suite: operators -- Operator readiness tests

| Test name | Meaning |
| --------- | ------- |
| `crd_certmanager` | The tool checks if cert-manager CRDs are present on the cluster |
| `operator_certmanager` | Check if cert-manager deployments are ready |
| `crd_sailoperator` | The tool checks if sail-operator CRDs are present on the cluster |
| `operator_sail` | Check if sail-operator deployments are ready |
| `crd_lwsoperator`  | The tool checks if lws-operator CRDs are present on the cluster |
| `operator_lws`     | Check if lws-operator deployments are ready |
| `crd_kserve`       | The tool checks if kserve CRDs are present on the cluster |
| `operator_kserve`  | Check if kserve-controller-manager deployment is ready |

At the end, a brief report is printed with `PASSED` or `FAILED` status for each of the above tests and the suggested action the user should follow.

 **Azure Supported Instance Types**:
- `Standard_NC24ads_A100_v4` (NVIDIA A100)
- `Standard_ND96asr_v4` (NVIDIA A100)
- `Standard_ND96amsr_A100_v4` (NVIDIA A100)
- `Standard_ND96isr_H100_v5` (NVIDIA H100)
- `Standard_ND96isr_H200_v5` (NVIDIA H200)

**GCP Supported Machine Families**:

TPU Machine Families:
- `ct6e` (TPU v6e - Trillium)
- `ct5e` (TPU v5e)
- `ct5p` (TPU v5p)

GPU Machine Families:
- `n1` (NVIDIA T4, K80)
- `a2` (NVIDIA A100)
- `g2` (NVIDIA L4)
- `a3` (NVIDIA H100)

## GKE-Specific Validation

When validating GKE clusters, the tool performs additional checks:

### Accelerator Types

**GPU Validation**:
- Checks for `nvidia.com/gpu` resource allocation
- Validates `cloud.google.com/gke-accelerator` label (GPU type)
- Supported GPUs: T4, A100, L4, H100

**TPU Validation**:
- Checks for `google.com/tpu` resource allocation
- Validates `cloud.google.com/gke-tpu-accelerator` label (TPU type)
- Validates `cloud.google.com/gke-tpu-topology` label (chip layout)
- Supported TPUs: v6e (Trillium), v5e, v5p

### Zone Compatibility (Optional)

For GKE, the tool includes an optional `zone_compatibility` test that validates accelerators are deployed in known-good availability zones. This check uses zone data last updated in February 2026 covering 100+ zones across:

- **TPU v6e**: 9 zones (US, Europe, Asia, South America)
- **TPU v5e**: 5 zones
- **TPU v5p**: 3 zones
- **GPU T4**: 22 zones
- **GPU A100**: 13 zones
- **GPU L4**: 13 zones
- **GPU H100**: 8 zones

This test is marked as optional and warns if accelerators are found in zones not in the validated list.

### Quick Start (GKE)

**Prerequisites for GKE**: Ensure you're authenticated with gcloud:
```bash
gcloud auth login
gcloud container clusters get-credentials <cluster-name> --zone <zone>
```

The container automatically mounts `~/.config/gcloud` for GKE authentication.

```bash
# Run all validation checks (auto-detect GCP)
cd validation
make container
make run

# Explicitly specify GCP
make run-gke

# Run specific suites
make run SUITE=cluster
make run SUITE=operators

# Debug mode
make run-gke-debug
```

### Testing with TPU Cluster

```bash
# Connect to your GKE TPU cluster
gcloud container clusters get-credentials <cluster-name> --zone <zone>

# Run validation
cd validation
python llmd_xks_checks.py --cloud-provider gcp --log-level DEBUG

# Expected output for TPU cluster:
# ✓ Cloud provider: gcp
# ✓ Found supported machine types: ct6e-standard-4t on node-xyz
# ✓ TPU available on: node-xyz (v6e-slice, topology: 2x2: 4 chips)
# ✓ All accelerators in validated zones (optional)
# ✓ All operator CRDs and deployments ready
```

## Standalone script usage

Required dependencies:
  * `configargparse>=1.7.1`
  * `kubernetes>=34.1`

### Command-Line Arguments

- `-l, --log-level`: Set the log level (choices: DEBUG, INFO, WARNING, ERROR, CRITICAL, default: INFO)
- `-k, --kube-config`: Path to the kubeconfig file (overrides KUBECONFIG environment variable)
- `-u, --cloud-provider`: Cloud provider to perform checks on (choices: auto, azure, gcp, default: auto)
- `-c, --config`: Path to a custom config file
- `-s, --suite`: Test suite to run (choices: all, cluster, operators, default: all)
- `-h, --help`: Show help message

### Configuration File

The application automatically looks for config files in the following locations (in order):
1. `~/.llmd-xks-preflight.conf` (user home directory)
2. `./llmd-xks-preflight.conf` (current directory)
3. `/etc/llmd-xks-preflight.conf` (system-wide)

You can also specify a custom config file:
```bash
python llmd_xks_checks.py --config /path/to/config.conf
```

Example config file:
```ini
log_level = INFO
kube_config = /path/to/kubeconfig
cloud_provider = azure
# or for GKE:
# cloud_provider = gcp
```

### Environment Variables

- `LLMD_XKS_LOG_LEVEL`: Log level (same choices as `--log-level`)
- `LLMD_XKS_CLOUD_PROVIDER`: Cloud provider (choices: auto, azure, gcp)
- `LLMD_XKS_SUITE`: Test suite to run (choices: all, cluster, operators)
- `KUBECONFIG`: Path to kubeconfig file (standard Kubernetes environment variable)
