#!/bin/bash
# List available Sail operator bundle versions
echo "Available bundle versions (Red Hat):"
skopeo list-tags docker://registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle 2>/dev/null | \
    grep -oP '"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' | tr -d '"' | grep -v sha256 | sort -V
