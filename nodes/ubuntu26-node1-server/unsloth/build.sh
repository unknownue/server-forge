#!/bin/bash
# Build custom Unsloth Studio Docker image with pre-built frontend.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/unsloth/build.sh
#
# This produces an image that starts instantly because the frontend
# is already built — no bun/npm install at first container start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="unsloth-studio:latest"

echo "=== Building Custom Unsloth Image ==="
echo "  Dockerfile: $SCRIPT_DIR/Dockerfile"
echo "  Tag       : $IMAGE_NAME"
echo ""

docker build \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$SCRIPT_DIR"

echo ""
echo "=== Done ==="
echo "Image: $IMAGE_NAME"
docker image ls "$IMAGE_NAME"
