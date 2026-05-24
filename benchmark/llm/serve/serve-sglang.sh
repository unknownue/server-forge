#!/bin/bash
# Start SGLang inference server with OpenAI-compatible API.
# Optimised for RTX 6000 Blackwell (SM120a).
#
# Usage:
#   bash benchmark/llm/serve/serve-sglang.sh [MODEL_ID] [GPUS] [PORT]
#
# Default: Qwen/Qwen3.6-27B-FP8, GPU 0,1 (TP=2), port 8000
#
# The server runs in the foreground. Press Ctrl+C to stop.
# Model must be downloaded first: bash scripts/lib/download-model.sh

set -euo pipefail

MODEL_ID="${1:-Qwen/Qwen3.6-27B-FP8}"
GPUS="${2:-0,1}"
PORT="${3:-8000}"

ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/$ORG/$MODEL_NAME"

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "ERROR: Model not found at $MODEL_DIR" >&2
    echo "Run first: bash scripts/lib/download-model.sh" >&2
    exit 1
fi

# Count GPUs for tensor parallelism
IFS=',' read -ra GPU_ARRAY <<< "$GPUS"
TP_SIZE="${#GPU_ARRAY[@]}"

if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2
    exit 1
fi

SGLANG_IMAGE="voipmonitor/sglang:test-cu132"

if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
    echo "ERROR: Docker image '$SGLANG_IMAGE' not found." >&2
    echo "Run: docker pull $SGLANG_IMAGE" >&2
    exit 1
fi

CACHE_DIR="/data/cache/sglang_jit"
mkdir -p "$CACHE_DIR"

CONTAINER_NAME="sglang-server"
# Stop any existing container with the same name or port
EXISTING_CID=$(docker ps -q --filter "name=$CONTAINER_NAME" 2>/dev/null)
if [[ -z "$EXISTING_CID" ]]; then
    EXISTING_CID=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
fi
if [[ -n "$EXISTING_CID" ]]; then
    echo "Stopping existing container (CID: $EXISTING_CID)..."
    docker stop "$EXISTING_CID" 2>/dev/null || true
fi

echo "=== Starting SGLang Server ==="
echo "  Model    : $MODEL_ID"
echo "  GPUs     : $GPUS  (TP=$TP_SIZE)"
echo "  Port     : $PORT"
echo "  Image    : $SGLANG_IMAGE"
[[ -n "${HF_ENDPOINT:-}" ]] && echo "  HF_ENDPOINT: $HF_ENDPOINT"
echo ""

HF_ENV=()
[[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

docker run --rm \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=$GPUS" \
    -e "SGLANG_ENABLE_JIT_DEEPGEMM=0" \
    -e "SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1" \
    -e "SGLANG_ENABLE_SPEC_V2=1" \
    -e "HOME=/cache" \
    --user "$(id -u):$(id -g)" \
    --ipc=host \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    "${HF_ENV[@]}" \
    -p "$PORT:8000" \
    -v "$MODEL_DIR:/models:ro" \
    -v "$CACHE_DIR:/cache:rw" \
    "$SGLANG_IMAGE" \
    sglang serve \
    --model-path "/models" \
    --served-model-name frisky \
    --tp-size "$TP_SIZE" \
    --context-length 262144 \
    --host 0.0.0.0 \
    --port 8000 \
    --log-requests \
    --log-requests-level 2 \
    --reasoning-parser qwen3 \
    --tool-call-parser qwen3_coder \
    --speculative-algo NEXTN \
    --speculative-num-steps 3 \
    --speculative-eagle-topk 1 \
    --speculative-num-draft-tokens 4 \
    --attention-backend triton \
    --fp8-gemm-backend triton \
    --mamba-scheduler-strategy extra_buffer \
    --kv-cache-dtype fp8_e4m3 \
    --chunked-prefill-size 8192 \
    --page-size 64 \
    --mem-fraction-static 0.9 \
    --enable-metrics
