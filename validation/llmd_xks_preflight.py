#!/usr/bin/env python3
"""
LLMD xKS preflight checks.
"""

import configargparse  # pyright: ignore[reportMissingImports]
import sys
import logging
import os
import kubernetes  # pyright: ignore[reportMissingImports]


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

        if self.cloud_provider == "auto":
            self.cloud_provider = self.detect_cloud_provider()
            if self.cloud_provider == "none":
                self.logger.error("Failed to detect cloud provider")
                sys.exit(2)
            self.logger.info(f"Cloud provider detected: {self.cloud_provider}")
        else:
            self.logger.info(f"Cloud provider specified: {self.cloud_provider}")

        self.crds_cache = None

        self.tests = {
            "cluster": {
                "description": "Cluster readiness tests",
                "tests": [
                    {
                        "name": "instance_type",
                        "function": self.test_instance_type,
                        "description": "Test if the cluster has at least one supported instance type",
                        "suggested_action": "Provision a cluster with at least one supported instance type",
                        "result": False
                    },
                    {
                        "name": "gpu_availability",
                        "function": self.test_gpu_availability,
                        "description": "Test if the cluster has GPU drivers",
                        "suggested_action": "Provision a cluster with at least one supported GPU driver",
                        "result": False
                    },
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
                        "result": False,
                        "optional": False
                    },
                    {
                        "name": "operator_kserve",
                        "function": self.test_operator_kserve,
                        "description": "test if the kserve controller is running properly",
                        "suggested_action": "install or verify kserve deployment",
                        "result": False,
                    },
                ]
            },
            "rhcl": {
                "description": "RHCL (Red Hat Connectivity Link) readiness tests",
                "tests": [
                    {
                        "name": "crd_kuadrant",
                        "function": self.test_crd_kuadrant,
                        "description": "test if the cluster has the Kuadrant CRDs",
                        "suggested_action": "install RHCL: cd charts/rhcl && helmfile apply",
                        "result": False,
                        "optional": True
                    },
                    {
                        "name": "operator_kuadrant",
                        "function": self.test_operator_kuadrant,
                        "description": "test if the Kuadrant operator is running properly",
                        "suggested_action": "install or verify RHCL deployment",
                        "result": False,
                        "optional": True
                    },
                    {
                        "name": "operator_authorino",
                        "function": self.test_operator_authorino,
                        "description": "test if the Authorino operator is running properly",
                        "suggested_action": "install or verify RHCL deployment",
                        "result": False,
                        "optional": True
                    },
                    {
                        "name": "operator_limitador",
                        "function": self.test_operator_limitador,
                        "description": "test if the Limitador operator is running properly",
                        "suggested_action": "install or verify RHCL deployment",
                        "result": False,
                        "optional": True
                    },
                    {
                        "name": "instance_kuadrant",
                        "function": self.test_instance_kuadrant,
                        "description": "test if the Kuadrant instance is ready",
                        "suggested_action": "verify Kuadrant CR: kubectl get kuadrant -n kuadrant-system",
                        "result": False,
                        "optional": True
                    },
                ]
            }
        }

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

    def test_crd_kuadrant(self):
        required_crds = [
            "kuadrants.kuadrant.io",
            "authpolicies.kuadrant.io",
            "ratelimitpolicies.kuadrant.io",
            "tlspolicies.kuadrant.io",
            "authconfigs.authorino.kuadrant.io",
            "limitadors.limitador.kuadrant.io",
        ]
        if self._test_crds_present(required_crds):
            self.logger.info("All required Kuadrant/RHCL CRDs are present")
            return True
        else:
            self.logger.warning("Missing Kuadrant/RHCL CRDs")
            return False

    def test_operator_kuadrant(self):
        return self._deployment_ready("kuadrant-operators", "kuadrant-operator-controller-manager")

    def test_operator_authorino(self):
        return self._deployment_ready("kuadrant-operators", "authorino-operator")

    def test_operator_limitador(self):
        return self._deployment_ready("kuadrant-operators", "limitador-operator-controller-manager")

    def test_instance_kuadrant(self):
        try:
            api = kubernetes.client.CustomObjectsApi()
            kuadrant = api.get_namespaced_custom_object(
                group="kuadrant.io", version="v1beta1",
                namespace="kuadrant-system", plural="kuadrants", name="kuadrant"
            )
            conditions = kuadrant.get("status", {}).get("conditions", [])
            for c in conditions:
                if c.get("type") == "Ready" and c.get("status") == "True":
                    self.logger.info("Kuadrant instance is Ready")
                    return True
            self.logger.warning("Kuadrant instance exists but is not Ready")
            return False
        except Exception as e:
            self.logger.warning(f"Kuadrant instance not found: {e}")
            return False

    def test_gpu_availability(self):
        def nvidia_driver_present(node):
            allocatable = node.status.allocatable or {}
            if "nvidia.com/gpu" in allocatable:
                if int(node.status.allocatable["nvidia.com/gpu"]) > 0:
                    return True
                else:
                    self.logger.warning(
                        f"No allocatable NVIDIA GPUs on node {node.metadata.name}"
                        " - no NVIDIA GPU drivers present")
                    return False
            else:
                self.logger.warning(
                    f"No NVIDIA GPU drivers present on node {node.metadata.name}"
                    " - no NVIDIA GPU accelerators present")
                return False
        gpu_found = False
        accelerators = {
            "nvidia": 0,
            "other": 0,
        }
        nodes = self.k8s_client.CoreV1Api().list_node() or {}
        for node in nodes.items:
            labels = node.metadata.labels or {}
            # Check if NVIDIA gpu-operator node label is applied --OR-- cloud provider gpu node label is applied
            if ("nvidia.com/gpu.present" in labels or      # NVIDIA gpu-operator
                    labels.get("gpu.nvidia.com/class")):   # CoreWeave
                accelerators["nvidia"] += 1
                self.logger.info(f"NVIDIA GPU accelerator present on node {node.metadata.name}")
                if nvidia_driver_present(node):
                    gpu_found = True
            else:
                accelerators["other"] += 1
        if not gpu_found:
            self.logger.warning("No supported GPU drivers found")
            return False
        else:
            self.logger.info("At least one supported GPU driver found")
            return True

    def test_instance_type(self):
        def azure_instance_type():
            return {
                "Standard_NC24ads_A100_v4": 0,
                "Standard_ND96asr_v4": 0,
                "Standard_ND96amsr_A100_v4": 0,
                "Standard_ND96isr_H100_v5": 0,
                "Standard_ND96isr_H200_v5": 0,
            }

        def coreweave_instance_type():
            return {
                "b200-8x": 0,
                "gd-8xh200ib-i128": 0,
                "gd-8xh100ib-i128": 0,
                "gd-8xa100-i128": 0,
            }

        if self.cloud_provider == "azure":
            instance_types = azure_instance_type()
        elif self.cloud_provider == "coreweave":
            instance_types = coreweave_instance_type()
        else:
            self.logger.warning("Unsupported cloud provider")
            return False

        nodes = self.k8s_client.CoreV1Api().list_node() or {}
        for node in nodes.items:
            labels = node.metadata.labels
            instance_type = ""
            if "beta.kubernetes.io/instance-type" in labels:
                instance_type = labels["beta.kubernetes.io/instance-type"]
            if "node.kubernetes.io/instance-type" in labels:
                instance_type = labels["node.kubernetes.io/instance-type"]
            if instance_type != "":
                try:
                    self.logger.debug(f"{self.cloud_provider}: gpu instance type found {instance_type}")
                    instance_types[instance_type] += 1
                except KeyError:
                    # ignore unknown instance types
                    pass
        max_instance_type = max(instance_types, key=instance_types.get)
        if instance_types[max_instance_type] == 0:
            self.logger.warning("No supported instance type found")
            return False
        else:
            self.logger.info(f"At least one supported {self.cloud_provider} instance type found")
            self.logger.debug(f"Instances by type: {instance_types}")
            return True

    def detect_cloud_provider(self):
        clouds = {
            "none": 0,
            "azure": 0,
            "coreweave": 0,
        }
        nodes = self.k8s_client.CoreV1Api().list_node() or {}
        for node in nodes.items:
            labels = node.metadata.labels
            if "kubernetes.azure.com/cluster" in labels:
                clouds["azure"] += 1
            elif "cks.coreweave.com/cluster" in labels:
                clouds["coreweave"] += 1

        return max(clouds, key=clouds.get)

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
        choices=["auto", "azure", "coreweave"],
        default="auto",
        env_var="LLMD_XKS_CLOUD_PROVIDER",
        help="Cloud provider to perform checks on (by default, try to auto-detect)"
    )

    parser.add_argument(
        "-s", "--suite",
        choices=["all", "cluster", "operators", "rhcl"],
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
