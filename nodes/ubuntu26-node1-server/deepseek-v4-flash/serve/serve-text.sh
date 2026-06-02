#!/bin/bash
# Start DeepSeek-V4-Flash vLLM inference server.
# W4A16 model (~145 GB) requires 2 GPUs with TP=2.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/deepseek-v4-flash/serve/serve-text.sh [PORT] [MAX_MODEL_LEN] [MAX_NUM_SEQS]
#
# PORT:          host port (default: 8000)
# MAX_MODEL_LEN: context length (default: 131072)
# MAX_NUM_SEQS:  concurrent requests (default: 2)

set -euo pipefail

PORT="${1:-8000}"
MAX_MODEL_LEN="${2:-131072}"
MAX_NUM_SEQS="${3:-2}"

IMAGE_NAME="dsv4-flash-acti-mtp:0.1.0"
MODEL_PATH="/data/work/models/LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8"
CACHE_VOLUME="dsv4_cache"
CONTAINER_NAME="dsv4-flash-${PORT}"

# Pre-flight checks
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2; exit 1
fi
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "ERROR: Image not found: $IMAGE_NAME" >&2
    echo "Build: bash $(dirname "$(dirname "$0")")/docker/build.sh" >&2
    exit 1
fi
if [[ ! -f "$MODEL_PATH/config.json" ]]; then
    echo "ERROR: Model not found: $MODEL_PATH" >&2; exit 1
fi

# Stop existing container on same port
EXISTING=$(docker ps -a -q --filter "publish=$PORT" 2>/dev/null)
if [[ -n "$EXISTING" ]]; then
    echo "Stopping existing container on port $PORT..."
    docker rm -f "$EXISTING" 2>/dev/null || true
fi

# Ensure cache volume exists
docker volume create "$CACHE_VOLUME" 2>/dev/null || true

echo ""
echo "============================================"
echo "  DeepSeek-V4-Flash vLLM Server"
echo "  Model    : DeepSeek-V4-Flash W4A16-FP8"
echo "  GPU      : 0,1 (TP=2)"
echo "  Port     : $PORT"
echo "  Context  : $MAX_MODEL_LEN"
echo "  Concurrent: $MAX_NUM_SEQS"
echo "  Image    : $IMAGE_NAME"
echo "============================================"
echo ""

docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=0,1" \
    -e "MODEL_PATH=/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8" \
    -e "TENSOR_PARALLEL_SIZE=2" \
    -e "MAX_MODEL_LEN=$MAX_MODEL_LEN" \
    -e "MAX_NUM_SEQS=$MAX_NUM_SEQS" \
    -e "MAX_NUM_BATCHED_TOKENS=8192" \
    -e "GPU_MEMORY_UTILIZATION=0.93" \
    -e "BLOCK_SIZE=256" \
    -e "DISABLE_CUSTOM_ALL_REDUCE=1" \
    -e "ENABLE_MTP=1" \
    -e "PORT=$PORT" \
    --ipc=host \
    --shm-size=16g \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -p "$PORT:$PORT" \
    -v "$MODEL_PATH:/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8:ro" \
    -v "${CACHE_VOLUME}:/root/.cache" \
    "$IMAGE_NAME"

# Wait for health
echo "Waiting for server to be ready..."
for i in $(seq 1 120); do
    if curl -s --max-time 5 "http://localhost:$PORT/health" -o /dev/null 2>/dev/null; then
        echo "Ready (${i}x5s)."
        echo "  Endpoint: http://localhost:$PORT/v1/chat/completions"
        echo "  Model   : deepseek-v4-flash"
        exit 0
    fi
    sleep 5
done

echo "ERROR: Server failed to become ready within 600s."
exit 1
