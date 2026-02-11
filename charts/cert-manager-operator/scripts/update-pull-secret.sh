#!/bin/bash
# Update pull secret in the cluster
# Usage: ./update-pull-secret.sh [pull-secret-file]
# Examples:
#   ./update-pull-secret.sh ~/pull-secret.txt
#   ./update-pull-secret.sh  # uses system podman auth

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_SECRET_FILE="${1:-}"
NAMESPACES="cert-manager-operator cert-manager"
SECRET_NAME="redhat-pull-secret"

echo "=== Updating Pull Secret ==="

# Determine auth source
if [ -n "$PULL_SECRET_FILE" ]; then
  if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "ERROR: File not found: $PULL_SECRET_FILE"
    exit 1
  fi
  DOCKER_CONFIG_JSON=$(cat "$PULL_SECRET_FILE")
  echo "Using pull secret from: $PULL_SECRET_FILE"
elif [ -f ~/.config/containers/auth.json ]; then
  DOCKER_CONFIG_JSON=$(cat ~/.config/containers/auth.json)
  echo "Using podman auth: ~/.config/containers/auth.json"
elif [ -f "${XDG_RUNTIME_DIR}/containers/auth.json" ]; then
  DOCKER_CONFIG_JSON=$(cat "${XDG_RUNTIME_DIR}/containers/auth.json")
  echo "Using session podman auth: ${XDG_RUNTIME_DIR}/containers/auth.json"
elif [ -f ~/.docker/config.json ]; then
  DOCKER_CONFIG_JSON=$(cat ~/.docker/config.json)
  echo "Using docker auth: ~/.docker/config.json"
else
  echo "ERROR: No auth source found"
  echo "Options:"
  echo "  1. podman login registry.redhat.io"
  echo "  2. ./update-pull-secret.sh /path/to/pull-secret.txt"
  exit 1
fi

# Update the secret in each namespace
for ns in $NAMESPACES; do
  echo "Updating secret $SECRET_NAME in namespace $ns..."
  kubectl create secret docker-registry "$SECRET_NAME" \
    --namespace="$ns" \
    --docker-server=registry.redhat.io \
    --from-file=.dockerconfigjson=<(echo "$DOCKER_CONFIG_JSON") \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "=== Pull Secret Updated ==="
echo ""
echo "Pods using this secret will use it on next restart."
echo "To restart cert-manager pods: kubectl rollout restart deployment -n cert-manager --all"
