# Monitoring on CoreWeave (CKS)

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

## Enable Monitoring in KServe

By default, monitoring is disabled. Enable it:

```bash
kubectl set env deployment/kserve-controller-manager \
  -n opendatahub \
  LLMISVC_MONITORING_DISABLED=false
```

KServe automatically creates `PodMonitor` resources for vLLM pods when LLMInferenceService is deployed.

## Verify

```bash
# Check PodMonitors created by KServe
kubectl get podmonitors -n <llmisvc-namespace>

# Check targets in Prometheus
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090/targets
```

## Access Grafana

```bash
# Port forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Get password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

Open http://localhost:3000 (user: admin)
