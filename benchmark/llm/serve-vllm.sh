#!/bin/bash
# Start vLLM inference server with OpenAI-compatible API.
#
# Usage:
#   bash benchmark/llm/serve-vllm.sh [MODEL_ID] [GPUS] [PORT]
#
# Default: Qwen/Qwen3-27B, GPU 0,1 (TP=2), port 8000
#
# The server runs in the foreground. Press Ctrl+C to stop.
# Model must be downloaded first: bash benchmark/llm/download-model.sh

set -euo pipefail

MODEL_ID="${1:-Qwen/Qwen3.6-27B}"
GPUS="${2:-0,1}"
PORT="${3:-8000}"

ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/$ORG/$MODEL_NAME"

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "ERROR: Model not found at $MODEL_DIR" >&2
    echo "Run first: bash benchmark/llm/download-model.sh" >&2
    exit 1
fi

# Count GPUs for tensor parallelism
IFS=',' read -ra GPU_ARRAY <<< "$GPUS"
TP_SIZE="${#GPU_ARRAY[@]}"

if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2
    exit 1
fi

echo "=== Starting vLLM Server ==="
echo "  Model    : $MODEL_ID"
echo "  GPUs     : $GPUS  (TP=$TP_SIZE)"
echo "  Port     : $PORT"
[[ -n "${HF_ENDPOINT:-}" ]] && echo "  HF_ENDPOINT: $HF_ENDPOINT"
echo ""

# VLLM_IMAGE="vllm/vllm-openai:v0.20.2-cu129-ubuntu2404"
VLLM_IMAGE="vllm/vllm-openai:latest"
HF_ENV=()
[[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

docker run --rm \
    --gpus all \
    -e "HOME=/tmp" \
    -e "NVIDIA_VISIBLE_DEVICES=$GPUS" \
    --user "$(id -u):$(id -g)" \
    --ipc=host \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    "${HF_ENV[@]}" \
    -p "$PORT:8000" \
    -v "$MODEL_DIR:/models:ro" \
    "$VLLM_IMAGE" \
    --model "/models" \
    --served-model-name "$MODEL_NAME" \
    --tensor-parallel-size "$TP_SIZE" \
    --host 0.0.0.0 \
    --port 8000
