#!/bin/bash
# Serve MiMo-V2.6-Flash-RL (309B total / 15B active, MXFP4 experts + FP8 dense,
# 1M context, omni input) on the node's 4x RTX 6000D (SM120, 85 GB each, PCIe,
# no NVLink).
#
# Usage:
#   bash serve/mimo26-flash.sh [CTX] [SEQS] [BIND_ADDRESS]
#
#   CTX    --max-model-len, per-request context cap (default 1048576)
#   SEQS   --max-num-seqs, concurrent sequences (default 8)
#   BIND   host interface the API is published on (default 127.0.0.1).
#          Pass 0.0.0.0 to serve the LAN -- see the security note below.
#
# Security: vLLM's --api-key is the only authentication and this node runs no
# firewall (ufw and firewalld are both inactive). Publishing on 0.0.0.0 exposes
# the endpoint to everyone on the LAN, so treat the key file as a LAN secret.
#
# Why this launcher exists (and why it is not just the upstream serve.sh):
#   * Upstream's launcher is hard-coded to TP2 on 2x 96 GB cards. This node has
#     4x 85 GB, so the model must be sharded TP4 (178 GB / 4 = ~45 GB per card).
#   * Upstream runs docker in the foreground; the Service Hub expects a script
#     that starts the stack, waits for readiness, and exits.
#   * Kernel/compile caches are pointed at /data/cache/mimo26 (repo convention:
#     kernel caches live under /data/cache/<project>/, never inside the weights).
#
# Upstream recipe + measured evidence (2x RTX PRO 6000, SM120, PCIe, TP2):
#   https://huggingface.co/diffbot/MiMo-V2.6-Flash-RL-FP8KV-W4A8-2x-RTX-PRO-6000
#   Vendored read-only copy: /data/work/vendor/diffbot-mimo26-recipe
#   Its FP8-KV + Marlin W4A8 + custom prefill-attention stack is what makes this
#   model usable on SM120 at all: FA4 does not cover SM120, DeepGEMM refuses the
#   architecture (sglang#25877), and vLLM's stock bf16 KV pool is too small.
#
# Everything runs from the pinned official checkpoint; nothing here rewrites
# weights. The MXFP4 experts are the checkpoint's own storage format.

set -euo pipefail

CTX="${1:-1048576}"
SEQS="${2:-8}"
BIND="${3:-127.0.0.1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VENDOR_DIR="${MIMO26_VENDOR_DIR:-/data/work/vendor/diffbot-mimo26-recipe}"
RECIPE_DIR="$VENDOR_DIR/recipe"
MODEL_DIR="${MIMO26_MODEL_DIR:-/data/work/models/XiaomiMiMo/MiMo-V2.6-Flash-RL}"
CACHE_DIR="${MIMO26_CACHE_DIR:-/data/cache/mimo26}"
STATE_DIR="${MIMO26_STATE_DIR:-/data/work/mimo26/state}"
IMAGE="${MIMO26_IMAGE:-mimo-v26-omni:latest}"
CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-mimo26-flash}"
# Same port as the DeepSeek profile on purpose: only one 4-GPU model can run at a
# time, so LAN clients keep a single endpoint (http://<host>:8010/v1) and only the
# model name changes when the node is switched.
PORT="${MIMO26_PORT:-8010}"

# Parallelism. TP=EP=4 keeps one full copy of every expert shard's share per card
# and avoids expert-parallel all-to-all, which is the wrong trade on PCIe-only
# hosts. vLLM requires the draft TP to be 1 or the target TP, so the DFlash
# drafter follows the target TP (the upstream TP2 recipe used draft TP2).
TP="${MIMO26_TP:-4}"
DRAFT_TP="${MIMO26_DRAFT_TP:-$TP}"

# Memory knobs (see profile header for the VRAM budget arithmetic).
# UTIL 0.95 is the measured default: KV pool 10,877,194 tokens (34.76 GiB per
# card) versus 9,577,937 tokens at 0.90, and a 1M-token cold prefill still fits
# (peak 82,784 MiB of 85,651 MiB per card, no OOM). Decode speed is unchanged by
# this knob - the run-to-run spread (207-359 tok/s at 46K) tracks speculative
# acceptance, not memory. The engine reports the absolute ceiling as
# --kv-cache-memory=40607249408 (37.82 GiB, ~11.8M tokens) if the last ~3 GiB is
# wanted; that leaves ~1 GiB per card and is not the default.
UTIL="${MIMO26_UTIL:-0.95}"          # --gpu-memory-utilization
KV_OFFLOAD="${MIMO26_KV_OFFLOAD:-64}" # GiB of host RAM used as the CPU KV tier
KV_DTYPE="${MIMO26_KV_DTYPE:-fp8}"    # E4M3 KV for the DiffKV layers (upstream patch)
MAX_BATCHED="${MIMO26_MAX_BATCHED:-4096}"
SPEC_TOKENS="${MIMO26_SPEC_TOKENS:-3}"
TEXT_ONLY="${MIMO26_TEXT_ONLY:-0}"    # 1 = --language-model-only (skip encoders)
# Optional: pin the KV pool explicitly instead of a utilization target. The engine
# reports the "fully utilize gpu memory" value at startup (40,607,249,408 bytes =
# 37.82 GiB on this node); setting it leaves under 1 GiB per card of headroom.
KV_MEM="${MIMO26_KV_MEM:-}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
log_err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

# ── Pre-flight ──
if ! docker info >/dev/null 2>&1; then
    log_err "Docker not accessible."
    exit 1
fi

if [[ ! -f "$RECIPE_DIR/serve/serve.sh" ]]; then
    log_err "Vendored recipe not found at $VENDOR_DIR (expected recipe/serve/serve.sh)."
    exit 1
fi

if [[ ! -f "$MODEL_DIR/.revision" ]]; then
    log_err "Model not found or not pinned at $MODEL_DIR."
    log_err "Download it first: bash scripts/lib/download-model.sh \\"
    log_err "    XiaomiMiMo/MiMo-V2.6-Flash-RL 5711b268169967567844e1e560e8a3966da959b1 full"
    exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log_err "Image $IMAGE not found. Build it with:"
    log_err "    bash $RECIPE_DIR/docker/build.sh"
    exit 1
fi

if [[ "$CTX" -gt 1048576 ]]; then
    log_err "CTX=$CTX exceeds the checkpoint's max_position_embeddings=1048576."
    exit 1
fi

mkdir -p "$CACHE_DIR" "$STATE_DIR" "$RECIPE_DIR/kernels/attention/build-prefill_attn_v1.cu"

# ── API key ──
if [[ ! -f "$STATE_DIR/api-key" ]]; then
    head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40 > "$STATE_DIR/api-key"
    chmod 600 "$STATE_DIR/api-key"
    log "Generated a new API key at $STATE_DIR/api-key"
fi
API_KEY="$(cat "$STATE_DIR/api-key")"

log "MiMo-V2.6-Flash-RL: CTX=$CTX SEQS=$SEQS TP=$TP container=$CONTAINER_NAME bind=$BIND"
log "memory: $( [[ -n "$KV_MEM" ]] && echo "--kv-cache-memory=$KV_MEM" || echo "--gpu-memory-utilization=$UTIL" ) | max-num-batched-tokens=$MAX_BATCHED | kv-offload=${KV_OFFLOAD}GiB"
log "model=$MODEL_DIR"
log "vendor=$VENDOR_DIR cache=$CACHE_DIR"

if [[ "$BIND" != "127.0.0.1" ]]; then
    lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    if [[ -n "$lan_ip" ]]; then
        log "LAN endpoint: http://${lan_ip}:${PORT}/v1  (clients: baseURL + header 'Authorization: Bearer <key>')"
        log "NOTE: this address is a DHCP lease and can change; prefer the mDNS name"
        log "      $(hostname).lan, or reserve a static lease on the router."
    fi
fi

# ── Teardown of a previous instance ──
log "Tearing down any previous container named $CONTAINER_NAME..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

free_mib=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -n | tail -1)
if (( free_mib > 4096 )); then
    log_err "A GPU still holds ${free_mib} MiB; another service did not exit."
    log_err "Check: docker ps -a"
    exit 1
fi

# ── vLLM arguments ──
# The container uses host networking, so the listen address has to come from
# --host: with BIND=127.0.0.1 the API must NOT be reachable from the LAN.
VLLM_HOST="127.0.0.1"
[[ "$BIND" != "127.0.0.1" ]] && VLLM_HOST="0.0.0.0"

VLLM_ARGS=(
    serve "$MODEL_DIR"
    --served-model-name mimo-v2.6-flash
    --trust-remote-code
    --tensor-parallel-size "$TP"
    --distributed-executor-backend mp
    --hf-overrides '{"moe_router_dtype":"bfloat16"}'
    --host "$VLLM_HOST" --port "$PORT"
    --api-key "$API_KEY"
    --max-model-len "$CTX"
    --max-num-seqs "$SEQS"
    --max-num-batched-tokens "$MAX_BATCHED"
    --reasoning-parser mimo
    --tool-call-parser mimo
    --enable-auto-tool-choice
    --generation-config auto
    --moe-backend marlin
    --kv-cache-dtype "$KV_DTYPE"
    --kv-offloading-size "$KV_OFFLOAD"
    --disable-custom-all-reduce
    --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY"}'
    --speculative-config "{\"method\":\"dflash\",\"model\":\"$MODEL_DIR/dflash\",\"num_speculative_tokens\":$SPEC_TOKENS,\"draft_tensor_parallel_size\":$DRAFT_TP}"
)

# Either an explicit pool size or a utilization target, never both.
if [[ -n "$KV_MEM" ]]; then
    VLLM_ARGS+=(--kv-cache-memory "$KV_MEM")
else
    VLLM_ARGS+=(--gpu-memory-utilization "$UTIL")
fi

if [[ "$TEXT_ONLY" == "1" ]]; then
    VLLM_ARGS+=(--language-model-only)
else
    VLLM_ARGS+=(--limit-mm-per-prompt '{"image":{"count":4,"width":1920,"height":1080},"video":{"count":1,"num_frames":32,"width":640,"height":360},"audio":{"count":1,"length":1920000}}')
    VLLM_ARGS+=(--mm-processor-kwargs '{"max_pixels":2073600}')
fi

VPY=/usr/local/lib/python3.12/dist-packages/vllm

log "Starting (first start also JIT-compiles the custom prefill kernel and the"
log "torch.compile cache; later starts reuse $CACHE_DIR)."

# ── Launch ──
docker run -d --name "$CONTAINER_NAME" \
    --gpus all --network host --ipc host --shm-size 32g --ulimit memlock=-1:-1 \
    -v "$MODEL_DIR":"$MODEL_DIR":ro \
    -v "$CACHE_DIR":/root/.cache \
    -v "$RECIPE_DIR/patches/triton_unified_attention_diffkv.py:$VPY/v1/attention/ops/triton_unified_attention_diffkv.py:ro" \
    -v "$RECIPE_DIR/patches/mimo_v2.py:$VPY/model_executor/models/mimo_v2.py:ro" \
    -v "$RECIPE_DIR/patches/triton_attn_diffkv.attn.py:$VPY/v1/attention/backends/triton_attn_diffkv.py:ro" \
    -v "$RECIPE_DIR/kernels/attention:/attn-kernels" \
    -e TORCHINDUCTOR_CACHE_DIR=/root/.cache/torchinductor \
    -e TRITON_CACHE_DIR=/root/.cache/triton \
    -e VLLM_ENGINE_READY_TIMEOUT_S=3600 \
    -e VLLM_MARLIN_INPUT_DTYPE=fp8 \
    -e VLLM_MIMO_EXACT_QKV=1 \
    -e ATTN_CUSTOM_SRC=/attn-kernels/prefill_attn_v1.cu \
    -e ATTN_CUSTOM_BUILD=/attn-kernels/build-prefill_attn_v1.cu \
    -e NCCL_CUMEM_ENABLE=0 \
    -e NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE:-0}" \
    --entrypoint vllm "$IMAGE" "${VLLM_ARGS[@]}" >/dev/null

log "Container started. Waiting for the API to report ready (model load ~3-6 min)..."

# vLLM answers /health once the engine is up. The engine also prints its KV pool
# size at startup; surface it because it is the number that sets real capacity.
deadline=$(( $(date +%s) + 1800 ))
ready=0
while (( $(date +%s) < deadline )); do
    if curl -sf -m 5 -H "Authorization: Bearer $API_KEY" "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log_err "Container exited during startup:"
        docker logs --tail 40 "$CONTAINER_NAME" 2>&1 | grep -vE "^\s*File |^\s*\^|^\s*~" >&2 || true
        exit 1
    fi
    sleep 10
done

if (( ready == 0 )); then
    log_err "Timed out waiting for the API. Inspect: docker logs $CONTAINER_NAME"
    exit 1
fi

pool_line=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -iE "GPU KV cache size|KV cache size" | tail -1 || true)
log "Ready. API on http://${BIND}:${PORT}/v1 (container listens on ${VLLM_HOST}), key at $STATE_DIR/api-key"
[[ -n "$pool_line" ]] && log "KV pool: ${pool_line#*] }"
log "Smoke test:"
log "  curl -s http://127.0.0.1:${PORT}/v1/chat/completions \\"
log "    -H 'Authorization: Bearer '\$(cat $STATE_DIR/api-key) -H 'Content-Type: application/json' \\"
log "    -d '{\"model\":\"mimo-v2.6-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":64}'"
exit 0
