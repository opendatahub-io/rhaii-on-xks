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
| [CoreWeave](https://coreweave.com)   | [CKS](https://coreweave.com/products/coreweave-kubernetes-service)   |


## Container image build

This tool can be packaged and run as a container image and a Containerfile is provided, along with scripts to ease the build process.

In order to build a container locally:

```bash
make image
```

The container is built on top of UBI9 (Universal Base Image 9.5).

The resulting container image repository (name) and tag can be customized by using `CONTAINER_REPO` and `CONTAINER_TAG` environment variables:

```bash
CONTAINER_REPO=quay.io/myusername/llm-d-xks-preflight CONTAINER_TAG=mytag make image
```

## Container image run

After building the container image as described above, a helper script to run the validations against a Kubernetes cluster is available:

```bash
# run all tests
make run

# run specific test suite (cluster, operators, or rhcl)
SUITE=cluster make run
SUITE=operators make run
SUITE=rhcl make run

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

Suite: rhcl -- RHCL (Red Hat Connectivity Link) readiness tests (optional)

| Test name | Meaning |
| --------- | ------- |
| `crd_kuadrant` | Check if Kuadrant/RHCL CRDs are present (authpolicies, ratelimitpolicies, etc.) |
| `operator_kuadrant` | Check if Kuadrant operator is running in kuadrant-operators namespace |
| `operator_authorino` | Check if Authorino operator is running |
| `operator_limitador` | Check if Limitador operator is running |
| `instance_kuadrant` | Check if Kuadrant instance is Ready in kuadrant-system namespace |

> **Note:** All RHCL tests are marked optional since RHCL is an optional component. Run with `--suite rhcl` or as part of `--suite all`.

At the end, a brief report is printed with `PASSED` or `FAILED` status for each of the above tests and the suggested action the user should follow.

 **Azure Supported Instance Types**:
- `Standard_NC24ads_A100_v4` (NVIDIA A100)
- `Standard_ND96asr_v4` (NVIDIA A100)
- `Standard_ND96amsr_A100_v4` (NVIDIA A100)
- `Standard_ND96isr_H100_v5` (NVIDIA H100)
- `Standard_ND96isr_H200_v5` (NVIDIA H200)

 **CoreWeave Supported Instance Types**:
- `b200-8x` (B200 (InfiniBand))
- `gd-8xh200ib-i128` (H200 (InfiniBand))
- `gd-8xh100ib-i128` (H100 (InfiniBand))
- `gd-8xa100-i128` (A100)

## Standalone script usage

Required dependencies:
  * `configargparse>=1.7.1`
  * `kubernetes>=34.1`

### Command-Line Arguments

- `-l, --log-level`: Set the log level (choices: DEBUG, INFO, WARNING, ERROR, CRITICAL, default: INFO)
- `-k, --kube-config`: Path to the kubeconfig file (overrides KUBECONFIG environment variable)
- `-u, --cloud-provider`: Cloud provider to perform checks on (choices: auto, azure, coreweave, default: auto)
- `-c, --config`: Path to a custom config file
- `-s, --suite`: Test suite to run (choices: all, cluster, operators, rhcl, default: all)
- `-h, --help`: Show help message

### Configuration File

The application automatically looks for config files in the following locations (in order):
1. `~/.llmd-xks-preflight.conf` (user home directory)
2. `./llmd-xks-preflight.conf` (current directory)
3. `/etc/llmd-xks-preflight.conf` (system-wide)

You can also specify a custom config file:
```bash
CONFIG=/path/to/config.conf make run
```

Example config file:
```ini
log_level = INFO
kube_config = /path/to/kubeconfig
cloud_provider = azure
```

### Environment Variables

- `LLMD_XKS_LOG_LEVEL`: Log level (same choices as `--log-level`)
- `LLMD_XKS_CLOUD_PROVIDER`: Cloud provider (choices: auto, azure, coreweave)
- `LLMD_XKS_SUITE`: Test suite to run (choices: all(default), cluster, operators, rhcl)
- `KUBECONFIG`: Path to kubeconfig file (standard Kubernetes environment variable)
