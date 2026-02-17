#!/usr/bin/env python3
"""
LLMD xKS preflight checks.
"""

import configargparse  # pyright: ignore[reportMissingImports]
import sys
import logging
import os
import kubernetes  # pyright: ignore[reportMissingImports]
from cloud_providers import BaseCloudProvider, AzureProvider, GCPProvider


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

        # Initialize cloud provider
        if self.cloud_provider == "auto":
            self.provider = self._detect_provider()
        elif self.cloud_provider == "azure":
            self.provider = AzureProvider(self.k8s_client, self.logger)
        elif self.cloud_provider == "gcp":
            self.provider = GCPProvider(self.k8s_client, self.logger)
        else:
            self.logger.error(f"Unsupported cloud provider: {self.cloud_provider}")
            sys.exit(2)

        self.logger.info(f"Cloud provider: {self.cloud_provider}")

        self.crds_cache = None

        # Build test registry with provider-specific tests
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

    def _detect_provider(self) -> BaseCloudProvider:
        """
        Auto-detect cloud provider from node labels.

        Returns:
            BaseCloudProvider: Detected provider instance

        Exits with code 2 if no provider detected.
        """
        for provider_class in [AzureProvider, GCPProvider]:
            provider = provider_class(self.k8s_client, self.logger)
            if provider.detect():
                provider_name = provider_class.__name__.replace("Provider", "").lower()
                self.logger.info(f"Detected cloud provider: {provider_name}")
                self.cloud_provider = provider_name
                return provider

        self.logger.error("Failed to detect cloud provider")
        sys.exit(2)

    def _build_test_registry(self) -> dict:
        """
        Build test registry with provider-specific and cloud-agnostic tests.

        Returns:
            dict: Test registry structure with cluster and operator tests
        """
        tests = {
            "cluster": {
                "description": "Cluster readiness tests",
                "tests": [
                    {
                        "name": "instance_type",
                        "function": self._test_provider_instance_types,
                        "description": "Validate machine/instance types for cloud provider",
                        "suggested_action": "Provision cluster with supported instance types",
                        "result": False
                    },
                    {
                        "name": "accelerators",
                        "function": self._test_provider_accelerators,
                        "description": "Validate GPU/TPU availability",
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

        # Add GCP-specific zone validation (optional test)
        if isinstance(self.provider, GCPProvider):
            tests["cluster"]["tests"].append({
                "name": "zone_compatibility",
                "function": self._test_zone_compatibility,
                "description": "Validate accelerators in known-good zones (GCP)",
                "suggested_action": "Deploy to recommended zones for better availability",
                "result": False,
                "optional": True
            })

        return tests

    def _test_provider_instance_types(self) -> bool:
        """Delegate instance type validation to provider."""
        success, message = self.provider.validate_instance_types()
        if success:
            self.logger.info(message)
        else:
            self.logger.warning(message)
        return success

    def _test_provider_accelerators(self) -> bool:
        """Delegate accelerator validation to provider."""
        success, message = self.provider.validate_accelerators()
        if success:
            self.logger.info(message)
        else:
            self.logger.warning(message)
        return success

    def _test_zone_compatibility(self) -> bool:
        """GCP-specific zone validation."""
        if isinstance(self.provider, GCPProvider):
            success, message = self.provider.validate_zone_compatibility()
            if success:
                self.logger.info(message)
            else:
                self.logger.warning(message)
            return success
        return True  # Not applicable for other clouds

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
        for suite in suites:
            self.logger.debug(f"Start reporting on suite {suite}")
            for test in self.tests[suite]["tests"]:
                if test["result"]:
                    print(f"Test {test['name']} PASSED")
                    passed_counter += 1
                else:
                    if "optional" in test.keys() and test["optional"]:
                        print(f"Test {test['name']} OPTIONAL [failed]")
                        optional_failed_counter += 1
                    else:
                        print(f"Test {test['name']} FAILED")
                        print(f"    Suggested action: {test['suggested_action']}")
                        failed_counter += 1
        print(f"Total PASSED {passed_counter}")
        print(f"Total OPTIONAL FAILED {optional_failed_counter}")
        print(f"Total FAILED {failed_counter}")
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
        choices=["auto", "azure", "gcp"],
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
