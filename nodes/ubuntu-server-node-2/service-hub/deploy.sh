#!/bin/bash
# Deploy the Service Hub — web UI for starting and stopping serve profiles.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/service-hub/deploy.sh [PORT]
#
# Default port: 9090
#
# Notes for this node:
#   - `uv` is not installed and cannot be fetched (bootstrap.pypa.io is
#     unreachable), so this uses the repo's local .pylibs tree instead. It is
#     created on first run from the Tsinghua PyPI mirror.
#   - The frontend is pre-built into ./static. Run the build step only after
#     changing anything under frontend/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PORT="${1:-9090}"
PYLIBS="$REPO_ROOT/.pylibs"
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "============================================"
log "  Service Hub — ubuntu-server-node-2"
log "  Port: $PORT"
log "============================================"

# ── Wait for Docker ──
# The systemd user unit cannot declare `After=docker.service`, because that is a
# *system* unit and is invisible to the user manager (`Requires=` on it fails
# with "Unit docker.service not found"). Waiting here covers the boot race
# instead: without it, a hub started before dockerd would show every profile as
# stopped and refuse switches with confusing errors.
if command -v docker >/dev/null 2>&1; then
    for i in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            log "Docker is ready."
            break
        fi
        if [[ $i -eq 30 ]]; then
            log "WARNING: Docker not responding after 30s — the UI will start,"
            log "         but profiles cannot be started until it is up."
        else
            [[ $i -eq 1 ]] && log "Waiting for Docker…"
            sleep 2
        fi
    done
else
    log "WARNING: docker not found on PATH — profile switching will not work."
fi

# ── Python dependencies into the local tree (idempotent) ──
if [[ ! -d "$PYLIBS/fastapi" ]]; then
    log "Installing Python dependencies into $PYLIBS (first run)…"
    python3 -m pip install --target="$PYLIBS" --break-system-packages -q \
        -i "$PIP_MIRROR" fastapi "uvicorn[standard]" pyyaml
    log "Dependencies installed."
else
    log "Python dependencies present."
fi

# ── Frontend build (only if missing or sources are newer) ──
if [[ ! -f "$SCRIPT_DIR/static/index.html" ]]; then
    log "Frontend not built; building now…"
    if ! command -v npm >/dev/null 2>&1; then
        log "WARNING: npm not found — API will run without a UI."
        log "         API docs remain available at http://localhost:$PORT/docs"
    else
        ( cd "$SCRIPT_DIR/frontend" \
          && { [[ -d node_modules ]] || npm install; } \
          && npm run build )
        log "Frontend built."
    fi
fi

# ── Port check ──
if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
    log "ERROR: port $PORT is already in use."
    log "Stop it first: bash $SCRIPT_DIR/stop.sh"
    exit 1
fi

log ""
log "  UI:       http://localhost:$PORT/"
log "  API docs: http://localhost:$PORT/docs"
log ""

cd "$SCRIPT_DIR"
export PYTHONPATH="$SCRIPT_DIR/src:$PYLIBS"
exec python3 -m uvicorn service_hub.server:app \
    --host 0.0.0.0 --port "$PORT" --log-level info