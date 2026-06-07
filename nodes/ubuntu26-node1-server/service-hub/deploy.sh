#!/bin/bash
# Deploy the Service Hub — local service management gateway.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/service-hub/deploy.sh [PORT]
#
# Default port: 9090
# Requires: uv (https://docs.astral.sh/uv/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-9090}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "============================================"
log "  Service Hub — Local Service Management"
log "  Port: $PORT"
log "============================================"
log ""

# Check uv
if ! command -v uv &>/dev/null; then
    echo "ERROR: 'uv' not found. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    exit 1
fi

# Check if port is in use
if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
    log "WARNING: Port $PORT already in use."
    log "The service may fail to start. Stop the existing process first."
fi

log "Starting Service Hub..."
log "  API docs: http://localhost:$PORT/docs"
log ""

cd "$SCRIPT_DIR"
export PYTHONPATH=src
exec uv run uvicorn service_hub.server:app --host 0.0.0.0 --port "$PORT" --log-level info
