#!/bin/bash
# Start a Vision-Language model server for screenshot/video understanding.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/serve/sglang-vl.sh [MODEL] [GPU] [PORT]
#
# Default: Qwen2.5-VL-7B-Instruct, GPU=2, port=8100

set -euo pipefail

VL_MODEL_DIR="${1:-/data/work/models/Qwen/Qwen2.5-VL-7B-Instruct}"
GPUS="${2:-2}"
PORT="${3:-8100}"

IFS=',' read -ra GPU_ARRAY <<< "$GPUS"
TP="${#GPU_ARRAY[@]}"

SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
CACHE_DIR="/data/cache/sglang_jit"
mkdir -p "$CACHE_DIR"

_DEFAULT_NAME="sglang-vl-${PORT}"
CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-$_DEFAULT_NAME}"

if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2; exit 1
fi
if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
    echo "ERROR: Image not found: $SGLANG_IMAGE" >&2; exit 1
fi
if [[ ! -f "$VL_MODEL_DIR/config.json" ]]; then
    echo "ERROR: VL model not found: $VL_MODEL_DIR" >&2
    echo "Download with: bash scripts/lib/download-model.sh <MODEL_ID>" >&2
    exit 1
fi

EXISTING=$(docker ps -a -q --filter "name=$CONTAINER_NAME" 2>/dev/null)
[[ -n "$EXISTING" ]] && docker rm -f "$EXISTING" 2>/dev/null || true
EXISTING=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
if [[ -n "$EXISTING" ]]; then
    echo "Stopping existing container on port $PORT..."
    docker rm -f "$EXISTING" 2>/dev/null || true
fi

echo ""
echo "============================================"
echo "  SGLang VL Server"
echo "  Model : $(basename "$VL_MODEL_DIR")"
echo "  GPU   : $GPUS (TP=$TP)"
echo "  Port  : $PORT"
echo "============================================"
echo ""

docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=$GPUS" \
    -e "SGLANG_ENABLE_JIT_DEEPGEMM=0" \
    -e "NCCL_P2P_LEVEL=PHB" \
    -e "NCCL_MIN_NCHANNELS=8" \
    -e "NCCL_IB_DISABLE=1" \
    -e "NCCL_CUMEM_HOST_ENABLE=0" \
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
    -v "$VL_MODEL_DIR:/models:ro" \
    -v "$CACHE_DIR:/cache:rw" \
    "$SGLANG_IMAGE" \
    sglang serve \
        --model-path "/models" \
        --served-model-name "$(basename "$VL_MODEL_DIR")" \
        --tp-size "$TP" \
        --context-length 32768 \
        --host 0.0.0.0 \
        --port 8000 \
        --attention-backend flashinfer \
        --kv-cache-dtype fp8_e5m2 \
        --page-size 64 \
        --mem-fraction-static 0.85

echo "Waiting for VL server to be ready..."
for i in $(seq 1 300); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" == "200" ]]; then
        echo "Ready (${i}x2s)."
        echo "  Endpoint: http://localhost:$PORT/v1/chat/completions"
        echo "  Model  : $(basename "$VL_MODEL_DIR")"
        exit 0
    fi
    sleep 2
done

echo "ERROR: VL server failed to start."
exit 1
