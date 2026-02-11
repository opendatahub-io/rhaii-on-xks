#!/bin/bash
# List available Sail operator bundle versions
#
# Queries registry.redhat.io for all published Sail Operator bundle
# tags and prints them sorted by version. Requires skopeo and
# authenticated access to registry.redhat.io.
#
# Usage: ./list-versions.sh
echo "Available bundle versions (Red Hat):"
skopeo list-tags docker://registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle 2>/dev/null | \
    grep -oP '"[0-9]+\.[0-9]+\.[0-9]+[^"]*"' | tr -d '"' | grep -v sha256 | sort -V
