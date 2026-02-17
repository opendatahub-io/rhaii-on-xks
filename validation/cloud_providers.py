#!/usr/bin/env python3
"""
Cloud provider abstraction for multi-cloud Kubernetes validation.

Supports Azure AKS and Google Cloud GKE with extensible architecture
for future cloud providers (CoreWeave, AWS).
"""

from abc import ABC, abstractmethod
from typing import Tuple, Dict, Optional
import logging
import kubernetes.client  # type: ignore


class BaseCloudProvider(ABC):
    """
    Abstract base class for cloud provider-specific validation logic.

    Each cloud provider implementation must define:
    - detect(): Auto-detect if this cloud is present
    - validate_instance_types(): Check machine/instance types
    - validate_accelerators(): Check GPU/TPU availability
    """

    def __init__(self, k8s_client: kubernetes.client, logger: logging.Logger) -> None:
        """
        Initialize cloud provider with Kubernetes client and logger.

        Args:
            k8s_client: Kubernetes client (kubernetes.client)
            logger: Python logger instance
        """
        self.k8s = k8s_client
        self.logger = logger

    @abstractmethod
    def detect(self) -> bool:
        """
        Detect if this cloud provider is present in the cluster.

        Returns:
            bool: True if this cloud provider is detected
        """
        pass

    @abstractmethod
    def validate_instance_types(self) -> Tuple[bool, str]:
        """
        Validate machine/instance types are supported for LLM workloads.

        Returns:
            Tuple[bool, str]: (success, message) where:
                - success: True if at least one supported type found
                - message: Description of what was found/missing
        """
        pass

    @abstractmethod
    def validate_accelerators(self) -> Tuple[bool, str]:
        """
        Validate GPU/TPU availability and drivers.

        Returns:
            Tuple[bool, str]: (success, message) where:
                - success: True if accelerators are available
                - message: Description of accelerators found
        """
        pass

    def get_zone_data(self) -> Dict[str, Dict[str, Dict[str, str]]]:
        """
        Optional: Return zone/region data for cloud-specific validation.

        Returns:
            dict: Zone/region metadata (cloud-specific structure)
        """
        return {}


class AzureProvider(BaseCloudProvider):
    """
    Azure AKS cloud provider implementation.

    Supports validation of:
    - Azure VM instance types (NC/ND series with A100/H100/H200)
    - NVIDIA GPU availability (nvidia.com/gpu)
    """

    SUPPORTED_INSTANCES = [
        "Standard_NC24ads_A100_v4",
        "Standard_ND96asr_v4",
        "Standard_ND96amsr_A100_v4",
        "Standard_ND96isr_H100_v5",
        "Standard_ND96isr_H200_v5"
    ]

    def detect(self) -> bool:
        """Detect Azure AKS via kubernetes.azure.com/cluster label."""
        try:
            nodes = self.k8s.CoreV1Api().list_node()
        except kubernetes.client.exceptions.ApiException as e:
            self.logger.error(f"Failed to list nodes for Azure detection: {e}")
            return False
        except Exception as e:
            self.logger.error(f"Unexpected error during Azure detection: {e}")
            return False

        for node in nodes.items:
            labels = node.metadata.labels or {}
            if "kubernetes.azure.com/cluster" in labels:
                self.logger.debug(f"Azure AKS detected on node {node.metadata.name}")
                return True
        return False

    def validate_instance_types(self) -> Tuple[bool, str]:
        """
        Validate Azure VM instance types.

        Checks for Standard_NC*/Standard_ND* series VMs with A100/H100/H200 GPUs.
        """
        instance_types = {vm: 0 for vm in self.SUPPORTED_INSTANCES}

        nodes = self.k8s.CoreV1Api().list_node()
        for node in nodes.items:
            labels = node.metadata.labels or {}

            # Try both old and new instance-type labels
            instance_type = labels.get("node.kubernetes.io/instance-type") or \
                            labels.get("beta.kubernetes.io/instance-type", "")

            if instance_type in instance_types:
                instance_types[instance_type] += 1
                self.logger.debug(f"Found supported instance {instance_type} on {node.metadata.name}")

        # Find most common supported instance type
        max_instance_type = max(instance_types, key=instance_types.get)
        if instance_types[max_instance_type] == 0:
            return False, f"No supported Azure instance types found. Expected: {self.SUPPORTED_INSTANCES}"

        found_types = [f"{vm} ({count} nodes)" for vm, count in instance_types.items() if count > 0]
        return True, f"Found supported Azure instance types: {', '.join(found_types)}"

    def validate_accelerators(self) -> Tuple[bool, str]:
        """
        Validate NVIDIA GPU availability on Azure.

        Checks for nvidia.com/gpu resource and nvidia.com/gpu.present label.
        """
        gpu_found = False
        gpu_nodes = []

        nodes = self.k8s.CoreV1Api().list_node()
        for node in nodes.items:
            labels = node.metadata.labels or {}
            allocatable = node.status.allocatable or {}

            # Check if GPU is present and allocatable
            if "nvidia.com/gpu.present" in labels:
                gpu_count = allocatable.get("nvidia.com/gpu", "0")
                if int(gpu_count) > 0:
                    gpu_found = True
                    gpu_nodes.append(f"{node.metadata.name} ({gpu_count} GPUs)")
                    self.logger.debug(f"GPU available on {node.metadata.name}: {gpu_count}")
                else:
                    self.logger.warning(
                        f"GPU accelerator present but no drivers on {node.metadata.name}"
                    )

        if gpu_found:
            return True, f"GPU available on: {', '.join(gpu_nodes)}"
        else:
            return False, "No GPUs with drivers found (checked nvidia.com/gpu resource)"


class GCPProvider(BaseCloudProvider):
    """
    Google Cloud GKE provider implementation.

    Supports validation of:
    - GCP machine types (CT6E/CT5E/CT5P for TPU, N1/A2/G2/A3 for GPU)
    - NVIDIA GPU availability (nvidia.com/gpu)
    - Google Cloud TPU availability (google.com/tpu + topology labels)
    - Zone compatibility (optional, 100+ zones mapped)
    """

    # Machine families for instance type validation
    TPU_MACHINE_FAMILIES = ["ct6e", "ct5e", "ct5p"]
    GPU_MACHINE_FAMILIES = ["n1", "a2", "g2", "a3"]

    # Zone data ported from check-accelerator-availability.sh
    # Last updated: Feb 2026
    ZONE_DATA = {
        'tpu': {
            'v6e': {
                'us-central1-b': 'US Central',
                'us-east1-d': 'US East',
                'us-east5-a': 'US East (Columbus)',
                'us-east5-b': 'US East (Columbus)',
                'us-south1-a': 'US South (Dallas)',
                'us-south1-b': 'US South (Dallas)',
                'europe-west4-a': 'Europe (Netherlands)',
                'asia-northeast1-b': 'Asia (Tokyo)',
                'southamerica-west1-a': 'South America (Santiago)'
            },
            'v5e': {
                'europe-west4-b': 'Europe (Netherlands)',
                'us-central1-a': 'US Central',
                'us-south1-a': 'US South (Dallas)',
                'us-west1-c': 'US West (Oregon)',
                'us-west4-a': 'US West (Las Vegas)'
            },
            'v5p': {
                'europe-west4-b': 'Europe (Netherlands)',
                'us-central1-a': 'US Central',
                'us-east5-a': 'US East (Columbus)'
            }
        },
        'gpu': {
            't4': {
                'us-central1-a': 'US Central',
                'us-central1-b': 'US Central',
                'us-central1-c': 'US Central',
                'us-central1-f': 'US Central',
                'us-east1-b': 'US East',
                'us-east1-c': 'US East',
                'us-east1-d': 'US East',
                'us-east4-a': 'US East (Virginia)',
                'us-east4-b': 'US East (Virginia)',
                'us-east4-c': 'US East (Virginia)',
                'us-west1-a': 'US West (Oregon)',
                'us-west1-b': 'US West (Oregon)',
                'us-west2-b': 'US West (Los Angeles)',
                'us-west2-c': 'US West (Los Angeles)',
                'us-west4-a': 'US West (Las Vegas)',
                'us-west4-b': 'US West (Las Vegas)',
                'europe-west1-b': 'Europe (Belgium)',
                'europe-west1-c': 'Europe (Belgium)',
                'europe-west4-a': 'Europe (Netherlands)',
                'europe-west4-b': 'Europe (Netherlands)',
                'asia-east1-a': 'Asia (Taiwan)',
                'asia-southeast1-a': 'Asia (Singapore)'
            },
            'a100': {
                'us-central1-a': 'US Central',
                'us-central1-b': 'US Central',
                'us-central1-c': 'US Central',
                'us-east1-c': 'US East',
                'us-east4-a': 'US East (Virginia)',
                'us-east4-b': 'US East (Virginia)',
                'us-west1-a': 'US West (Oregon)',
                'us-west1-b': 'US West (Oregon)',
                'europe-west4-a': 'Europe (Netherlands)',
                'europe-west4-b': 'Europe (Netherlands)',
                'asia-southeast1-c': 'Asia (Singapore)',
                'asia-northeast1-a': 'Asia (Tokyo)',
                'asia-northeast1-c': 'Asia (Tokyo)'
            },
            'l4': {
                'us-central1-a': 'US Central',
                'us-central1-b': 'US Central',
                'us-central1-c': 'US Central',
                'us-east1-c': 'US East',
                'us-east4-a': 'US East (Virginia)',
                'us-east4-b': 'US East (Virginia)',
                'us-west1-a': 'US West (Oregon)',
                'us-west1-b': 'US West (Oregon)',
                'us-west4-b': 'US West (Las Vegas)',
                'europe-west1-b': 'Europe (Belgium)',
                'europe-west4-a': 'Europe (Netherlands)',
                'asia-southeast1-b': 'Asia (Singapore)',
                'asia-northeast1-b': 'Asia (Tokyo)'
            },
            'h100': {
                'us-central1-a': 'US Central',
                'us-central1-b': 'US Central',
                'us-east4-a': 'US East (Virginia)',
                'us-east4-c': 'US East (Virginia)',
                'us-west1-a': 'US West (Oregon)',
                'us-west4-b': 'US West (Las Vegas)',
                'europe-west4-a': 'Europe (Netherlands)',
                'asia-southeast1-c': 'Asia (Singapore)'
            }
        }
    }

    def detect(self) -> bool:
        """Detect GKE via cloud.google.com/gke-* labels."""
        try:
            nodes = self.k8s.CoreV1Api().list_node()
        except kubernetes.client.exceptions.ApiException as e:
            self.logger.error(f"Failed to list nodes for GKE detection: {e}")
            return False
        except Exception as e:
            self.logger.error(f"Unexpected error during GKE detection: {e}")
            return False

        for node in nodes.items:
            labels = node.metadata.labels or {}
            if "cloud.google.com/gke-nodepool" in labels or \
               "cloud.google.com/gke-os-distribution" in labels:
                self.logger.debug(f"GKE detected on node {node.metadata.name}")
                return True
        return False

    def validate_instance_types(self) -> Tuple[bool, str]:
        """
        Validate GCP machine types.

        Checks for supported families:
        - TPU: ct6e, ct5e, ct5p (e.g., ct6e-standard-4t)
        - GPU: n1, a2, g2, a3 (e.g., n1-standard-4, a2-highgpu-1g)
        """
        valid_types = []
        all_families = self.TPU_MACHINE_FAMILIES + self.GPU_MACHINE_FAMILIES

        nodes = self.k8s.CoreV1Api().list_node()
        for node in nodes.items:
            labels = node.metadata.labels or {}
            machine_type = labels.get("node.kubernetes.io/instance-type", "")

            if machine_type:
                # Extract family (first component before '-')
                family = machine_type.split('-')[0]

                if family in all_families:
                    valid_types.append(f"{machine_type} on {node.metadata.name}")
                    self.logger.debug(f"Found supported machine type {machine_type} on {node.metadata.name}")

        if valid_types:
            return True, f"Found supported machine types: {', '.join(valid_types)}"
        else:
            return False, f"No supported machine types. Expected families: {all_families}"

    def validate_accelerators(self) -> Tuple[bool, str]:
        """
        Validate GPU and TPU availability on GKE.

        Checks both GPU (nvidia.com/gpu) and TPU (google.com/tpu) resources.
        """
        gpu_result = self._check_gpu()
        tpu_result = self._check_tpu()

        # Success if either GPU or TPU is found
        if gpu_result[0] or tpu_result[0]:
            messages = [r[1] for r in [gpu_result, tpu_result] if r[0]]
            return True, " | ".join(messages)
        else:
            return False, f"No accelerators found. GPU: {gpu_result[1]}, TPU: {tpu_result[1]}"

    def _check_gpu(self) -> Tuple[bool, str]:
        """Check NVIDIA GPU availability on GKE nodes."""
        gpu_nodes = []

        try:
            nodes = self.k8s.CoreV1Api().list_node()
        except Exception as e:
            self.logger.error(f"Failed to list nodes for GPU check: {e}")
            return False, f"Failed to query nodes: {e}"

        for node in nodes.items:
            labels = node.metadata.labels or {}
            allocatable = node.status.allocatable or {}

            gpu_type = labels.get("cloud.google.com/gke-accelerator", "")
            gpu_count = allocatable.get("nvidia.com/gpu", "0")

            if gpu_type and int(gpu_count) > 0:
                gpu_nodes.append(f"{node.metadata.name} ({gpu_type}: {gpu_count})")
                self.logger.debug(f"GPU {gpu_type} available on {node.metadata.name}: {gpu_count}")

        if gpu_nodes:
            return True, f"GPU available on: {', '.join(gpu_nodes)}"
        else:
            return False, "No GPUs found (checked nvidia.com/gpu resource)"

    def _check_tpu(self) -> Tuple[bool, str]:
        """Check Google Cloud TPU availability on GKE nodes."""
        tpu_nodes = []

        try:
            nodes = self.k8s.CoreV1Api().list_node()
        except Exception as e:
            self.logger.error(f"Failed to list nodes for TPU check: {e}")
            return False, f"Failed to query nodes: {e}"

        for node in nodes.items:
            labels = node.metadata.labels or {}
            allocatable = node.status.allocatable or {}

            tpu_type = labels.get("cloud.google.com/gke-tpu-accelerator", "")
            tpu_count = allocatable.get("google.com/tpu", "0")
            tpu_topology = labels.get("cloud.google.com/gke-tpu-topology", "")

            if tpu_type and int(tpu_count) > 0:
                topology_str = f", topology: {tpu_topology}" if tpu_topology else ""
                tpu_nodes.append(f"{node.metadata.name} ({tpu_type}{topology_str}: {tpu_count} chips)")
                self.logger.debug(
                    f"TPU {tpu_type} available on {node.metadata.name}: {tpu_count} chips, topology: {tpu_topology}"
                )

        if tpu_nodes:
            return True, f"TPU available on: {', '.join(tpu_nodes)}"
        else:
            return False, "No TPUs found (checked google.com/tpu resource)"

    def validate_zone_compatibility(self) -> Tuple[bool, str]:
        """
        GCP-specific: Validate accelerators are in known-good zones.

        This is an optional validation that checks if TPUs/GPUs are deployed
        in zones that have been validated for availability (as of Feb 2026).
        """
        warnings = []

        nodes = self.k8s.CoreV1Api().list_node()
        for node in nodes.items:
            labels = node.metadata.labels or {}
            zone = labels.get("topology.kubernetes.io/zone", "")

            # Check TPU zone compatibility
            tpu_type = labels.get("cloud.google.com/gke-tpu-accelerator", "")
            if tpu_type and zone:
                # Extract version (e.g., "v6e-slice" → "v6e")
                if '-' in tpu_type:
                    tpu_version = tpu_type.split('-')[0]
                else:
                    tpu_version = tpu_type
                    self.logger.warning(f"Unexpected TPU type format (no hyphen): {tpu_type}")

                valid_zones = self.ZONE_DATA.get('tpu', {}).get(tpu_version, {})

                if valid_zones and zone not in valid_zones:
                    warnings.append(
                        f"TPU {tpu_type} on {node.metadata.name} in zone {zone} "
                        f"not in validated zones for {tpu_version}"
                    )
                    self.logger.warning(warnings[-1])

            # Check GPU zone compatibility
            gpu_type = labels.get("cloud.google.com/gke-accelerator", "")
            if gpu_type and zone:
                # Normalize GPU type (e.g., "nvidia-tesla-t4" → "t4")
                gpu_short = gpu_type.replace("nvidia-tesla-", "").replace("nvidia-", "")
                if gpu_short == gpu_type:
                    self.logger.warning(f"Unexpected GPU type format (no nvidia prefix): {gpu_type}")

                valid_zones = self.ZONE_DATA.get('gpu', {}).get(gpu_short, {})

                if valid_zones and zone not in valid_zones:
                    warnings.append(
                        f"GPU {gpu_type} on {node.metadata.name} in zone {zone} "
                        f"not in validated zones for {gpu_short}"
                    )
                    self.logger.warning(warnings[-1])

        if warnings:
            return False, "; ".join(warnings)
        else:
            return True, "All accelerators in validated zones"

    def get_zone_data(self) -> Dict:
        """Return zone compatibility data for GCP."""
        return self.ZONE_DATA
