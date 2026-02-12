# LLM-D xKS Preflight Validation Checks

A CLI application for running validation checks against Kubernetes clusters in the context of Red Hat AI Inference Server (KServe LLMInferenceService) on managed Kubernetes platforms (AKS, CoreWeave etc.). The tool connects to a running Kubernetes cluster, detects the cloud provider, and executes a series of validation tests to ensure the cluster is properly configured and ready for use.

## Features

- **Cloud Provider Detection**: Automatically detects cloud provider (Azure, AWS) or allows manual specification
- **Configurable Logging**: Adjustable log levels for debugging and monitoring
- **Flexible Configuration**: Supports command-line arguments, config files, and environment variables
- **Test Framework**: Extensible test execution framework for preflight validations
- **Test Reporting**: Detailed test results with suggested actions for failures

## Supported cloud Kubernetes Services

| Cloud provider | Managed K8s Service |
| -------------- | ------------------- |
| [Azure](https://azure.microsoft.com) | [AKS](https://azure.microsoft.com/en-us/products/kubernetes-service) |


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

| Test name | Meaning |
| --------- | ------- |
| `cloud_provider` | The validation script tries to determine the cloud provider the cluster is running on. Can be overridden with `--cloud-provider` |
| `instance_type` | At least one supported instance type must be present as a cluster node. See below for details. |
| `gpu_availability` | At least one supported GPU must be available on a cluster node. Availability is determined by driver presence and node labels |
| `crd_certmanager` | The tool checks if cert-manager CRDs are present on the cluster |
| `crd_sailoperator` | The tool checks if sail-operator CRDs are present on the cluster |
| `crd_lwsoperator`  | The tool checks if lws-operator CRDs are present on the cluster |
| `crd_kserve`       | The tool checks if kserve CRDs are present on the cluster |

At the end, a brief report is printed with `PASSED` or `FAILED` status for each of the above tests and the suggested action the user should follow.

 **Azure Supported Instance Types**:
- `Standard_NC24ads_A100_v4` (NVIDIA A100)
- `Standard_ND96asr_v4` (NVIDIA A100)
- `Standard_ND96amsr_A100_v4` (NVIDIA A100)
- `Standard_ND96isr_H100_v5` (NVIDIA H100)
- `Standard_ND96isr_H200_v5` (NVIDIA H200)


## Standalone script usage

Required dependencies:
  * `configargparse>=1.7.1`
  * `kubernetes>=34.1`

### Command-Line Arguments

- `-l, --log-level`: Set the log level (choices: DEBUG, INFO, WARNING, ERROR, CRITICAL, default: INFO)
- `-k, --kube-config`: Path to the kubeconfig file (overrides KUBECONFIG environment variable)
- `-u, --cloud-provider`: Cloud provider to perform checks on (choices: auto, azure, default: auto)
- `-c, --config`: Path to a custom config file
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
```

### Environment Variables

- `LLMD_XKS_LOG_LEVEL`: Log level (same choices as `--log-level`)
- `LLMD_XKS_CLOUD_PROVIDER`: Cloud provider (choices: auto, azure)
- `KUBECONFIG`: Path to kubeconfig file (standard Kubernetes environment variable)
