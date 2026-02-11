#!/bin/bash
# Collect debug info for cert-manager and LWS operator issues
# Output can be shared with Red Hat support

OUTPUT_DIR="${1:-/tmp/cert-manager-debug-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"

echo "Collecting debug info to: $OUTPUT_DIR"
echo ""

# Check kubeconfig
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster"; exit 1; }

echo "[1/8] Cluster info..."
kubectl cluster-info > "$OUTPUT_DIR/cluster-info.txt" 2>&1
kubectl version > "$OUTPUT_DIR/k8s-version.txt" 2>&1

echo "[2/8] cert-manager operator logs..."
kubectl logs -n cert-manager-operator -l name=cert-manager-operator --tail=500 > "$OUTPUT_DIR/operator-logs.txt" 2>&1

echo "[3/8] cert-manager controller logs..."
kubectl logs -n cert-manager -l app.kubernetes.io/component=controller --tail=500 > "$OUTPUT_DIR/controller-logs.txt" 2>&1
kubectl logs -n cert-manager -l app=cert-manager --tail=500 >> "$OUTPUT_DIR/controller-logs.txt" 2>&1

echo "[4/8] cert-manager webhook logs..."
kubectl logs -n cert-manager -l app.kubernetes.io/component=webhook --tail=500 > "$OUTPUT_DIR/webhook-logs.txt" 2>&1
kubectl logs -n cert-manager -l app=webhook --tail=500 >> "$OUTPUT_DIR/webhook-logs.txt" 2>&1

echo "[5/8] cert-manager cainjector logs..."
kubectl logs -n cert-manager -l app.kubernetes.io/component=cainjector --tail=500 > "$OUTPUT_DIR/cainjector-logs.txt" 2>&1

echo "[6/8] Certificates and Issuers..."
{
    echo "=== ClusterIssuers ==="
    kubectl get clusterissuers -o wide 2>&1
    echo ""
    kubectl describe clusterissuers 2>&1
    echo ""
    echo "=== Issuers (all namespaces) ==="
    kubectl get issuers -A -o wide 2>&1
    echo ""
    kubectl describe issuers -A 2>&1
    echo ""
    echo "=== Certificates (all namespaces) ==="
    kubectl get certificates -A -o wide 2>&1
    echo ""
    kubectl describe certificates -A 2>&1
    echo ""
    echo "=== CertificateRequests (all namespaces) ==="
    kubectl get certificaterequests -A -o wide 2>&1
} > "$OUTPUT_DIR/certificates-issuers.txt" 2>&1

echo "[7/8] CertManager CR and pods..."
{
    echo "=== CertManager CR ==="
    kubectl get certmanager cluster -o yaml 2>&1
    echo ""
    echo "=== cert-manager-operator pods ==="
    kubectl get pods -n cert-manager-operator -o wide 2>&1
    echo ""
    echo "=== cert-manager pods ==="
    kubectl get pods -n cert-manager -o wide 2>&1
    echo ""
    echo "=== cert-manager deployments ==="
    kubectl get deployments -n cert-manager -o wide 2>&1
} > "$OUTPUT_DIR/certmanager-status.txt" 2>&1

echo "[8/8] LWS operator info (if present)..."
{
    echo "=== LWS Operator pods ==="
    kubectl get pods -n openshift-lws-operator -o wide 2>&1
    echo ""
    echo "=== LWS Certificates ==="
    kubectl get certificates -n openshift-lws-operator -o wide 2>&1
    echo ""
    kubectl describe certificates -n openshift-lws-operator 2>&1
    echo ""
    echo "=== LWS Issuers ==="
    kubectl get issuers -n openshift-lws-operator -o wide 2>&1
    echo ""
    kubectl describe issuers -n openshift-lws-operator 2>&1
    echo ""
    echo "=== LWS Webhook configs ==="
    kubectl get mutatingwebhookconfiguration lws-mutating-webhook-configuration -o yaml 2>&1
    echo ""
    kubectl get validatingwebhookconfiguration lws-validating-webhook-configuration -o yaml 2>&1
    echo ""
    echo "=== LWS Secrets ==="
    kubectl get secrets -n openshift-lws-operator 2>&1
} > "$OUTPUT_DIR/lws-operator-info.txt" 2>&1

echo ""
echo "=== Debug info collected ==="
echo ""
ls -la "$OUTPUT_DIR"
echo ""
echo "To share: tar -czf cert-manager-debug.tar.gz -C $(dirname $OUTPUT_DIR) $(basename $OUTPUT_DIR)"
