#!/bin/bash
# Serve DeepSeek-V4.1-Flash (475 GiB checkpoint, TP4/EP4 + DSpark) on the node's
# 4x RTX 6000D (85 GB each), tuned for concurrent long-context programming work.
#
# Usage:
#   bash serve/dsv41-flash.sh [CTX] [SLOTS] [BIND_ADDRESS]
#
#   CTX    --context-length, per-request cap (default 620000)
#   SLOTS  --max-running-requests, concurrency (default 3)
#   BIND   host interface the API is published on (default 127.0.0.1).
#          Pass 0.0.0.0 to serve the LAN — see the security note below.
#
# Security: the API key is the only authentication, and this node runs no
# firewall (ufw and firewalld are both inactive). Publishing on 0.0.0.0 exposes
# the endpoint to everyone on the LAN, so treat state/api-key as a LAN secret.
#
# Verified presets (measured with benchmarks/matrix.py, 8192-token outputs):
#   620000 3   three concurrent long sessions  <- 3 x 620k = 1.86M of the
#              1,953,792-token KV pool; TTFT 24 min cold, decode 108 tok/s per
#              request / 323 tok/s aggregate, peak_client_overlap=3
#   524288 3   same shape with more slack (TTFT 16 min, 114 / 330 tok/s)
#   1048576 1  a single 1M-token request (TTFT 35 min, decode ~154 tok/s)
#
# Why these values are not upstream defaults:
#   * The 85 GB cards leave ~2.5 GB per GPU once the 74.70 GB of weights are
#     resident, so the device KV pool is capped at 1,953,792 tokens (a measured
#     1,743 B/token/rank). Three concurrent requests therefore top out near 647k
#     each no matter how the rest is configured. Raising --max-total-tokens does
#     not help: at 3000000 the pool still reported only 2,030,592.
#   * Upstream hard-codes the sparse indexer's score chunk at 1 GiB, and its own
#     comment says the transients run ~3x that. At 32 MiB, long prefills stop
#     failing on 6-135 MiB shortfalls against 1.0-1.24 GiB of fragmentation.
#   * chunked_prefill_size 2048 builds a [chunk, lc] bf16 score tensor worth
#     ~2 GB at 1M context; 256 cuts that 8x and is what actually makes 600k+
#     prefills fit.
#   * OFFLOAD_MODE=ram pins the 189 GiB Engram tables in locked DDR5 instead of
#     streaming them from a consumer-grade NVMe (7.1k IOPS @QD1, 140 us).
#   * --disable-fast-image-processor is set in the submodule's boot.py: every TP
#     rank probes Rust with `cargo --version --verbose`, and cargo here is a
#     rustup shim with no default toolchain, so on some starts one rank blocks
#     downloading one and the other three die with
#     "DistStoreError: Timed out after 601 seconds waiting for clients.
#     3/4 clients joined."
#
# The API binds 127.0.0.1:8010 and the key is in <submodule>/state/api-key.

set -euo pipefail

CTX="${1:-620000}"
SLOTS="${2:-3}"
BIND="${3:-127.0.0.1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DSV_DIR="$REPO_ROOT/submodules/deepseek-v4.1-flash-4x-rtx-pro-6000"
CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-dsv41-flash}"

# Device KV pool ceiling, measured on this node from the engine's own startup line
# (max_total_num_tokens) under this launcher's own settings: mem-fraction-static 0.95,
# chunked-prefill-size 256, max-total-tokens 2000000, context 620000, 3 request slots.
# Measured 1,953,792; a single-slot run reaches 1,999,872, so this is the conservative
# of the two. Raising max-total-tokens does not help: at 3000000 the pool still reported
# 2,030,592, i.e. the ceiling is set by VRAM, not by that flag.
POOL_MAX_TOKENS=1953792
# Per-request slack for the generated output that shares the same pool.
OUTPUT_RESERVE=4096

log() { echo "[$(date +%H:%M:%S)] $*"; }
# Errors go to stderr so the Service Hub can capture the failure reason.
log_err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

# ── Pre-flight ──
if ! docker info >/dev/null 2>&1; then
    log_err "Docker not accessible."
    exit 1
fi

if [[ ! -f "$DSV_DIR/compose.yaml" ]]; then
    log_err "Compose project not found at $DSV_DIR"
    exit 1
fi

needed=$(( SLOTS * (CTX + OUTPUT_RESERVE) ))
if (( needed > POOL_MAX_TOKENS )); then
    log_err "${SLOTS} x ${CTX} needs ${needed} tokens but the KV pool caps at ${POOL_MAX_TOKENS}."
    log_err "These requests will queue rather than run concurrently; lower CTX or SLOTS."
    exit 1
fi

if [[ ! -f "$DSV_DIR/state/api-key" ]]; then
    log_err "Missing $DSV_DIR/state/api-key — run the stack once to generate it."
    exit 1
fi

log "DeepSeek-V4.1-Flash: CTX=$CTX SLOTS=$SLOTS container=$CONTAINER_NAME bind=$BIND"
log "pool budget: ${needed}/${POOL_MAX_TOKENS} tokens ($(( needed * 100 / POOL_MAX_TOKENS ))%)"

if [[ "$BIND" != "127.0.0.1" ]]; then
    lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    if [[ -n "$lan_ip" ]]; then
        log "LAN endpoint: http://${lan_ip}:8010/v1  (clients: baseURL + header 'Authorization: Bearer <key>')"
        log "NOTE: this address is a DHCP lease and can change; prefer the mDNS name"
        log "      $(hostname).lan, or reserve a static lease on the router."
    fi
fi

# ── Configuration ──
# Exported so they win over the submodule's .env (shell beats .env in Compose).
export SERVICE_HUB_CONTAINER_NAME="$CONTAINER_NAME"
export CONTEXT_LENGTH="$CTX"
export MAX_RUNNING_REQUESTS="$SLOTS"
export MAX_TOTAL_TOKENS=2000000          # SGLang clamps this to the POOL_MAX_TOKENS ceiling above
export CHUNKED_PREFILL_SIZE=256
export SGLANG_INDEXER_SCORE_BUDGET_BYTES=33554432
export MEMORY_FRACTION=0.95
export OFFLOAD_MODE=ram
export NCCL_P2P_DISABLE=1
export BIND_ADDRESS="$BIND"

cd "$DSV_DIR"

# Tear down this compose project first. The Hub's stop phase only targets the
# container names listed in profiles' stop_containers, so anything this project
# created under a different name (e.g. before container_name was pinned) would
# otherwise still be holding VRAM when the check below runs.
log "Tearing down any previous stack from this compose project..."
docker compose down --timeout 30 >/dev/null 2>&1 || true

# Now this only catches leftovers from *other* profiles.
free_mib=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -n | tail -1)
if (( free_mib > 4096 )); then
    log_err "A GPU still holds ${free_mib} MiB after teardown; another service did not exit."
    log_err "Check: docker ps -a"
    exit 1
fi

log "Starting (model load takes ~4-5 min; smoke test runs before it reports ready)..."
if ! docker compose up -d 2>&1 | tail -3 >&2; then
    log_err "docker compose up failed."
    exit 1
fi

# ── Wait for boot.py's own acceptance test to pass ──
# "healthy" alone is not enough: the container healthcheck only probes /health,
# which answers before smoke() has finished.
deadline=$(( $(date +%s) + 540 ))
while (( $(date +%s) < deadline )); do
    if docker compose logs 2>/dev/null | grep -q "Ready: authenticated API"; then
        if [[ "$BIND" == "127.0.0.1" ]]; then
            log "Ready. API on http://127.0.0.1:8010 (localhost only), key at state/api-key."
        else
            # Say where clients should actually connect, not just the wildcard bind.
            log "Ready. API published on ${BIND}:8010 — clients use http://${lan_ip:-<this-host>}:8010/v1"
            log "       The API key at state/api-key is the only authentication, and this node"
            log "       runs no firewall, so anyone on the LAN with that key can use the endpoint."
        fi
        log "First request on a cold prefix pays the full prefill; later requests"
        log "sharing that prefix hit the radix cache (measured 0.7 s at 600k)."
        exit 0
    fi
    if ! docker compose ps --format '{{.Status}}' 2>/dev/null | grep -q "^Up"; then
        log_err "Container exited during startup:"
        docker compose logs --tail 25 2>&1 | grep -vE "^\s*File |^\s*\^|^\s*~" >&2 || true
        exit 1
    fi
    sleep 10
done

log_err "Timed out waiting for the startup acceptance test; inspect: cd $DSV_DIR && docker compose logs"
exit 1
