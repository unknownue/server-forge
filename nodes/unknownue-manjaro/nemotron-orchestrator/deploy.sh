#!/bin/bash
# Start Nemotron-Orchestrator-8B-AWQ-8bit via vLLM OpenAI-compatible server.
#
# Usage:
#   bash nodes/unknownue-manjaro/nemotron-orchestrator/serve.sh [PORT]
#
# Default port: 8001
# Press Ctrl+C to stop.

set -euo pipefail

PORT="${1:-8001}"
MODEL_ID="cyankiwi/Nemotron-Orchestrator-8B-AWQ-8bit"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/cyankiwi/Nemotron-Orchestrator-8B-AWQ-8bit"
IMAGE="vllm/vllm-openai:latest"
CONTAINER_NAME="nemotron-orchestrator"

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "ERROR: Model not found at $MODEL_DIR" >&2
    echo "Run first: bash scripts/lib/download-model.sh $MODEL_ID" >&2
    exit 1
fi

if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "ERROR: Image '$IMAGE' not found." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2
    exit 1
fi

# Stop existing container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo "=== Starting Nemotron-Orchestrator vLLM Server ==="
echo "  Model    : $MODEL_ID"
echo "  GPU      : 0  (TP=1)"
echo "  Port     : $PORT"
[[ -n "${HF_ENDPOINT:-}" ]] && echo "  HF_ENDPOINT: $HF_ENDPOINT"
echo ""

HF_ENV=()
[[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

docker run --rm \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=0" \
    -e "OMP_NUM_THREADS=8" \
    -e "HOME=/tmp" \
    --user "$(id -u):$(id -g)" \
    --ipc=host \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    "${HF_ENV[@]}" \
    -p "$PORT:8000" \
    -v "$MODEL_DIR:/models:ro" \
    "$IMAGE" \
    "/models" \
    --served-model-name "$MODEL_NAME" \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.93 \
    --max-model-len 40960 \
    --max-num-seqs 32 \
    --enable-prefix-caching \
    --tool-call-parser hermes \
    --enable-auto-tool-choice \
    --reasoning-parser deepseek_r1 \
    --host 0.0.0.0 \
    --port 8000
