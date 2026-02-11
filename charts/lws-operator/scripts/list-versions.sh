#!/bin/bash
# List available LWS operator bundle versions
#
# Queries registry.redhat.io for all published LeaderWorkerSet
# Operator bundle tags and prints them sorted by version.
# Requires skopeo and authenticated access to registry.redhat.io.
#
# Usage: ./list-versions.sh
echo "Available bundle versions:"
skopeo list-tags docker://registry.redhat.io/leader-worker-set/lws-operator-bundle 2>/dev/null | \
    grep -oP '"[0-9]+\.[0-9]+[^"]*"' | tr -d '"' | grep -v sha256 | sort -V
