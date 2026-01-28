# LLM-D Monitoring Stack (Optional)

## When is Monitoring Needed?

| Use Case | Monitoring Required? |
|----------|---------------------|
| Basic inference (vLLM + Gateway) | **No** |
| Grafana dashboards/visualization | **Yes** |
| Workload Variant Autoscaler (WVA) | **Yes** - hard requirement |

**Monitoring is disabled by default.** Only set it up if you need autoscaling or dashboards.

## What llm-d Needs (if enabled)

| Prerequisite | Why |
|--------------|-----|
| **Prometheus running** | To scrape and store metrics |
| **ServiceMonitor/PodMonitor CRDs** | So llm-d helm chart can create monitors |

Any Prometheus deployment works - self-hosted, Azure Managed, GCP Managed, or other options.

## What llm-d Helm Chart Does Automatically

When you enable monitoring in llm-d values, the helm chart creates:
- **ServiceMonitor** for EPP (scrapes `/metrics`)
- **PodMonitor** for vLLM prefill/decode pods

```yaml
# llm-d values.yaml
inferenceExtension:
  monitoring:
    prometheus:
      enabled: true   # Creates ServiceMonitor for EPP

prefill:
  monitoring:
    podmonitor:
      enabled: true   # Creates PodMonitor for vLLM prefill

decode:
  monitoring:
    podmonitor:
      enabled: true   # Creates PodMonitor for vLLM decode
```

**Users do NOT create ServiceMonitors manually.**

## Platform Guides

| Platform | Guide |
|----------|-------|
| **AKS** | [aks/](./aks/) |
| **CoreWeave (CKS)** | [cks/](./cks/) |

## Verify Monitoring is Working

```bash
# Check ServiceMonitors/PodMonitors were created
kubectl get servicemonitors,podmonitors -n <llm-d-namespace>

# Expected output:
# servicemonitor.monitoring.coreos.com/epp
# podmonitor.monitoring.coreos.com/vllm-prefill
# podmonitor.monitoring.coreos.com/vllm-decode
```

## Dashboards

Community dashboards available at:
- [llm-d Dashboards](https://github.com/llm-d/llm-d/tree/main/docs/monitoring/dashboards)
