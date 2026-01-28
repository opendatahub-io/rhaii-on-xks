#!/bin/bash
# Fix for sail-operator infinite reconciliation loop on vanilla Kubernetes
#
# Problem: The sail-operator watches MutatingWebhookConfiguration but doesn't
# filter out caBundle changes. When istiod injects the CA certificate, it triggers
# a reconcile loop.
#
# Workaround: Add sailoperator.io/ignore annotation to the webhook.

set -e

NAMESPACE="${1:-istio-system}"
WEBHOOK_NAME="istio-sidecar-injector"
MAX_WAIT=120

echo "[fix-webhook-loop] Waiting for MutatingWebhookConfiguration ${WEBHOOK_NAME}..."

# Wait for webhook to exist
waited=0
while ! kubectl get mutatingwebhookconfiguration ${WEBHOOK_NAME} &>/dev/null; do
  if [ $waited -ge $MAX_WAIT ]; then
    echo "[fix-webhook-loop] WARNING: Timeout waiting for ${WEBHOOK_NAME}"
    echo "  Run manually: kubectl annotate mutatingwebhookconfiguration ${WEBHOOK_NAME} sailoperator.io/ignore=true"
    exit 0
  fi
  sleep 5
  waited=$((waited + 5))
done

echo "[fix-webhook-loop] Found ${WEBHOOK_NAME}, applying annotation..."
kubectl annotate mutatingwebhookconfiguration ${WEBHOOK_NAME} sailoperator.io/ignore=true --overwrite

echo "[fix-webhook-loop] Done. Reconciliation loop workaround applied."
