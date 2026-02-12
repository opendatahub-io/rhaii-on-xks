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

        self.logger.debug(f"Log level: {self.log_level}")
        self.logger.debug(f"Arguments: {kwargs}")
        self.logger.debug("LLMDXKSChecks initialized")

        self.k8s_core_api, self.k8s_ext_api = self._k8s_connection()

        if self.k8s_core_api is None or self.k8s_ext_api is None:
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

        self.tests = [
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
            {
                "name": "crd_certmanager",
                "function": self.test_crd_certmanager,
                "description": "test if the cluster has the cert-manager crds",
                "suggested_action": "install cert-manager",
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
                "name": "crd_lwsoperator",
                "function": self.test_crd_lwsoperator,
                "description": "test if the cluster has the lws-operator crds",
                "suggested_action": "install lws-operator",
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
        ]

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
            core_api = kubernetes.client.CoreV1Api()
            ext_api = kubernetes.client.ApiextensionsV1Api()
        except Exception as e:
            self.logger.error(f"{e}")
            return None, None
        self.logger.info("Kubernetes connection established")
        return core_api, ext_api

    def _get_all_crd_names(self, cache=True):
        if cache and self.crds_cache is not None:
            return self.crds_cache
        crd_list = self.k8s_ext_api.list_custom_resource_definition()
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
        nodes = self.k8s_core_api.list_node()
        for node in nodes.items:
            labels = node.metadata.labels or {}
            if "nvidia.com/gpu.present" in labels:
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
            instance_types = {
                "Standard_NC24ads_A100_v4": 0,
                "Standard_ND96asr_v4": 0,
                "Standard_ND96amsr_A100_v4": 0,
                "Standard_ND96isr_H100_v5": 0,
                "Standard_ND96isr_H200_v5": 0,
            }
            nodes = self.k8s_core_api.list_node() or {}
            for node in nodes.items:
                labels = node.metadata.labels
                instance_type = ""
                if "beta.kubernetes.io/instance-type" in labels:
                    instance_type = labels["beta.kubernetes.io/instance-type"]
                if "node.kubernetes.io/instance-type" in labels:
                    instance_type = labels["node.kubernetes.io/instance-type"]
                if instance_type != "":
                    try:
                        instance_types[instance_type] += 1
                    except KeyError:
                        # ignore unknown instance types
                        pass
            max_instance_type = max(instance_types, key=instance_types.get)
            if instance_types[max_instance_type] == 0:
                self.logger.warning("No supported instance type found")
                return False
            else:
                self.logger.info("At least one supported Azure instance type found")
                self.logger.debug(f"Instances by type: {instance_types}")
                return True

        if self.cloud_provider == "azure":
            return azure_instance_type()
        else:
            self.logger.warning("Unsupported cloud provider")
            return False

    def detect_cloud_provider(self):
        clouds = {
            "none": 0,
            "azure": 0,
        }
        nodes = self.k8s_core_api.list_node() or {}
        for node in nodes.items:
            labels = node.metadata.labels
            if "kubernetes.azure.com/cluster" in labels:
                clouds["azure"] += 1

        return max(clouds, key=clouds.get)

    def run(self, tests=None):
        if tests is None:
            tests = self.tests
        for test in tests:
            if test["function"]():
                self.logger.debug(f"Test {test['name']} passed")
                test["result"] = True
            else:
                self.logger.error(f"Test {test['name']} failed")
                test["result"] = False
        return None

    def report(self):
        failed_counter = 0
        for test in self.tests:
            if test["result"]:
                print(f"Test {test['name']} PASSED")
            else:
                if "optional" in test.keys() and test["optional"]:
                    print(f"Test {test['name']} OPTIONAL [failed]")
                else:
                    print(f"Test {test['name']} FAILED")
                    print(f"    Suggested action: {test['suggested_action']}")
                    failed_counter += 1
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

    return parser.parse_args()


def main():
    args = cli_arguments()
    validator = LLMDXKSChecks(**vars(args))
    validator.run()
    sys.exit(validator.report())


if __name__ == "__main__":
    main()
