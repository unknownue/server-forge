#!/bin/bash
# End-to-end LLM benchmark: download model → start server → run AIPerf.
#
# Usage:
#   bash benchmark/llm/bench/run-all.sh [MODEL_ID] [GPUS] [BACKEND]
#
# Default: Qwen/Qwen3.6-27B, GPU 0,1 (TP=2), backend=sglang
#
# BACKEND: sglang (default, Blackwell-compatible) or vllm
#
# Steps are run separately so each can be re-run independently:
#   1. nodes/ubuntu26-node1-server/download-model.sh  — download model once
#   2. benchmark/llm/serve/serve-sglang.sh            — start server (background)
#   3. benchmark/llm/bench/bench-aiperf.sh            — run benchmark
#
# The server stops automatically when this script exits.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LLM_DIR="$REPO_ROOT/benchmark/llm"

MODEL_ID="${1:-Qwen/Qwen3.6-27B}"
GPUS="${2:-0,1}"
BACKEND="${3:-sglang}"
PORT=8000

MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"

if [[ "$BACKEND" == "sglang" ]]; then
    SERVE_SCRIPT="$LLM_DIR/serve/serve-sglang.sh"
elif [[ "$BACKEND" == "vllm" ]]; then
    SERVE_SCRIPT="$LLM_DIR/serve/serve-vllm.sh"
else
    echo "ERROR: Unknown backend '$BACKEND'. Choose sglang or vllm." >&2
    exit 1
fi

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "[cleanup] Stopping server (PID $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    local cid
    cid=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
    if [[ -n "$cid" ]]; then
        docker stop "$cid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "============================================"
echo "  LLM Inference Benchmark"
echo "  Model   : $MODEL_ID"
echo "  GPUs    : $GPUS"
echo "  Backend : $BACKEND"
echo "============================================"
echo ""

# ── Step 1: Download model ──
echo "[1/3] Ensuring model is downloaded..."
bash "$REPO_ROOT/nodes/ubuntu26-node1-server/download-model.sh" "$MODEL_ID"
echo ""

# ── Step 2: Start server ──
echo "[2/3] Starting $BACKEND server..."
bash "$SERVE_SCRIPT" "$MODEL_ID" "$GPUS" "$PORT" &
SERVER_PID=$!

echo "  Waiting for server to be ready..."
for i in $(seq 1 120); do
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
    echo "ERROR: Server failed to become ready within 240s." >&2
    exit 1
fi
echo ""

# ── Step 3: Run AIPerf benchmark ──
echo "[3/3] Running AIPerf benchmark..."
bash "$LLM_DIR/bench/bench-aiperf.sh" "http://localhost:$PORT" "$MODEL_NAME" "$MODEL_ID"

echo ""
echo "============================================"
echo "  Benchmark complete."
echo "============================================"
