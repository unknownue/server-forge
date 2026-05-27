#!/bin/bash
# Start a single SGLang text model inference server.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/game-server/serve/serve-text.sh [MODEL] [GPU] [PORT] [TP] [EXTRA_ARGS]
#
# MODEL:      model path (e.g. /data/work/models/Qwen/Qwen3.6-27B)
# GPU:        CUDA_VISIBLE_DEVICES (e.g. "0,1")
# PORT:       host port (default: 8000)
# TP:         tensor parallel size (default: auto from GPU count)
# EXTRA_ARGS: additional sglang serve arguments (e.g. "--quantization fp8 --reasoning-parser qwen3")
#
# Examples:
#   # 27B Dense FP8 (coordinator or multimodal)
#   bash serve-text.sh /data/work/models/Qwen/Qwen3.6-27B 0 8000 1 "--quantization fp8 --reasoning-parser qwen3"
#
#   # 35B-A3B MoE BF16 (code generation — RTX 6000D can't FP8-quantize Triton MoE kernels)
#   bash serve-text.sh /data/work/models/Qwen/Qwen3.6-35B-A3B 1 8001 1 "--cuda-graph-max-bs 4 --reasoning-parser qwen3"

set -euo pipefail

MODEL_DIR="${1:-/data/work/models/Qwen/Qwen3.5-4B}"
GPUS="${2:-0}"
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
mkdir -p "$CACHE_DIR"

CONTAINER_NAME="sglang-text-$(basename "$MODEL_DIR")-${PORT}"

if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2; exit 1
fi
if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
    echo "ERROR: Image not found: $SGLANG_IMAGE" >&2; exit 1
fi
if [[ ! -f "$MODEL_DIR/config.json" ]]; then
    echo "ERROR: Model not found: $MODEL_DIR" >&2; exit 1
fi

# Stop existing container on same port
EXISTING=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
if [[ -n "$EXISTING" ]]; then
    echo "Stopping existing container on port $PORT..."
    docker stop "$EXISTING" 2>/dev/null || true
fi

echo ""
echo "============================================"
echo "  SGLang Text Server"
echo "  Model : $(basename "$MODEL_DIR")"
echo "  GPU   : $GPUS (TP=$TP)"
echo "  Port  : $PORT"
echo "============================================"
echo ""

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
    "$SGLANG_IMAGE" \
    sglang serve \
        --model-path "/models" \
        --served-model-name "$(basename "$MODEL_DIR")" \
        --tp-size "$TP" \
        --context-length 32768 \
        --host 0.0.0.0 \
        --port 8000 \
        --attention-backend flashinfer \
        --kv-cache-dtype fp8_e5m2 \
        --mem-fraction-static 0.85 \
        $EXTRA_ARGS

# Wait for health — SGLang exposes /health_generate, not /health
echo "Waiting for server to be ready..."
for i in $(seq 1 300); do
    if curl -s --max-time 3 "http://localhost:$PORT/health_generate" -o /dev/null 2>/dev/null; then
        echo "Ready (${i}x2s)."
        echo "  Endpoint: http://localhost:$PORT/v1/chat/completions"
        echo "  Model  : $(basename "$MODEL_DIR")"
        exit 0
    fi
    sleep 2
done

echo "ERROR: Server failed to become ready."
exit 1
