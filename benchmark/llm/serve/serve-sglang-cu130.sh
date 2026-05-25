#!/bin/bash
# Start SGLang inference server with OpenAI-compatible API.
# Uses voipmonitor/sglang:cu130 with default SGLang settings.
#
# Usage:
#   bash benchmark/llm/serve/serve-sglang-cu130.sh [MODEL_ID] [GPUS] [PORT]
#
# Default: Qwen/Qwen3.6-27B, GPU 0,1 (TP=2), port 8000
#
# The server runs in the foreground. Press Ctrl+C to stop.
# Model must be downloaded first: bash nodes/ubuntu26-node1-server/download-model.sh

set -euo pipefail

MODEL_ID="${1:-Qwen/Qwen3.6-27B}"
GPUS="${2:-0,1}"
PORT="${3:-8000}"

ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/$ORG/$MODEL_NAME"

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "ERROR: Model not found at $MODEL_DIR" >&2
    echo "Run first: bash nodes/ubuntu26-node1-server/download-model.sh" >&2
    exit 1
fi

# Count GPUs for tensor parallelism
IFS=',' read -ra GPU_ARRAY <<< "$GPUS"
TP_SIZE="${#GPU_ARRAY[@]}"

if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2
    exit 1
fi

SGLANG_IMAGE="voipmonitor/sglang:cu130"

if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
    echo "ERROR: Docker image '$SGLANG_IMAGE' not found." >&2
    echo "Run: docker pull $SGLANG_IMAGE" >&2
    exit 1
fi

CACHE_DIR="/data/cache/sglang_jit"
mkdir -p "$CACHE_DIR"

CONTAINER_NAME="sglang-server-cu130"
# Stop any existing container with the same name or port
EXISTING_CID=$(docker ps -q --filter "name=$CONTAINER_NAME" 2>/dev/null)
if [[ -z "$EXISTING_CID" ]]; then
    EXISTING_CID=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
fi
if [[ -n "$EXISTING_CID" ]]; then
    echo "Stopping existing container (CID: $EXISTING_CID)..."
    docker stop "$EXISTING_CID" 2>/dev/null || true
fi

echo "=== Starting SGLang Server (Default Config) ==="
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
    -e "HOME=/cache" \
    -e "HF_HOME=/cache/huggingface" \
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
    --served-model-name "$MODEL_NAME" \
    --tp-size "$TP_SIZE" \
    --host 0.0.0.0 \
    --port 8000
