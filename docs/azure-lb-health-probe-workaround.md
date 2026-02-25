# Workaround: Azure Load Balancer Health Probe for Istio Gateway

## Problem

When deploying KServe with Istio Gateway API on AKS, external traffic to the inference gateway on port 80 times out, even though the gateway pod is running and works fine from inside the cluster.

Port 15021 (Istio health port) works externally, but port 80 does not.

## Root Cause

AKS automatically creates an **HTTP health probe** for LoadBalancer service ports that have `appProtocol: http` set. The Istio Gateway controller sets `appProtocol: http` on port 80 by default.

The HTTP health probe sends `GET /` to the nodePort backing port 80. Since no HTTPRoute matches `/`, Istio returns **404**. The Azure Load Balancer treats this as unhealthy and **stops forwarding all traffic** to port 80.

Port 15021 works because its health probe uses **TCP** (just checks if the port is open).

```text
Azure LB health probe → HTTP GET / → nodePort → Istio port 80 → 404 → backend marked unhealthy → all traffic dropped
```

## Why deploying an HTTPRoute doesn't fix it

Deploying an HTTPRoute for your model (e.g., `/llm-inference/qwen2-7b-instruct/...`) does not fix this because the health probe hits `/`, not your model path. Unless you have a route that explicitly matches `/` and returns 200, the probe will continue to fail.

## Fix

Annotate the `inference-gateway-istio` service to use a **TCP health probe** for the affected port instead of HTTP.

> **Note:** The port number in the annotation (`port_80`) must match the Gateway listener port. Port 80 is used here because that is what `setup-gateway.sh` configures in the Gateway's `listeners` spec. If your Gateway uses a different port, update the annotation key accordingly (e.g., `port_8080_health-probe_protocol`).

```bash
kubectl annotate svc inference-gateway-istio -n opendatahub \
  "service.beta.kubernetes.io/port_80_health-probe_protocol=tcp" \
  --overwrite
```

This annotation is applied automatically on AKS when using `setup-gateway.sh`. The manual command above is only needed if you recreate the Gateway without re-running the setup script.

### Verify the probe changed

```bash
# Find the MC resource group
NODE_RG=$(az aks show --resource-group <rg> --name <cluster> --query nodeResourceGroup -o tsv)

# Check probes
az network lb probe list --resource-group "$NODE_RG" --lb-name kubernetes -o table
```

The port 80 probe should now show `Protocol: Tcp` instead of `Http`.

## How to diagnose this issue

1. Verify the gateway works from inside the cluster (bypasses Azure LB):
   ```bash
   kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl \
     -- curl -s -o /dev/null -w "HTTP %{http_code}" \
     http://inference-gateway-istio.opendatahub.svc.cluster.local:80/
   ```
   If this returns 404 but external access times out, the LB health probe is the issue.

2. Check the Azure LB health probe configuration:
   ```bash
   NODE_RG=$(az aks show --resource-group <rg> --name <cluster> --query nodeResourceGroup -o tsv)
   az network lb probe list --resource-group "$NODE_RG" --lb-name kubernetes -o table
   ```
   If the port 80 probe shows `Protocol: Http` and `RequestPath: /`, that confirms the problem.

   > **Note:** If the `inference-gateway-istio` service is annotated with `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`, use `--lb-name kubernetes-internal` instead.

## Notes

- This is an AKS-specific issue. AWS and GCP load balancers default to TCP health checks.
- On AKS clusters v1.24+, `spec.ports.appProtocol` is used as the health probe protocol with `/` as the default request path. Since the Istio Gateway controller sets `appProtocol: http` on port 80, AKS creates an HTTP probe by default.
- The annotation `service.beta.kubernetes.io/port_80_health-probe_protocol` is a per-port override. The generic `service.beta.kubernetes.io/azure-load-balancer-health-probe-protocol` applies to all ports but may not take effect if the gateway controller reconciles the service.
- The Istio gateway service is managed by the Gateway controller and has no annotations by default.

## References

- [Configure a Public Standard Load Balancer in AKS](https://learn.microsoft.com/en-us/azure/aks/configure-load-balancer-standard) — Microsoft documentation on per-port health probe annotation overrides and default probe behavior.
- [Troubleshoot AKS Health Probe Mode](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/availability-performance/cluster-service-health-probe-mode-issues) — Troubleshooting guide for health probe issues.
