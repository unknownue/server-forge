#!/bin/bash
# Run AIPerf benchmark against an OpenAI-compatible API endpoint.
# Runs aiperf in Docker (build first: bash benchmark/llm/build-aiperf.sh)
#
# Usage:
#   bash benchmark/llm/bench-aiperf.sh [ENDPOINT] [MODEL_NAME]
#
# Default: endpoint=http://localhost:8000/v1, model from serve-vllm.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ENDPOINT="${1:-http://localhost:8000/v1}"
MODEL_NAME="${2:-Qwen3.6-27B}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-32}"

AIPERF_IMAGE="aiperf:latest"

# Ensure image is built
if ! docker image inspect "$AIPERF_IMAGE" &>/dev/null; then
    echo "ERROR: Docker image '$AIPERF_IMAGE' not found." >&2
    echo "Run: bash benchmark/llm/build-aiperf.sh" >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/benchmark/results"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/aiperf_${MODEL_NAME}_${TIMESTAMP}.log"

echo "=== AIPerf Benchmark ==="
echo "  Endpoint      : $ENDPOINT"
echo "  Model         : $MODEL_NAME"
echo "  Num Prompts   : $NUM_PROMPTS"
echo "  Concurrency   : $MAX_CONCURRENCY"
echo "  Result File   : $RESULT_FILE"
echo ""

docker run --rm \
    --network host \
    --user "$(id -u):$(id -g)" \
    -e "HOME=/tmp" \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -v "$RESULT_DIR:/results" \
    "$AIPERF_IMAGE" \
    bash -c "aiperf profile \
        --endpoint '$ENDPOINT' \
        --model '$MODEL_NAME' \
        --num-prompts '$NUM_PROMPTS' \
        --max-concurrency '$MAX_CONCURRENCY'" \
    2>&1 | tee "$RESULT_FILE"

echo ""
echo "=== Done ==="
echo "Result: $RESULT_FILE"
