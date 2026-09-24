#!/bin/bash
# Deploy the Caddy reverse proxy for Multica.
#
# Usage:
#   bash nodes/mac-mini-m4/caddy/deploy.sh
#
# Prerequisites:
#   - The multica stack must be running (it creates the multica-net network).
#   - A Docker Hub registry mirror should be configured, or caddy:2-alpine
#     cannot be pulled — Docker Hub is unreachable from this network. See
#     ../config/set-docker-mirror.sh.
#
# This starts only the proxy. Start the Multica stack with ../multica/deploy.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE="caddy:2-alpine"
NETWORK="multica-net"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon not reachable. Start Docker Desktop first." >&2
    exit 1
fi

# ── The upstream stack must exist first ─────────────────────────────────────
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    echo "ERROR: Docker network '${NETWORK}' not found." >&2
    echo "       It is created by the Multica stack. Start that first:" >&2
    echo "         bash ${SCRIPT_DIR}/../multica/deploy.sh" >&2
    exit 1
fi

# Warn if the upstreams are absent: Caddy would start but return 502 for every
# request, which is a confusing failure to debug from the browser alone.
for name in multica-backend multica-frontend; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
        warn "container '${name}' is not running — the proxy will answer 502."
        warn "start the Multica stack:  bash ${SCRIPT_DIR}/../multica/deploy.sh"
    fi
done

# ── Image ───────────────────────────────────────────────────────────────────
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Pulling ${IMAGE} (requires a working Docker Hub mirror — see ../config/set-docker-mirror.sh)"
    if ! docker pull "$IMAGE"; then
        echo "" >&2
        echo "ERROR: could not pull ${IMAGE}." >&2
        echo "  Docker Hub is not reachable from this network directly." >&2
        echo "  Configure a mirror, then retry:" >&2
        echo "    bash ${SCRIPT_DIR}/../config/set-docker-mirror.sh" >&2
        echo "    osascript -e 'quit app \"Docker\"' && sleep 3 && open -a Docker" >&2
        exit 1
    fi
else
    log "${IMAGE} already present locally"
fi

# ── Validate the Caddyfile before starting ──────────────────────────────────
# `caddy validate` catches syntax errors here, with a readable message, rather
# than as a restart loop visible only in `docker logs caddy`.
log "Validating Caddyfile..."
if ! docker run --rm -v "${SCRIPT_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
        "$IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    echo "ERROR: Caddyfile failed validation. Details:" >&2
    docker run --rm -v "${SCRIPT_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
        "$IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >&2 || true
    exit 1
fi
log "Caddyfile OK"

# ── Start ───────────────────────────────────────────────────────────────────
log "Starting Caddy..."
docker compose up -d --remove-orphans

sleep 2
if ! docker ps --format '{{.Names}}' | grep -qx caddy; then
    warn "caddy container is not running. Logs:"
    docker compose logs --tail 30 caddy
    exit 1
fi

# ── Smoke test ──────────────────────────────────────────────────────────────
# The Caddyfile uses a bare `:3000` address, so the LAN origin is not in it —
# read it from the multica .env, which is the single source of truth for the
# address browsers use.
MULTICA_ENV="${SCRIPT_DIR}/../multica/.env"
ORIGIN=""
if [[ -f "$MULTICA_ENV" ]]; then
    ORIGIN=$(sed -n 's/^FRONTEND_ORIGIN=//p' "$MULTICA_ENV" | tail -n 1)
fi
ORIGIN=${ORIGIN:-http://192.168.50.248:3000}
ORIGIN_HOST=${ORIGIN#http://}

# Two independent traps here, both of which produce a false failure:
#
#  1. Proxy env vars. If the host has http_proxy/https_proxy set (common with a
#     local Clash/Surge-style proxy), curl routes even a loopback request
#     through it, and the proxy answers 502 for a Docker-internal hostname.
#     `--noproxy '*'` disables that for this call only, leaving the caller's
#     shell environment untouched.
#
#  2. Hairpin routing. A Mac reaching its OWN LAN IP:port published by Docker
#     Desktop can stall, because the packet leaves and returns on the same
#     interface. localhost is the path that always works from this host; the
#     LAN address is verified from another machine, which is what the README
#     asks for.
smoke_ok=0
for url in "http://localhost:3000/health" "${ORIGIN}/health"; do
    if curl -sf --noproxy '*' --max-time 10 "$url" >/dev/null 2>&1; then
        log "✓ proxy is forwarding to the backend (${url})"
        smoke_ok=1
        break
    fi
done

if [[ "$smoke_ok" -eq 0 ]]; then
    warn "no healthy response through the proxy yet (tried localhost and ${ORIGIN})."
    warn "If the stack just started, wait a moment and retry."
    warn "Inspect with:  docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs -f caddy"
fi

cat <<EOF

=== Caddy ===
  LAN URL   : ${ORIGIN}
  Container : caddy  (network: ${NETWORK})
  Config    : ${SCRIPT_DIR}/Caddyfile

Verify WebSocket forwarding from a browser on another LAN machine:
  open ${ORIGIN}, then in DevTools → Network filter "ws".
  /ws must show 101 Switching Protocols. If it loops with
  "disconnected, reconnecting in 3s", see README.md (Troubleshooting).
EOF