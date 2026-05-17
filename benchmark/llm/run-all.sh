#!/bin/bash
# End-to-end LLM benchmark: download model → start vLLM → run AIPerf.
#
# Usage:
#   bash benchmark/llm/run-all.sh [MODEL_ID] [GPUS]
#
# Default: Qwen/Qwen3-27B, GPU 0,1 (TP=2)
#
# Steps are run separately so each can be re-run independently:
#   1. benchmark/llm/download-model.sh   — download model once
#   2. benchmark/llm/serve-vllm.sh        — start server (background)
#   3. benchmark/llm/bench-aiperf.sh      — run benchmark
#
# The vLLM server stops automatically when this script exits.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLM_DIR="$REPO_ROOT/benchmark/llm"

MODEL_ID="${1:-Qwen/Qwen3.6-27B}"
GPUS="${2:-0,1}"
PORT=8000

MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "[cleanup] Stopping vLLM server (PID $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # Also stop any container using our port
    local cid
    cid=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
    if [[ -n "$cid" ]]; then
        docker stop "$cid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "============================================"
echo "  LLM Inference Benchmark"
echo "  Model : $MODEL_ID"
echo "  GPUs  : $GPUS"
echo "============================================"
echo ""

# ── Step 1: Download model ──
echo "[1/3] Ensuring model is downloaded..."
bash "$LLM_DIR/download-model.sh" "$MODEL_ID"
echo ""

# ── Step 2: Start vLLM server ──
echo "[2/3] Starting vLLM server..."
bash "$LLM_DIR/serve-vllm.sh" "$MODEL_ID" "$GPUS" "$PORT" &
SERVER_PID=$!

# Wait for server to be ready
echo "  Waiting for server to be ready..."
for i in $(seq 1 60); do
    if curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
        echo "  Server is ready."
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: Server process died unexpectedly." >&2
        exit 1
    fi
    sleep 2
done

if ! curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "ERROR: Server failed to become ready within 120s." >&2
    exit 1
fi
echo ""

# ── Step 3: Run AIPerf benchmark ──
echo "[3/3] Running AIPerf benchmark..."
bash "$LLM_DIR/bench-aiperf.sh" "http://localhost:$PORT/v1" "$MODEL_NAME"

echo ""
echo "============================================"
echo "  Benchmark complete."
echo "============================================"
