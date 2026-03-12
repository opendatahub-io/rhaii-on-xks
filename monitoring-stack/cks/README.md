# Monitoring on CoreWeave (CKS)

CoreWeave does not have a managed Prometheus service. You must deploy your own.

**Prerequisites:** KServe must be deployed first. See the [deployment guide](../../docs/deploying-llm-d-on-managed-kubernetes.md) if not yet completed.

## 1. Install Prometheus

Install kube-prometheus-stack with Helm:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
```

This automatically installs:
- Prometheus server
- ServiceMonitor/PodMonitor CRDs
- Grafana

**Verify installation:**

```bash
# Check CRDs
kubectl get crd servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com

# Check Prometheus is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
```

## 2. Enable Monitoring in KServe

By default, monitoring is disabled. Enable it:

```bash
# Using make (recommended)
make enable-monitoring

# Or manually
kubectl set env deployment/kserve-controller-manager \
  -n opendatahub \
  LLMISVC_MONITORING_DISABLED=false
```

When enabled, KServe automatically creates `PodMonitor` resources for vLLM pods.

## 3. Verify Monitoring Works

After deploying an LLMInferenceService:

```bash
# Check PodMonitors were created (replace with your namespace, e.g., llm-inference)
kubectl get podmonitors -n <llmisvc-namespace>

# Check Prometheus is scraping targets
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090/targets and look for vLLM endpoints
```

## 4. Access Dashboards

**Prometheus:**
```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
```
Open http://localhost:9090

**Grafana:**
```bash
# Port forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Get password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```
Open http://localhost:3000 (user: admin)
