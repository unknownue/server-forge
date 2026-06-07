#!/bin/bash
# Start a single SGLang text model inference server.
# Unified version — works for both Dense and MoE models.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/serve/sglang-text.sh [MODEL] [GPU] [PORT] [TP] [EXTRA_ARGS]
#
# MODEL:      model path (e.g. /data/work/models/Qwen/Qwen3.6-27B)
# GPU:        CUDA_VISIBLE_DEVICES (e.g. "0" or "0,1")
# PORT:       host port (default: 8000)
# TP:         tensor parallel size (default: auto from GPU count)
# EXTRA_ARGS: additional sglang serve arguments
#
# Examples:
#   # 27B Dense FP8
#   bash serve/sglang-text.sh /data/work/models/Qwen/Qwen3.6-27B 0 8000 1 \
#     "--quantization fp8 --reasoning-parser qwen3 --tool-call-parser qwen3_coder"
#
#   # 35B-A3B MoE FP8 (requires tuned MoE kernel config)
#   bash serve/sglang-text.sh /data/work/models/Qwen/Qwen3.6-35B-A3B 1 8001 1 \
#     "--quantization fp8 --cuda-graph-max-bs 8 --max-running-requests 2 --reasoning-parser qwen3 --tool-call-parser qwen3_coder"
#
#   # 72B Dense FP8 TP=2
#   bash serve/sglang-text.sh /data/work/models/Qwen/Qwen3-72B 0,1 8000 2 \
#     "--quantization fp8 --reasoning-parser qwen3 --tool-call-parser qwen3_coder"

set -euo pipefail

MODEL_DIR="${1:?Usage: $0 MODEL GPU [PORT] [TP] [EXTRA_ARGS]}"
GPUS="${2:?Usage: $0 MODEL GPU [PORT] [TP] [EXTRA_ARGS]}"
PORT="${3:-8000}"
TP="${4:-}"
EXTRA_ARGS="${5:-}"

# Auto-detect TP from GPU count
if [[ -z "$TP" ]]; then
    IFS=',' read -ra GPU_ARRAY <<< "$GPUS"
    TP="${#GPU_ARRAY[@]}"
fi

SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
CACHE_DIR="/data/cache/sglang_jit"
MOE_CONFIG_DIR="$CACHE_DIR/moe_configs"
SGLANG_PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../images/sglang/patches/anthropic" && pwd)"
mkdir -p "$CACHE_DIR"

_DEFAULT_NAME="sglang-text-$(basename "$MODEL_DIR")-${PORT}"
CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-$_DEFAULT_NAME}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Pre-flight ──
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2; exit 1
fi
if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
    echo "ERROR: Image not found: $SGLANG_IMAGE" >&2; exit 1
fi
if [[ ! -f "$MODEL_DIR/config.json" ]]; then
    echo "ERROR: Model not found: $MODEL_DIR" >&2
    echo "Download with: bash scripts/lib/download-model.sh <MODEL_ID>" >&2
    exit 1
fi

# Stop existing container on same port
EXISTING=$(docker ps -a -q --filter "name=$CONTAINER_NAME" 2>/dev/null)
if [[ -n "$EXISTING" ]]; then
    log "Removing existing container $CONTAINER_NAME..."
    docker rm -f "$EXISTING" 2>/dev/null || true
fi
EXISTING=$(docker ps -a -q --filter "publish=$PORT" 2>/dev/null)
if [[ -n "$EXISTING" ]]; then
    log "Removing existing container on port $PORT..."
    docker rm -f "$EXISTING" 2>/dev/null || true
fi

log ""
log "============================================"
log "  SGLang Text Server"
log "  Model : $(basename "$MODEL_DIR")"
log "  GPU   : $GPUS (TP=$TP)"
log "  Port  : $PORT"
log "============================================"
log ""

# NOTE: no --page-size — Qwen3 GDN/Mamba hybrid architecture requires page_size=1 (auto).
# Setting it explicitly to 64 causes: AssertionError: Page size must be 1 for MambaRadixCache.
docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=$GPUS" \
    -e "SGLANG_ENABLE_JIT_DEEPGEMM=0" \
    -e "NCCL_P2P_LEVEL=PHB" \
    -e "NCCL_MIN_NCHANNELS=8" \
    -e "NCCL_MAX_NCHANNELS=8" \
    -e "NCCL_IB_DISABLE=1" \
    -e "NCCL_CUMEM_HOST_ENABLE=0" \
    -e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=1" \
    -e "OMP_NUM_THREADS=8" \
    -e "HOME=/cache" \
    -e "XDG_CACHE_HOME=/cache" \
    -e "FLASHINFER_WORKSPACE_BASE=/cache/flashinfer" \
    -e "TORCH_EXTENSIONS_DIR=/cache/torch_extensions" \
    -e "TRITON_CACHE_DIR=/cache/triton" \
    -e "TVM_FFI_CACHE_DIR=/cache/tvm-ffi" \
    --user "$(id -u):$(id -g)" \
    --ipc=host \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -p "$PORT:8000" \
    -v "$MODEL_DIR:/models:ro" \
    -v "$CACHE_DIR:/cache:rw" \
    -v "$MOE_CONFIG_DIR:/moe_configs:ro" \
    -e "SGLANG_MOE_CONFIG_DIR=/moe_configs" \
    -v "$SGLANG_PATCH_DIR/protocol.py:/opt/sglang/python/sglang/srt/entrypoints/anthropic/protocol.py:ro" \
    -v "$SGLANG_PATCH_DIR/serving.py:/opt/sglang/python/sglang/srt/entrypoints/anthropic/serving.py:ro" \
    "$SGLANG_IMAGE" \
    sglang serve \
        --model-path "/models" \
        --served-model-name "$(basename "$MODEL_DIR")" \
        --tp-size "$TP" \
        --host 0.0.0.0 \
        --port 8000 \
        --attention-backend flashinfer \
        --kv-cache-dtype fp8_e5m2 \
        --mem-fraction-static 0.92 \
        $EXTRA_ARGS

# Wait for health — SGLang exposes /health_generate, not /health
log "Waiting for server to be ready..."
for i in $(seq 1 300); do
    if curl -s --max-time 3 "http://localhost:$PORT/health_generate" -o /dev/null 2>/dev/null; then
        log "Ready (${i}x2s)."
        log "  Endpoint: http://localhost:$PORT/v1/chat/completions"
        log "  Model  : $(basename "$MODEL_DIR")"
        exit 0
    fi
    sleep 2
done

log "ERROR: Server failed to become ready."
exit 1
