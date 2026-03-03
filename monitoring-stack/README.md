# Monitoring Stack (Optional)

## When is Monitoring Needed?

| Use Case | Monitoring Required? |
|----------|---------------------|
| Basic inference (LLMInferenceService) | **No** |
| Grafana dashboards/visualization | **Yes** |
| Workload Variant Autoscaler (WVA) | **Yes** - hard requirement |

**Monitoring is disabled by default.** Only set it up if you need autoscaling or dashboards.

## Prerequisites

Before setting up monitoring, ensure KServe and infrastructure are deployed:

| Prerequisite | How to Deploy | How to Verify |
|--------------|---------------|---------------|
| **KServe deployed** | `make deploy-kserve` | `kubectl get deployment kserve-controller-manager -n opendatahub` |
| **Infrastructure running** | `make deploy` | cert-manager, Istio, LWS operators deployed |

**Not deployed yet?** See:
- Quick start: Run `make deploy-all` from the [root directory](../)
- Full guide: [Deploying Red Hat AI Inference Server](../docs/deploying-llm-d-on-managed-kubernetes.md)

## Monitoring Prerequisites

| Prerequisite | Why |
|--------------|-----|
| **Prometheus running** | To scrape and store metrics |
| **ServiceMonitor/PodMonitor CRDs** | So KServe can create monitors for vLLM pods |

Any Prometheus deployment works - self-hosted, Azure Managed, or other options.

## Enabling Monitoring with KServe

By default, monitoring is disabled. The KServe Helm chart is generated from the `odh-xks` Kustomize overlay (from [red-hat-data-services/kserve](https://github.com/red-hat-data-services/kserve/tree/rhoai-3.4-ea.1/config/overlays/odh-xks) branch `rhoai-3.4-ea.1`), which sets `LLMISVC_MONITORING_DISABLED=true` via patch files. This gets baked into the chart at `charts/kserve/files/resources.yaml`. The Helm chart deploys the pre-rendered manifests from `resources.yaml`.

To enable monitoring after deployment:

```bash
# Using make (recommended)
make enable-monitoring

# Or manually
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
# Check PodMonitors were created by KServe (replace with your namespace, e.g., llm-inference)
kubectl get podmonitors -n <llmisvc-namespace>

# Check Prometheus is scraping metrics
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090 and query: vllm_num_requests_running
```

## Dashboards

Community dashboards available at:
- [llm-d Dashboards](https://github.com/llm-d/llm-d/tree/main/docs/monitoring/grafana/dashboards)
