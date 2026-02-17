#!/usr/bin/env python3
"""
Unit tests for cloud provider abstraction.

Tests Azure and GCP provider detection, instance type validation,
and accelerator validation.
"""

import unittest
from unittest.mock import MagicMock, patch
from cloud_providers import BaseCloudProvider, AzureProvider, GCPProvider


class TestAzureProvider(unittest.TestCase):
    """Test Azure AKS provider implementation."""

    def setUp(self):
        """Set up mock Kubernetes client and logger."""
        self.mock_k8s = MagicMock()
        self.mock_logger = MagicMock()
        self.provider = AzureProvider(self.mock_k8s, self.mock_logger)

    def test_detect_azure_cluster_label(self):
        """Test detection via kubernetes.azure.com/cluster label."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {"kubernetes.azure.com/cluster": "test-cluster"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        result = self.provider.detect()
        self.assertTrue(result)

    def test_detect_no_azure_labels(self):
        """Test detection fails when no Azure labels present."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {"some.other.label": "value"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        result = self.provider.detect()
        self.assertFalse(result)

    def test_validate_supported_instance_type(self):
        """Test validation succeeds with supported Azure VM type."""
        mock_node = MagicMock()
        mock_node.metadata.name = "node-1"
        mock_node.metadata.labels = {
            "node.kubernetes.io/instance-type": "Standard_NC24ads_A100_v4"
        }

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_instance_types()
        self.assertTrue(success)
        self.assertIn("Standard_NC24ads_A100_v4", message)

    def test_validate_unsupported_instance_type(self):
        """Test validation fails with unsupported Azure VM type."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {
            "node.kubernetes.io/instance-type": "Standard_D4s_v3"
        }

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_instance_types()
        self.assertFalse(success)
        self.assertIn("No supported", message)

    def test_validate_gpu_available(self):
        """Test GPU validation succeeds when GPUs are available."""
        mock_node = MagicMock()
        mock_node.metadata.name = "node-1"
        mock_node.metadata.labels = {"nvidia.com/gpu.present": "true"}
        mock_node.status.allocatable = {"nvidia.com/gpu": "4"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_accelerators()
        self.assertTrue(success)
        self.assertIn("GPU available", message)
        self.assertIn("node-1", message)

    def test_validate_no_gpu(self):
        """Test GPU validation fails when no GPUs available."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {}
        mock_node.status.allocatable = {}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_accelerators()
        self.assertFalse(success)
        self.assertIn("No GPUs", message)


class TestGCPProvider(unittest.TestCase):
    """Test Google Cloud GKE provider implementation."""

    def setUp(self):
        """Set up mock Kubernetes client and logger."""
        self.mock_k8s = MagicMock()
        self.mock_logger = MagicMock()
        self.provider = GCPProvider(self.mock_k8s, self.mock_logger)

    def test_detect_gke_nodepool_label(self):
        """Test detection via cloud.google.com/gke-nodepool label."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {"cloud.google.com/gke-nodepool": "default-pool"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        result = self.provider.detect()
        self.assertTrue(result)

    def test_detect_gke_os_label(self):
        """Test detection via cloud.google.com/gke-os-distribution label."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {"cloud.google.com/gke-os-distribution": "cos"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        result = self.provider.detect()
        self.assertTrue(result)

    def test_detect_no_gke_labels(self):
        """Test detection fails when no GKE labels present."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {"kubernetes.io/hostname": "node-1"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        result = self.provider.detect()
        self.assertFalse(result)

    def test_validate_tpu_machine_type(self):
        """Test validation succeeds with TPU machine type."""
        mock_node = MagicMock()
        mock_node.metadata.name = "tpu-node-1"
        mock_node.metadata.labels = {
            "node.kubernetes.io/instance-type": "ct6e-standard-4t"
        }

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_instance_types()
        self.assertTrue(success)
        self.assertIn("ct6e-standard-4t", message)

    def test_validate_gpu_machine_type(self):
        """Test validation succeeds with GPU machine type."""
        mock_node = MagicMock()
        mock_node.metadata.name = "gpu-node-1"
        mock_node.metadata.labels = {
            "node.kubernetes.io/instance-type": "n1-standard-4"
        }

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_instance_types()
        self.assertTrue(success)
        self.assertIn("n1-standard-4", message)

    def test_validate_unsupported_machine_type(self):
        """Test validation fails with unsupported machine type."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {
            "node.kubernetes.io/instance-type": "e2-standard-4"
        }

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_instance_types()
        self.assertFalse(success)
        self.assertIn("No supported", message)

    def test_validate_tpu_available(self):
        """Test TPU validation succeeds when TPUs are available."""
        mock_node = MagicMock()
        mock_node.metadata.name = "tpu-node-1"
        mock_node.metadata.labels = {
            "cloud.google.com/gke-tpu-accelerator": "v6e-slice",
            "cloud.google.com/gke-tpu-topology": "2x2"
        }
        mock_node.status.allocatable = {"google.com/tpu": "4"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_accelerators()
        self.assertTrue(success)
        self.assertIn("TPU", message)
        self.assertIn("v6e-slice", message)
        self.assertIn("2x2", message)

    def test_validate_gpu_available(self):
        """Test GPU validation succeeds when GPUs are available."""
        mock_node = MagicMock()
        mock_node.metadata.name = "gpu-node-1"
        mock_node.metadata.labels = {
            "cloud.google.com/gke-accelerator": "nvidia-tesla-t4"
        }
        mock_node.status.allocatable = {"nvidia.com/gpu": "1"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_accelerators()
        self.assertTrue(success)
        self.assertIn("GPU", message)
        self.assertIn("nvidia-tesla-t4", message)

    def test_validate_no_accelerators(self):
        """Test accelerator validation fails when none available."""
        mock_node = MagicMock()
        mock_node.metadata.labels = {}
        mock_node.status.allocatable = {}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_accelerators()
        self.assertFalse(success)
        self.assertIn("No accelerators", message)

    def test_zone_compatibility_valid_tpu_zone(self):
        """Test zone compatibility succeeds for valid TPU zone."""
        mock_node = MagicMock()
        mock_node.metadata.name = "tpu-node-1"
        mock_node.metadata.labels = {
            "cloud.google.com/gke-tpu-accelerator": "v6e-slice",
            "topology.kubernetes.io/zone": "us-east5-a"
        }
        mock_node.status.allocatable = {"google.com/tpu": "4"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_zone_compatibility()
        self.assertTrue(success)
        self.assertIn("validated zones", message)

    def test_zone_compatibility_invalid_tpu_zone(self):
        """Test zone compatibility warns for invalid TPU zone."""
        mock_node = MagicMock()
        mock_node.metadata.name = "tpu-node-1"
        mock_node.metadata.labels = {
            "cloud.google.com/gke-tpu-accelerator": "v6e-slice",
            "topology.kubernetes.io/zone": "us-west99-z"  # Invalid zone
        }
        mock_node.status.allocatable = {"google.com/tpu": "4"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_zone_compatibility()
        self.assertFalse(success)
        self.assertIn("not in validated zones", message)

    def test_zone_compatibility_valid_gpu_zone(self):
        """Test zone compatibility succeeds for valid GPU zone."""
        mock_node = MagicMock()
        mock_node.metadata.name = "gpu-node-1"
        mock_node.metadata.labels = {
            "cloud.google.com/gke-accelerator": "nvidia-tesla-t4",
            "topology.kubernetes.io/zone": "us-central1-a"
        }
        mock_node.status.allocatable = {"nvidia.com/gpu": "1"}

        mock_nodes = MagicMock()
        mock_nodes.items = [mock_node]
        self.mock_k8s.CoreV1Api().list_node.return_value = mock_nodes

        success, message = self.provider.validate_zone_compatibility()
        self.assertTrue(success)
        self.assertIn("validated zones", message)

    def test_get_zone_data(self):
        """Test zone data retrieval."""
        zone_data = self.provider.get_zone_data()

        # Verify structure
        self.assertIn('tpu', zone_data)
        self.assertIn('gpu', zone_data)

        # Verify TPU data
        self.assertIn('v6e', zone_data['tpu'])
        self.assertIn('us-east5-a', zone_data['tpu']['v6e'])

        # Verify GPU data
        self.assertIn('t4', zone_data['gpu'])
        self.assertIn('us-central1-a', zone_data['gpu']['t4'])


class TestBaseCloudProvider(unittest.TestCase):
    """Test abstract base class contract."""

    def test_cannot_instantiate_abstract_class(self):
        """Test that BaseCloudProvider cannot be instantiated directly."""
        mock_k8s = MagicMock()
        mock_logger = MagicMock()

        with self.assertRaises(TypeError):
            BaseCloudProvider(mock_k8s, mock_logger)

    def test_concrete_class_implements_all_methods(self):
        """Test that concrete providers implement all required methods."""
        for provider_class in [AzureProvider, GCPProvider]:
            # Verify all abstract methods are implemented
            self.assertTrue(hasattr(provider_class, 'detect'))
            self.assertTrue(hasattr(provider_class, 'validate_instance_types'))
            self.assertTrue(hasattr(provider_class, 'validate_accelerators'))

            # Verify they are callable
            provider = provider_class(MagicMock(), MagicMock())
            self.assertTrue(callable(getattr(provider, 'detect')))
            self.assertTrue(callable(getattr(provider, 'validate_instance_types')))
            self.assertTrue(callable(getattr(provider, 'validate_accelerators')))


if __name__ == '__main__':
    unittest.main()
