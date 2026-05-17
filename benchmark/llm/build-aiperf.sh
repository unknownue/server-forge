#!/bin/bash
# Build AIPerf Docker image from local submodule.
#
# Usage:
#   bash benchmark/llm/build-aiperf.sh
#
# Uses the env-builder stage (python:3.13-slim-bookworm, public image)
# which contains a complete aiperf installation. The NGC distroless-based
# runtime stage is skipped to avoid NGC authentication requirements.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AIPERF_DIR="$REPO_ROOT/submodules/aiperf"
DOCKERFILE="$AIPERF_DIR/Dockerfile"
IMAGE_NAME="aiperf:latest"

if [[ ! -f "$DOCKERFILE" ]]; then
    echo "ERROR: Dockerfile not found at $DOCKERFILE" >&2
    echo "Run: git submodule update --init --recursive" >&2
    exit 1
fi

echo "=== Building AIPerf Docker Image ==="
echo "  Source : $AIPERF_DIR"
echo "  Target : env-builder (python:3.13-slim-bookworm)"
echo "  Tag    : $IMAGE_NAME"
echo ""

docker build \
    --target env-builder \
    -t "$IMAGE_NAME" \
    -f "$DOCKERFILE" \
    "$AIPERF_DIR"

echo ""
echo "=== Done ==="
echo "Image: $IMAGE_NAME"
docker image ls "$IMAGE_NAME"
