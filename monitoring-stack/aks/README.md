# LLM-D Monitoring on AKS

## Prerequisites

| Prerequisite | How to Check |
|--------------|--------------|
| **Prometheus running** | See options below |
| **ServiceMonitor/PodMonitor CRDs** | `kubectl get crd servicemonitors.monitoring.coreos.com` |

## Prometheus Options

Choose one:

### Option 1: Self-hosted kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
```

CRDs are included automatically.

### Option 2: Azure Managed Prometheus

1. Enable in Azure Portal: AKS cluster → Monitoring → Enable Managed Prometheus
2. Install CRDs separately:
   ```bash
   helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds
   ```

## Verify Prerequisites

```bash
# CRDs exist
kubectl get crd servicemonitors.monitoring.coreos.com
kubectl get crd podmonitors.monitoring.coreos.com

# Prometheus is running (self-hosted)
kubectl get pods -n monitoring | grep prometheus

# Or Azure Managed Prometheus
kubectl get pods -n kube-system | grep ama-metrics
```

## Enable Monitoring in llm-d

```yaml
# llm-d values.yaml
inferenceExtension:
  monitoring:
    prometheus:
      enabled: true

prefill:
  monitoring:
    podmonitor:
      enabled: true

decode:
  monitoring:
    podmonitor:
      enabled: true
```

The helm chart creates ServiceMonitors/PodMonitors automatically.

## Verify

```bash
kubectl get servicemonitors,podmonitors -n <llm-d-namespace>
```
