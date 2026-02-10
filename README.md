# LLM-D xKS Preflight Checks

A Python CLI application for running preflight checks on Kubernetes clusters. The tool connects to a Kubernetes cluster, detects the cloud provider, and executes a series of validation tests to ensure the cluster is properly configured and ready for use.

## Features

- **Cloud Provider Detection**: Automatically detects cloud provider (Azure, AWS) or allows manual specification
- **Configurable Logging**: Adjustable log levels for debugging and monitoring
- **Flexible Configuration**: Supports command-line arguments, config files, and environment variables
- **Test Framework**: Extensible test execution framework for preflight validations
- **Test Reporting**: Detailed test results with suggested actions for failures

## Container build & run

In order to build a container:

```bash
make container
```

By default, the container is built on top of latest Fedora image. If you have an entitled Red Hat Enterprise Linux system, you can use UBI9 (Universal Basic Image) as the base:

```bash
FROM=registry.access.redhat.com/ubi9:latest make container
```

In order to run the container locally:

```bash
make run
```

And in order to run with a custom KUBECONFIG:

```bash
HOST_KUBECONFIG=/path/to/kube/config make run
```

## Installation

Install the required dependencies:

```bash
pip install configargparse kubernetes
```

## Usage

### Basic Usage

```bash
# Run with default settings (auto-detects cloud provider)
python llmd-xks-checks.py

# With custom log level
python llmd-xks-checks.py --log-level DEBUG

# With custom kubeconfig path
python llmd-xks-checks.py --kube-config /path/to/kubeconfig

# Specify cloud provider explicitly
python llmd-xks-checks.py --cloud-provider azure

# Show help
python llmd-xks-checks.py --help
```

### Configuration File

The application automatically looks for config files in the following locations (in order):
1. `~/.llmd-xks-preflight.conf` (user home directory)
2. `./llmd-xks-preflight.conf` (current directory)
3. `/etc/llmd-xks-preflight.conf` (system-wide)

You can also specify a custom config file:
```bash
python llmd-xks-checks.py --config /path/to/config.conf
```

Example config file:
```ini
log_level = INFO
kube_config = /path/to/kubeconfig
cloud_provider = azure
```

### Environment Variables

The application supports environment variables for configuration:

```bash
# Set log level via environment variable
export LLMD_XKS_LOG_LEVEL=DEBUG

# Set cloud provider
export LLMD_XKS_CLOUD_PROVIDER=azure

# Set kubeconfig path (uses standard KUBECONFIG variable)
export KUBECONFIG=/path/to/kubeconfig

# Run the application
python llmd-xks-checks.py
```

## Configuration Priority

Arguments are resolved in the following priority order (highest to lowest):
1. **Command-line arguments** (highest priority)
2. **Environment variables**
3. **Config file** (from default locations or `--config`)
4. **Default values** (lowest priority)

## Command-Line Arguments

- `-l, --log-level`: Set the log level (choices: DEBUG, INFO, WARNING, ERROR, CRITICAL, default: INFO)
- `-k, --kube-config`: Path to the kubeconfig file (overrides KUBECONFIG environment variable)
- `-u, --cloud-provider`: Cloud provider to perform checks on (choices: auto, azure, default: auto)
- `-c, --config`: Path to a custom config file
- `-h, --help`: Show help message

## Environment Variables

- `LLMD_XKS_LOG_LEVEL`: Log level (same choices as `--log-level`)
- `LLMD_XKS_CLOUD_PROVIDER`: Cloud provider (choices: auto, azure)
- `KUBECONFIG`: Path to kubeconfig file (standard Kubernetes environment variable)

## Cloud Provider Detection

The application can automatically detect the cloud provider by examining node labels in the Kubernetes cluster:

- **Azure**: Detected by presence of `kubernetes.azure.com/cluster` label on nodes
- **AWS**: Detection support is available (currently not fully implemented)
- **Auto-detection**: When `--cloud-provider auto` is used (default), the tool attempts to detect the provider automatically

If auto-detection fails and no provider is explicitly specified, the application exits with code 2.

## Kubernetes Connection

The application connects to Kubernetes clusters using the standard Kubernetes Python client library. It:

- Loads kubeconfig from the default location (`~/.kube/config`) or the path specified via `--kube-config` or `KUBECONFIG`
- Establishes a connection to the cluster using the CoreV1Api
- Exits with an error code if the connection fails
- Logs connection status for debugging

## Preflight Tests

The application runs a series of preflight checks to validate cluster configuration:

### Instance Type Test

**Description**: Validates that the cluster has at least one supported instance type for the detected cloud provider.

**Azure Supported Instance Types**:
- `Standard_NC24ads_A100_v4` (NVIDIA A100)
- `Standard_ND96asr_v4` (NVIDIA A100)
- `Standard_ND96amsr_A100_v4` (NVIDIA A100)
- `Standard_ND96isr_H100_v5` (NVIDIA H100)
- `Standard_ND96isr_H200_v5` (NVIDIA H200)

**Behavior**:
- Scans all nodes in the cluster
- Checks node instance types against the supported list
- Reports failure if no supported instance types are found
- Provides suggested action when test fails

## Test Reporting

After running all tests, the application generates a report showing:

- Test name and result (PASSED/FAILED)
- Suggested actions for failed tests

Example output:
```
Test instance_type PASSED
```

or

```
Test instance_type FAILED
    Suggested action: Provision a cluster with at least one supported instance type
```

## Error Handling

- **Exit code 1**: Kubernetes connection failed
- **Exit code 2**: Cloud provider auto-detection failed (when using `--cloud-provider auto`)
- All errors are logged according to the configured log level
- Connection errors include detailed exception information when log level is set to DEBUG

## Extending the Test Suite

The test framework is designed to be extensible. Tests are defined as dictionaries with the following structure:

```python
{
    "name": "test_name",
    "function": self.test_function,
    "description": "Test description",
    "suggested_action": "Action to take if test fails",
    "result": False
}
```

Add new tests to the `self.tests` list in the `__init__` method to extend functionality.
