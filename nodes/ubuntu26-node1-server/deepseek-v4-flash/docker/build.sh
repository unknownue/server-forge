#!/bin/bash
# Build the dsv4-flash-acti-mtp Docker image.
# Estimated build time: 25-45 min (vLLM CUDA kernels compile).
#
# Usage:
#   bash nodes/ubuntu26-node1-server/deepseek-v4-flash/docker/build.sh [TAG]
#
# Default tag: dsv4-flash-acti-mtp:0.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:-dsv4-flash-acti-mtp:0.1.0}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "============================================"
log "  Building $TAG"
log "  Context: $SCRIPT_DIR"
log "============================================"
log ""

cd "$SCRIPT_DIR"

log "Starting docker build..."
docker build -t "$TAG" .

log ""
log "============================================"
log "  Build complete: $TAG"
log "============================================"
log ""
log "Verify:"
log "  docker image inspect $TAG"
log ""
log "Run:"
log "  bash $(dirname "$SCRIPT_DIR")/deploy.sh"
