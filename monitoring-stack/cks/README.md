# LLM-D Monitoring on CoreWeave (CKS)

## Prerequisites

| Prerequisite | How to Check |
|--------------|--------------|
| **Prometheus running** | Self-hosted (no managed option on CoreWeave) |
| **ServiceMonitor/PodMonitor CRDs** | `kubectl get crd servicemonitors.monitoring.coreos.com` |

## Install Prometheus (kube-prometheus-stack)

CoreWeave does not have a managed Prometheus service. Use self-hosted:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
```

CRDs are included automatically.

## Verify Prerequisites

```bash
# CRDs exist
kubectl get crd servicemonitors.monitoring.coreos.com
kubectl get crd podmonitors.monitoring.coreos.com

# Prometheus is running
kubectl get pods -n monitoring | grep prometheus
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

## Access Grafana (Optional)

```bash
# Port forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Get password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

Open http://localhost:3000 (user: admin)
