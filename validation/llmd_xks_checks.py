#!/usr/bin/env python3
"""
LLMD xKS preflight checks.

Validates Kubernetes cluster readiness for llm-d deployments on managed
Kubernetes services (Azure AKS).
"""

import configargparse  # pyright: ignore[reportMissingImports]
import sys
import logging
import os
from typing import TypedDict
import kubernetes  # pyright: ignore[reportMissingImports]


# ---------------------------------------------------------------------------
# Cloud provider configuration (data-driven, replaces class hierarchy)
# ---------------------------------------------------------------------------

class AcceleratorConfig(TypedDict):
    name: str               # e.g. "GPU"
    type_label: str         # node label for accelerator type
    resource_key: str       # allocatable resource key
    extra_labels: list[str]  # additional labels to report (e.g. topology)


class CloudProviderConfig(TypedDict):
    detect_labels: list[str]
    instance_families: list[str]
    accelerators: list[AcceleratorConfig]


CLOUD_PROVIDERS: dict[str, CloudProviderConfig] = {
    "azure": {
        "detect_labels": ["kubernetes.azure.com/cluster"],
        "instance_families": [
            "Standard_NC24ads_A100_v4",
            "Standard_ND96asr_v4",
            "Standard_ND96amsr_A100_v4",
            "Standard_ND96isr_H100_v5",
            "Standard_ND96isr_H200_v5"
        ],
        "accelerators": [{
            "name": "GPU",
            "type_label": "nvidia.com/gpu.present",
            "resource_key": "nvidia.com/gpu",
            "extra_labels": []
        }]
    }
}


# ---------------------------------------------------------------------------
# Generic cloud validation functions
# ---------------------------------------------------------------------------

def detect_cloud(nodes, config: CloudProviderConfig) -> bool:
    """Check if any node has any of the detection labels."""
    for node in nodes:
        labels = node.metadata.labels or {}
        for label in config["detect_labels"]:
            if label in labels:
                return True
    return False


def validate_instance_types(nodes, config: CloudProviderConfig, logger) -> tuple[bool, str]:
    """Check node instance-type labels against config's instance_families.

    Families containing '_' use exact matching (e.g. Azure).
    Other families use prefix matching on the first '-'-delimited segment.
    """
    families = config["instance_families"]
    # Determine match mode from naming convention
    use_exact = any("_" in f for f in families)

    found = []
    for node in nodes:
        labels = node.metadata.labels or {}
        instance_type = labels.get("node.kubernetes.io/instance-type") or \
            labels.get("beta.kubernetes.io/instance-type", "")
        if not instance_type:
            continue

        if use_exact:
            if instance_type in families:
                found.append(f"{instance_type} on {node.metadata.name}")
                logger.debug(f"Found supported instance {instance_type} on {node.metadata.name}")
        else:
            family = instance_type.split('-')[0]
            if family in families:
                found.append(f"{instance_type} on {node.metadata.name}")
                logger.debug(f"Found supported machine type {instance_type} on {node.metadata.name}")

    if found:
        return True, f"Found supported instance types: {', '.join(found)}"
    return False, f"No supported instance types found. Expected families: {families}"


def validate_accelerators(nodes, config: CloudProviderConfig, logger) -> tuple[bool, str]:
    """Loop over config's accelerator list, check type_label + resource_key."""
    all_found = []

    for accel in config["accelerators"]:
        accel_nodes = []
        for node in nodes:
            labels = node.metadata.labels or {}
            allocatable = node.status.allocatable or {}

            type_value = labels.get(accel["type_label"], "")
            count = int(allocatable.get(accel["resource_key"], "0"))

            if type_value and count > 0:
                extras = []
                for elabel in accel["extra_labels"]:
                    val = labels.get(elabel, "")
                    if val:
                        key_short = elabel.rsplit("/", 1)[-1]
                        extras.append(f"{key_short}: {val}")

                detail = f"{type_value}: {count}"
                if extras:
                    detail += f", {', '.join(extras)}"
                accel_nodes.append(f"{node.metadata.name} ({detail})")
                logger.debug(f"{accel['name']} {type_value} on {node.metadata.name}: {count}")
            elif type_value and count == 0:
                logger.warning(
                    f"{accel['name']} accelerator present but no allocatable resources "
                    f"on {node.metadata.name}"
                )

        if accel_nodes:
            all_found.append(f"{accel['name']} available on: {', '.join(accel_nodes)}")

    if all_found:
        return True, " | ".join(all_found)
    accel_names = [a["name"] for a in config["accelerators"]]
    return False, f"No accelerators found (checked: {', '.join(accel_names)})"


# ---------------------------------------------------------------------------
# Main validation class
# ---------------------------------------------------------------------------

class LLMDXKSChecks:
    def __init__(self, **kwargs):
        self.log_level = kwargs.get("log_level", "INFO")
        self.logger = self._log_init()

        self.cloud_provider = kwargs.get("cloud_provider", "auto")
        self.kube_config = kwargs.get("kube_config", None)
        self.suite = kwargs.get("suite", "all")

        self.logger.debug(f"Log level: {self.log_level}")
        self.logger.debug(f"Arguments: {kwargs}")
        self.logger.debug("LLMDXKSChecks initialized")

        self.k8s_client = self._k8s_connection()
        if self.k8s_client is None:
            self.logger.error("Failed to connect to Kubernetes cluster")
            sys.exit(1)

        # Resolve cloud provider
        if self.cloud_provider == "auto":
            self.cloud_provider = self._detect_provider()
            if self.cloud_provider is None:
                self.logger.error("Failed to detect cloud provider")
                sys.exit(2)
            self.logger.info(f"Cloud provider detected: {self.cloud_provider}")
        else:
            self.logger.info(f"Cloud provider specified: {self.cloud_provider}")

        self.provider_config = CLOUD_PROVIDERS[self.cloud_provider]
        self.crds_cache = None
        self.tests = self._build_test_registry()

    def _log_init(self):
        logger = logging.getLogger(__name__)
        logger.setLevel(self.log_level)
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
        logger.addHandler(handler)
        return logger

    def _k8s_connection(self):
        try:
            kubernetes.config.load_kube_config(config_file=self.kube_config)
            client = kubernetes.client
            client.CoreV1Api()
        except Exception as e:
            self.logger.error(f"{e}")
            return None
        self.logger.info("Kubernetes connection established")
        return client

    def _detect_provider(self) -> str | None:
        """Auto-detect cloud provider from node labels."""
        try:
            nodes = self.k8s_client.CoreV1Api().list_node().items
        except Exception as e:
            self.logger.error(f"Failed to list nodes for provider detection: {e}")
            return None

        for name, config in CLOUD_PROVIDERS.items():
            if detect_cloud(nodes, config):
                return name
        return None

    def _list_nodes(self):
        return self.k8s_client.CoreV1Api().list_node().items

    def _build_test_registry(self) -> dict:
        tests = {
            "cluster": {
                "description": "Cluster readiness tests",
                "tests": [
                    {
                        "name": "instance_type",
                        "function": self._test_instance_types,
                        "description": "Validate machine/instance types for cloud provider",
                        "suggested_action": "Provision cluster with supported instance types",
                        "result": False
                    },
                    {
                        "name": "accelerators",
                        "function": self._test_accelerators,
                        "description": "Validate accelerator availability",
                        "suggested_action": "Provision cluster with supported accelerators",
                        "result": False
                    }
                ]
            },
            "operators": {
                "description": "Operators readiness tests",
                "tests": [
                    {
                        "name": "crd_certmanager",
                        "function": self.test_crd_certmanager,
                        "description": "test if the cluster has the cert-manager crds",
                        "suggested_action": "install cert-manager",
                        "result": False
                    },
                    {
                        "name": "operator_certmanager",
                        "function": self.test_operator_certmanager,
                        "description": "test if the cert-manager operator is running properly",
                        "suggested_action": "install or verify cert-manager deployment",
                        "result": False
                    },
                    {
                        "name": "crd_sailoperator",
                        "function": self.test_crd_sailoperator,
                        "description": "test if the cluster has the sailoperator crds",
                        "suggested_action": "install sail-operator",
                        "result": False
                    },
                    {
                        "name": "operator_sail",
                        "function": self.test_operator_sail,
                        "description": "test if the sail operator is running properly",
                        "suggested_action": "install or verify sail operator deployment",
                        "result": False
                    },
                    {
                        "name": "crd_lwsoperator",
                        "function": self.test_crd_lwsoperator,
                        "description": "test if the cluster has the lws-operator crds",
                        "suggested_action": "install lws-operator",
                        "result": False,
                        "optional": True
                    },
                    {
                        "name": "operator_lws",
                        "function": self.test_operator_lws,
                        "description": "test if the lws-operator is running properly",
                        "suggested_action": "install or verify lws operator deployment",
                        "result": False,
                        "optional": True
                    },
                    {
                        "name": "crd_kserve",
                        "function": self.test_crd_kserve,
                        "description": "test if the cluster has the kserve crds",
                        "suggested_action": "install kserve",
                        "result": False
                    },
                    {
                        "name": "operator_kserve",
                        "function": self.test_operator_kserve,
                        "description": "test if the kserve controller is running properly",
                        "suggested_action": "install or verify kserve deployment",
                        "result": False
                    }
                ]
            }
        }

        return tests

    # -- Cloud validation test wrappers ------------------------------------

    def _test_instance_types(self) -> bool:
        nodes = self._list_nodes()
        success, message = validate_instance_types(nodes, self.provider_config, self.logger)
        (self.logger.info if success else self.logger.warning)(message)
        return success

    def _test_accelerators(self) -> bool:
        nodes = self._list_nodes()
        success, message = validate_accelerators(nodes, self.provider_config, self.logger)
        (self.logger.info if success else self.logger.warning)(message)
        return success

    # -- CRD / operator tests (unchanged) ----------------------------------

    def _get_all_crd_names(self, cache=True):
        if cache and self.crds_cache is not None:
            return self.crds_cache
        crd_list = self.k8s_client.ApiextensionsV1Api().list_custom_resource_definition()
        crd_names = {crd.metadata.name for crd in crd_list.items}
        if cache:
            self.crds_cache = crd_names
        return crd_names

    def _test_crds_present(self, required_crds):
        all_crds = self._get_all_crd_names()
        return_value = True
        for crd in required_crds:
            if crd not in all_crds:
                self.logger.warning(f"Missing CRD: {crd}")
                return_value = False
        if return_value:
            self.logger.debug("All tested CRDs are present")
        return return_value

    def _deployment_ready(self, namespace_name, deployment_name):
        try:
            deployment = self.k8s_client.AppsV1Api().read_namespaced_deployment(
                name=deployment_name, namespace=namespace_name)
        except Exception as e:
            self.logger.error(f"{e}")
            return False
        desired = deployment.spec.replicas
        ready = deployment.status.ready_replicas or 0
        if ready != desired:
            self.logger.warning(f"Deployment {namespace_name}/{deployment_name} has "
                                f"only {ready} replicas out of {desired} desired")
            return False
        else:
            self.logger.info(f"Deployment {namespace_name}/{deployment_name} ready")
            return True

    def test_crd_certmanager(self):
        required_crds = [
            "certificaterequests.cert-manager.io",
            "certificates.cert-manager.io",
            "clusterissuers.cert-manager.io",
            "issuers.cert-manager.io"
        ]
        if self._test_crds_present(required_crds):
            self.logger.info("All required cert-manager CRDs are present")
            return True
        else:
            self.logger.warning("Missing cert-manager CRDs")
            return False

    def test_operator_certmanager(self):
        test_failed = False
        if not self._deployment_ready("cert-manager-operator", "cert-manager-operator-controller-manager"):
            test_failed = True
        if not self._deployment_ready("cert-manager", "cert-manager-webhook"):
            test_failed = True
        if not self._deployment_ready("cert-manager", "cert-manager-cainjector"):
            test_failed = True
        if not self._deployment_ready("cert-manager", "cert-manager"):
            test_failed = True
        return not test_failed

    def test_crd_sailoperator(self):
        required_crds = [
            "istiocnis.sailoperator.io",
            "istiorevisions.sailoperator.io",
            "istiorevisiontags.sailoperator.io",
            "istios.sailoperator.io",
            "ztunnels.sailoperator.io",
        ]
        if self._test_crds_present(required_crds):
            self.logger.info("All required sail-operator CRDs are present")
            return True
        else:
            self.logger.warning("Missing sail-operator CRDs")
            return False

    def test_operator_sail(self):
        test_failed = False
        if not self._deployment_ready("istio-system", "istiod"):
            test_failed = True
        if not self._deployment_ready("istio-system", "servicemesh-operator3"):
            test_failed = True
        return not test_failed

    def test_crd_lwsoperator(self):
        required_crds = [
            "leaderworkersets.leaderworkerset.x-k8s.io"
        ]
        if self._test_crds_present(required_crds):
            self.logger.info("All required lws-operator CRDs are present")
            return True
        else:
            self.logger.warning("Missing lws-operator CRDs")
            return False

    def test_operator_lws(self):
        test_failed = False
        if not self._deployment_ready("openshift-lws-operator", "openshift-lws-operator"):
            test_failed = True
        return not test_failed

    def test_crd_kserve(self):
        required_crds = [
            "llminferenceservices.serving.kserve.io",
            "llminferenceserviceconfigs.serving.kserve.io",
            "inferencepools.inference.networking.k8s.io",
            "inferencemodels.inference.networking.x-k8s.io",
            "inferenceobjectives.inference.networking.x-k8s.io",
            "inferencepoolimports.inference.networking.x-k8s.io",
            "inferencepools.inference.networking.x-k8s.io",
        ]
        if self._test_crds_present(required_crds):
            self.logger.info("All required kserve CRDs are present")
            return True
        else:
            self.logger.warning("Missing kserve CRDs")
            return False

    def test_operator_kserve(self):
        test_failed = False
        if not self._deployment_ready("opendatahub", "kserve-controller-manager"):
            test_failed = True
        return not test_failed

    # -- Run & report ------------------------------------------------------

    def run(self, suite=None):
        suites = []
        if suite is None:
            suite = self.suite
        if suite == "all":
            self.logger.debug("Running all known tests")
            suites = ["cluster", "operators"]
        else:
            self.logger.debug(f"Running suite {suite}")
            suites.append(suite)
        for suite in suites:
            self.logger.info(f'Starting {suite} suite of tests - {self.tests[suite]["description"]}')
            for test in self.tests[suite]["tests"]:
                if test["function"]():
                    self.logger.debug(f"Test {test['name']} passed")
                    test["result"] = True
                else:
                    self.logger.error(f"Test {test['name']} failed")
                    test["result"] = False
        return None

    @staticmethod
    def _supports_color():
        return hasattr(sys.stdout, "isatty") and sys.stdout.isatty()

    def _color(self, code, text):
        if self._supports_color():
            return f"\033[{code}m{text}\033[0m"
        return text

    def _green(self, text):
        return self._color("32", text)

    def _red(self, text):
        return self._color("31", text)

    def _yellow(self, text):
        return self._color("33", text)

    def _bold(self, text):
        return self._color("1", text)

    def _dim(self, text):
        return self._color("2", text)

    def report(self, suite=None):
        suites = []
        if suite is None:
            suite = self.suite
        if suite == "all":
            self.logger.debug("Reporting on all known tests")
            suites = ["cluster", "operators"]
        else:
            self.logger.debug(f"Reporting on suite {suite}")
            suites.append(suite)

        failed_counter = 0
        passed_counter = 0
        optional_failed_counter = 0
        width = 50

        header_line = "=" * width
        print()
        print(self._bold(header_line))
        print(self._bold("  LLM-D xKS Preflight Validation Report"))
        print(self._bold(header_line))

        for suite in suites:
            self.logger.debug(f"Start reporting on suite {suite}")
            section_title = self.tests[suite]["description"].replace(" tests", "")
            print()
            print(self._bold(f"  {section_title}"))
            print(self._dim("  " + "-" * (width - 2)))

            for test in self.tests[suite]["tests"]:
                name = test["name"]
                if test["result"]:
                    print(f"  {self._green('PASS')} {name}")
                    passed_counter += 1
                elif test.get("optional"):
                    print(f"  {self._yellow('SKIP')} {name} {self._dim('(optional)')}")
                    optional_failed_counter += 1
                else:
                    print(f"  {self._red('FAIL')} {name}")
                    print(f"    {self._dim('->')} {test['suggested_action']}")
                    failed_counter += 1

        parts = []
        parts.append(self._green(f"{passed_counter} passed"))
        parts.append(self._red(f"{failed_counter} failed"))
        if optional_failed_counter:
            parts.append(self._yellow(f"{optional_failed_counter} optional"))
        summary = "  |  ".join(parts)

        print()
        print(self._bold(header_line))
        print(f"  Results:  {summary}")
        print(self._bold(header_line))
        print()

        return failed_counter


def cli_arguments():
    default_config_paths = [
        os.path.expanduser("~/.llmd-xks-preflight.conf"),
        os.path.join(os.getcwd(), "llmd-xks-preflight.conf"),
        "/etc/llmd-xks-preflight.conf",
    ]

    parser = configargparse.ArgumentParser(
        description="LLMD xKS preflight checks.",
        default_config_files=default_config_paths,
        config_file_parser_class=configargparse.ConfigparserConfigFileParser,
        auto_env_var_prefix="LLMD_XKS_",
    )

    parser.add_argument(
        "-c", "--config",
        is_config_file=True,
        help="Path to config file"
    )

    parser.add_argument(
        "-l", "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        default="INFO",
        env_var="LLMD_XKS_LOG_LEVEL",
        help="Set the log level (default: INFO)"
    )

    parser.add_argument(
        "-k", "--kube-config",
        type=str,
        default=None,
        env_var="KUBECONFIG",
        help="Path to the kubeconfig file"
    )

    parser.add_argument(
        "-u", "--cloud-provider",
        choices=["auto", "azure"],
        default="auto",
        env_var="LLMD_XKS_CLOUD_PROVIDER",
        help="Cloud provider to perform checks on (by default, try to auto-detect)"
    )

    parser.add_argument(
        "-s", "--suite",
        choices=["all", "cluster", "operators"],
        default="all",
        env_var="LLMD_XKS_SUITE",
        help="Test suite to execute"
    )

    return parser.parse_args()


def main():
    args = cli_arguments()
    validator = LLMDXKSChecks(**vars(args))
    validator.run()
    sys.exit(validator.report())


if __name__ == "__main__":
    main()
