#!/bin/bash
# Build cc-relay Docker image using multi-stage build (no Go required on host).
#
# Usage:
#   bash nodes/unknownue-manjaro/cc-relay/build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
IMAGE_NAME="cc-relay:latest"

echo "=== Building cc-relay ==="
echo "  Context   : $REPO_ROOT/submodules/cc-relay"
echo "  Dockerfile: $SCRIPT_DIR/Dockerfile"
echo "  Tag       : $IMAGE_NAME"
echo ""

docker build \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$REPO_ROOT/submodules/cc-relay"

echo ""
echo "=== Done ==="
echo "Image: $IMAGE_NAME"
docker image ls "$IMAGE_NAME"
