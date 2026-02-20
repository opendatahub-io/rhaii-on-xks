# Monitoring Stack (Optional)

## When is Monitoring Needed?

| Use Case | Monitoring Required? |
|----------|---------------------|
| Basic inference (LLMInferenceService) | **No** |
| Grafana dashboards/visualization | **Yes** |
| Workload Variant Autoscaler (WVA) | **Yes** - hard requirement |

**Monitoring is disabled by default.** Only set it up if you need autoscaling or dashboards.

## Prerequisites

| Prerequisite | Why |
|--------------|-----|
| **Prometheus running** | To scrape and store metrics |
| **ServiceMonitor/PodMonitor CRDs** | So KServe can create monitors for vLLM pods |

Any Prometheus deployment works - self-hosted, Azure Managed, or other options.

## Enabling Monitoring with KServe

By default, monitoring is disabled in the odh-xks overlay. To enable it:

```bash
kubectl set env deployment/kserve-controller-manager \
  -n opendatahub \
  LLMISVC_MONITORING_DISABLED=false
```

When enabled, KServe automatically creates `PodMonitor` resources for vLLM pods.

## Platform Guides

| Platform | Guide |
|----------|-------|
| **AKS** | [aks/](./aks/) |
| **CoreWeave (CKS)** | [cks/](./cks/) |

## Verify Monitoring is Working

```bash
# Check PodMonitors were created by KServe
kubectl get podmonitors -n <llmisvc-namespace>

# Check Prometheus is scraping metrics
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090 and query: vllm_num_requests_running
```

## Dashboards

Community dashboards available at:
- [llm-d Dashboards](https://github.com/llm-d/llm-d/tree/main/docs/monitoring/grafana/dashboards)
