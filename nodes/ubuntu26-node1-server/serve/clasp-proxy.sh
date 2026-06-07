#!/bin/bash
# Deploy CLASP proxy alongside a vLLM server.
# CLASP translates Anthropic /v1/messages → OpenAI /v1/chat/completions.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/serve/clasp-proxy.sh [VLLM_PORT] [CLASP_PORT]
#
# Default: vLLM on :8000, CLASP on :8080

set -euo pipefail

VLLM_PORT="${1:-8000}"
CLASP_PORT="${2:-8080}"
CLASP_IMAGE="ghcr.io/jedarden/clasp:latest"
_DEFAULT_NAME="clasp-proxy-${CLASP_PORT}"
CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-$_DEFAULT_NAME}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Pre-flight ──
preflight() {
    log "=== CLASP Proxy Deployment ==="

    if ! docker info &>/dev/null; then
        echo "ERROR: Docker not accessible." >&2; exit 1
    fi

    # Check vLLM is running
    if ! curl -s --max-time 5 "http://localhost:$VLLM_PORT/health" -o /dev/null 2>/dev/null; then
        echo "ERROR: vLLM server not reachable at http://localhost:$VLLM_PORT" >&2
        echo "Start the inference server first." >&2
        exit 1
    fi
    log "  vLLM backend: OK (:$VLLM_PORT)"

    # Pull CLASP image if needed
    if ! docker image inspect "$CLASP_IMAGE" &>/dev/null; then
        log "  Pulling $CLASP_IMAGE..."
        docker pull "$CLASP_IMAGE"
    fi
    log "  CLASP image: OK"

    # Clean up existing
    local existing
    existing=$(docker ps -a -q --filter "name=$CONTAINER_NAME" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Removing existing container $CONTAINER_NAME..."
        docker rm -f "$existing" 2>/dev/null || true
    fi
    existing=$(docker ps -a -q --filter "publish=$CLASP_PORT" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Removing existing container on port $CLASP_PORT..."
        docker rm -f "$existing" 2>/dev/null || true
    fi
}

# ── Start CLASP ──
start_clasp() {
    log ""
    log "=== Starting CLASP proxy ==="
    log "  Container : $CONTAINER_NAME"
    log "  Backend   : http://host.docker.internal:$VLLM_PORT/v1"
    log "  Listen    : $CLASP_PORT"

    docker run --rm -d \
        --name "$CONTAINER_NAME" \
        --add-host "host.docker.internal:host-gateway" \
        -p "$CLASP_PORT:8080" \
        -e "PROVIDER=custom" \
        -e "CUSTOM_BASE_URL=http://host.docker.internal:$VLLM_PORT/v1" \
        -e "CUSTOM_API_KEY=EMPTY" \
        -e "CLASP_MODEL=deepseek-v4-flash" \
        -e "CLASP_MODEL_OPUS=deepseek-v4-flash" \
        -e "CLASP_MODEL_SONNET=deepseek-v4-flash" \
        -e "CLASP_MODEL_HAIKU=deepseek-v4-flash" \
        "$CLASP_IMAGE" \
        -proxy-only -port 8080

    log "  Container started."
}

# ── Wait for CLASP ──
wait_clasp() {
    log ""
    log "=== Waiting for CLASP to be ready ==="

    for attempt in $(seq 1 30); do
        if curl -s --max-time 3 "http://localhost:$CLASP_PORT/health" -o /dev/null 2>/dev/null; then
            log "  CLASP ready (${attempt}x2s)."
            return 0
        fi
        sleep 2
    done
    log "  ERROR: CLASP did not become ready."
    return 1
}

# ── Smoke test ──
smoke_test() {
    log ""
    log "=== Smoke test (Anthropic /v1/messages) ==="

    local http_code
    http_code=$(curl -s --max-time 60 -o /dev/null -w '%{http_code}' \
        -X POST "http://localhost:$CLASP_PORT/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: dummy" \
        -d '{"model":"deepseek-v4-flash","max_tokens":32,
             "messages":[{"role":"user","content":"Reply with exactly: PROXY_OK"}]}' \
        2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        log "  PASS: Anthropic endpoint working (HTTP 200)"
    else
        log "  FAIL: HTTP $http_code"
        docker logs "$CONTAINER_NAME" --tail 10 2>&1 | while IFS= read -r line; do
            log "    | $line"
        done
        return 1
    fi
}

# ── Print status ──
print_status() {
    log ""
    log "============================================"
    log "  CLASP Proxy — READY"
    log "============================================"
    log ""
    log "Anthropic endpoint:"
    log "  http://localhost:$CLASP_PORT/v1/messages"
    log ""
    log "Claude Code config:"
    log "  export ANTHROPIC_BASE_URL=http://localhost:$CLASP_PORT"
    log "  export ANTHROPIC_API_KEY=dummy"
    log ""
    log "Stop:  docker stop $CONTAINER_NAME"
}

# ── Main ──
main() {
    preflight
    start_clasp
    wait_clasp || { log "CLASP startup failed."; exit 1; }
    smoke_test || { log "Smoke test failed."; exit 1; }
    print_status
}

main
