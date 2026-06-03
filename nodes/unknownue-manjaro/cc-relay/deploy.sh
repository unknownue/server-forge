#!/bin/bash
# Deploy cc-relay container as a local Claude Code proxy.
#
# Usage:
#   bash nodes/unknownue-manjaro/cc-relay/deploy.sh
#
# Prerequisites:
#   - Build the image first: bash nodes/unknownue-manjaro/cc-relay/build.sh
#   - Set ANTHROPIC_API_KEY in environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="cc-relay:latest"
CONTAINER_NAME="cc-relay"

# ── Ensure image exists ──
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "ERROR: Image '$IMAGE' not found. Build it first:"
    echo "  bash $SCRIPT_DIR/build.sh"
    exit 1
fi

# ── Stop existing container ──
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo "=== Starting cc-relay ==="
echo "  Image  : $IMAGE"
echo "  Config : $SCRIPT_DIR/config.yaml"
echo "  API    : http://127.0.0.1:8787"
echo "  gRPC   : 127.0.0.1:9090"
echo "  Metrics: http://127.0.0.1:9100/metrics"
echo ""

docker run -d \
    --name "$CONTAINER_NAME" \
    --network=host \
    -v "$SCRIPT_DIR/config.yaml:/etc/cc-relay/config.yaml:ro" \
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
    "$IMAGE" \
    serve --config /etc/cc-relay/config.yaml

echo ""
echo "=== cc-relay started ==="
echo "  Logs: docker logs -f $CONTAINER_NAME"
echo ""
echo "Claude Code integration:"
echo "  export ANTHROPIC_BASE_URL=http://localhost:8787/v1"
echo "  export ANTHROPIC_API_KEY=not-needed"
