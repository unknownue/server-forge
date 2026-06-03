#!/bin/bash
# Pull all Docker images required by benchmarks on this node.
# Run as: bash nodes/ubuntu26-node1-server/pull-images.sh

set -euo pipefail

IMAGES=(
    "vllm/vllm-openai:v0.20.2-cu129-ubuntu2404"
    "nvcr.io/nvidia/sglang:26.04-py3"
)

echo "=== Pulling Docker images ==="
for img in "${IMAGES[@]}"; do
    echo ""
    echo "Pulling $img ..."
    docker pull "$img"
done

echo ""
echo "=== Done ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" \
    "${IMAGES[@]%%:*}" 2>/dev/null || true
