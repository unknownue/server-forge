#!/bin/bash
# Run AIPerf benchmark against an OpenAI-compatible API endpoint.
# Runs aiperf in Docker (build first: bash benchmark/llm/bench/build-aiperf.sh)
#
# Usage:
#   bash benchmark/llm/bench/bench-aiperf.sh [BASE_URL] [MODEL_NAME] [HF_MODEL_ID]
#
# MODEL_NAME is the server-side model name (passed to vLLM).
# HF_MODEL_ID is the full HuggingFace ID for tokenizer download (e.g. Qwen/Qwen3.6-27B).
#
# Default: endpoint=http://localhost:8000, model=Qwen3.6-27B

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

BASE_URL="${1:-http://localhost:8000}"
MODEL_NAME="${2:-Qwen3.6-27B}"
HF_MODEL_ID="${3:-Qwen/$MODEL_NAME}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
NUM_REQUESTS="${NUM_REQUESTS:-$NUM_PROMPTS}"
CONCURRENCY="${AIPERF_CONCURRENCY:-16}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-10}"
OSL="${OSL:-4096}"

AIPERF_IMAGE="aiperf:latest"

# Ensure image is built
if ! docker image inspect "$AIPERF_IMAGE" &>/dev/null; then
    echo "ERROR: Docker image '$AIPERF_IMAGE' not found." >&2
    echo "Run: bash benchmark/llm/bench/build-aiperf.sh" >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/aiperf_${MODEL_NAME}_${TIMESTAMP}.log"

echo "=== AIPerf Benchmark ==="
echo "  Endpoint      : $BASE_URL"
echo "  Model         : $MODEL_NAME"
echo "  Tokenizer     : $HF_MODEL_ID"
echo "  Num Prompts   : $NUM_PROMPTS"
echo "  Num Requests  : $NUM_REQUESTS"
echo "  Concurrency   : $CONCURRENCY"
echo "  Warmup Reqs   : $WARMUP_REQUESTS"
echo "  Max Output Tok: $OSL"
echo "  Result File   : $RESULT_FILE"
echo ""

HF_MIRROR="${HF_ENDPOINT:-https://hf-mirror.com}"

docker run --rm \
    --network host \
    --user "$(id -u):$(id -g)" \
    -e "HOME=/tmp" \
    -e "HF_ENDPOINT=$HF_MIRROR" \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -v "$RESULT_DIR:/results" \
    "$AIPERF_IMAGE" \
    bash -c "aiperf profile \
        --url '$BASE_URL' \
        --model '$MODEL_NAME' \
        --tokenizer '$HF_MODEL_ID' \
        --num-prompts '$NUM_PROMPTS' \
        --num-requests '$NUM_REQUESTS' \
        --num-warmup-requests '$WARMUP_REQUESTS' \
        --concurrency '$CONCURRENCY' \
        --osl '$OSL' \
        --artifact-dir /results" \
    2>&1 | tee "$RESULT_FILE"

echo ""
echo "=== Done ==="
echo "Result: $RESULT_FILE"
