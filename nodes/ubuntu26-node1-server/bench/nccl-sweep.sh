#!/bin/bash
# NCCL parameter sweep — test multiple NCCL configurations with vLLM TP=4.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/bench/nccl-sweep.sh [QUICK|FULL]
#
#   QUICK (default): 30 requests per config, ~30 min total
#   FULL           : 100 requests per config, ~90 min total
#
# Each test: start vLLM TP=4 → health check → AIPerf → stop → next config.
# Results are saved to tmp/benchmark-results/nccl-sweep/
#
# Prerequisites: model downloaded, aiperf image built, IOMMU disabled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MODE="${1:-QUICK}"
MODEL_ID="Qwen/Qwen3.6-27B"
MODEL_ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/$MODEL_ORG/$MODEL_NAME"
GPUS="0,1,2,3"
TP_SIZE=4
PORT=8010  # Use non-default port to avoid conflicts
VLLM_IMAGE="vllm/vllm-openai:latest"
AIPERF_IMAGE="aiperf:latest"

if [[ "$MODE" == "FULL" ]]; then
    NUM_PROMPTS=100
    NUM_REQUESTS=100
    WARMUP=10
else
    NUM_PROMPTS=30
    NUM_REQUESTS=30
    WARMUP=5
fi
CONCURRENCY=16
OSL=4096

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/nccl-sweep"
mkdir -p "$RESULT_DIR"
SUMMARY_FILE="$RESULT_DIR/sweep_${TIMESTAMP}.csv"
MAIN_LOG="$RESULT_DIR/sweep_${TIMESTAMP}.log"

# ── NCCL configurations ──
# Each entry: "label|NCCL_P2P_LEVEL|NCCL_MIN_NCHANNELS|NCCL_PROTO|NCCL_P2P_DISABLE|NCCL_ALLOC_P2P_NET_LL_BUFFERS"
# Empty string = unset (use NCCL default)
CONFIGS=(
    "baseline|||||"
    "phb+nch8|PHB|8|||1"
    "sys+nch8|SYS|8|||1"
    "phb+nch16|PHB|16|||1"
    "phb+nch8+LL|PHB|8|LL||1"
    "p2p-off+nch16||16||1|"
)

# ── Pre-checks ──
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2
    exit 1
fi

for img in "$VLLM_IMAGE" "$AIPERF_IMAGE"; do
    if ! docker image inspect "$img" &>/dev/null; then
        echo "ERROR: Image not found: $img" >&2
        exit 1
    fi
done

if [[ ! -d "$MODEL_DIR" ]]; then
    echo "ERROR: Model not found: $MODEL_DIR" >&2
    exit 1
fi

# Write CSV header
echo "label,p2p_level,min_nchannels,proto,p2p_disable,output_tok_s,latency_avg_ms,latency_p50_ms,e2e_tok_s,avg_output_len,duration_sec,errors" > "$SUMMARY_FILE"

cleanup() {
    local cid
    cid=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
    [[ -n "$cid" ]] && docker stop "$cid" 2>/dev/null || true
}
trap cleanup EXIT

log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$MAIN_LOG"
}

# ── Run one test ──
run_test() {
    local label="$1"
    local p2p_level="$2"
    local min_nch="$3"
    local proto="$4"
    local p2p_disable="$5"
    local alloc_ll="$6"

    log ""
    log "============================================"
    log "  Config : $label"
    log "  P2P    : ${p2p_level:-(default)}"
    log "  NCH    : ${min_nch:-(default)}"
    log "  Proto  : ${proto:-(default)}"
    log "  P2P dis: ${p2p_disable:-0}"
    log "============================================"

    # Build NCCL env array
    local nccl_env=()
    [[ -n "$p2p_level" ]] && nccl_env+=(-e "NCCL_P2P_LEVEL=$p2p_level")
    [[ -n "$min_nch" ]] && nccl_env+=(-e "NCCL_MIN_NCHANNELS=$min_nch")
    [[ -n "$proto" ]] && nccl_env+=(-e "NCCL_PROTO=$proto")
    [[ -n "$p2p_disable" ]] && nccl_env+=(-e "NCCL_P2P_DISABLE=$p2p_disable")
    [[ -n "$alloc_ll" ]] && nccl_env+=(-e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=$alloc_ll")
    # Always set these
    nccl_env+=(-e "NCCL_IB_DISABLE=1")
    nccl_env+=(-e "OMP_NUM_THREADS=8")

    # Stop any leftover container
    cleanup

    log "  Starting vLLM server..."
    docker run --rm -d \
        --name "nccl-sweep" \
        --gpus all \
        -e "CUDA_VISIBLE_DEVICES=$GPUS" \
        "${nccl_env[@]}" \
        -e "HOME=/tmp" \
        --user "$(id -u):$(id -g)" \
        --ipc=host \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -p "$PORT:8000" \
        -v "$MODEL_DIR:/models:ro" \
        "$VLLM_IMAGE" \
        --model "/models" \
        --served-model-name "$MODEL_NAME" \
        --trust-remote-code \
        --tensor-parallel-size "$TP_SIZE" \
        --max-model-len 32768 \
        --host 0.0.0.0 \
        --port 8000

    log "  Waiting for server..."
    for i in $(seq 1 300); do
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" == "200" ]]; then
            log "  Server ready."
            break
        fi
        sleep 2
    done

    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" != "200" ]]; then
        log "  ERROR: Server failed to start. Skipping."
        echo "$label,$p2p_level,$min_nch,$proto,$p2p_disable,FAIL,FAIL,FAIL,FAIL,FAIL,FAIL,FAIL" >> "$SUMMARY_FILE"
        cleanup
        return 1
    fi

    # Smoke test
    log "  Smoke test..."
    if ! curl -s --max-time 30 "http://localhost:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":8}" \
        >/dev/null 2>&1; then
        log "  ERROR: Smoke test failed. Skipping benchmark."
        echo "$label,$p2p_level,$min_nch,$proto,$p2p_disable,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL" >> "$SUMMARY_FILE"
        cleanup
        return 1
    fi
    log "  Smoke test PASS"

    # Run AIPerf
    local result_file="$RESULT_DIR/aiperf_${label}_${TIMESTAMP}.log"
    log "  Running benchmark ($NUM_REQUESTS requests, conc=$CONCURRENCY)..."

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
            --url 'http://localhost:$PORT' \
            --model '$MODEL_NAME' \
            --tokenizer '$MODEL_ID' \
            --num-prompts '$NUM_PROMPTS' \
            --num-requests '$NUM_REQUESTS' \
            --num-warmup-requests '$WARMUP' \
            --concurrency '$CONCURRENCY' \
            --osl '$OSL' \
            --artifact-dir /results" \
        2>&1 | tee "$result_file"

    # Extract key metrics
    local out_tok_s lat_avg lat_p50 e2e_tok_s avg_out_len duration errors
    out_tok_s=$(grep "Output Token Throughput" "$result_file" | grep -oP '│\s*\K[0-9.]+\s*(?=│)' | head -1 | tr -d ' ')
    lat_avg=$(grep -A1 "Request Latency" "$result_file" | tail -1 | grep -oP '│\s*\K[0-9,.]+\s*(?=│)' | head -1 | tr -d ' ,')
    lat_p50=$(grep -A1 "Request Latency" "$result_file" | tail -1 | grep -oP '│\s*[0-9,.]+\s*│\s*\K[0-9,.]+\s*(?=│)' | head -1 | tr -d ' ,')
    e2e_tok_s=$(grep "E2E Output Token" "$result_file" | grep -oP '│\s*\K[0-9.]+\s*(?=│)' | head -1 | tr -d ' ')
    avg_out_len=$(grep "Output Sequence Length" "$result_file" | grep -oP '│\s*\K[0-9,.]+\s*(?=│)' | head -1 | tr -d ' ,')
    duration=$(grep "Benchmark Duration:" "$result_file" | grep -oP '[0-9.]+' | head -1)
    errors=$(grep -c "InvalidInferenceResultError\|Error" "$result_file" 2>/dev/null || echo 0)

    log "  Result: out_tok_s=${out_tok_s:-N/A} lat_avg=${lat_avg:-N/A}ms duration=${duration:-N/A}s"

    echo "$label,$p2p_level,$min_nch,$proto,$p2p_disable,${out_tok_s:-N/A},${lat_avg:-N/A},${lat_p50:-N/A},${e2e_tok_s:-N/A},${avg_out_len:-N/A},${duration:-N/A},${errors:-0}" >> "$SUMMARY_FILE"

    cleanup
    log "  Done with $label"
}

# ── Main ──
echo ""
echo "============================================"
echo "  NCCL Parameter Sweep"
echo "  Model  : $MODEL_ID"
echo "  GPUs   : $GPUS (TP=$TP_SIZE)"
echo "  Backend: vLLM"
echo "  Mode   : $MODE ($NUM_REQUESTS req/config)"
echo "  Configs: ${#CONFIGS[@]}"
echo "  Results: $SUMMARY_FILE"
echo "============================================"
echo ""

log "NCCL Sweep started at $(date)"
log "Mode: $MODE, Requests per config: $NUM_REQUESTS"
log ""

for cfg in "${CONFIGS[@]}"; do
    IFS='|' read -r label p2p nch proto p2pdis alloc_ll <<< "$cfg"
    run_test "$label" "$p2p" "$nch" "$proto" "$p2pdis" "$alloc_ll"
done

# ── Summary ──
log ""
log "============================================"
log "  Sweep Complete!"
log "============================================"
log ""
log "Results CSV: $SUMMARY_FILE"
log ""
echo ""
echo "=== NCCL Sweep Results ==="
column -t -s',' "$SUMMARY_FILE"
echo ""
echo "Full results: $RESULT_DIR/"
echo "Summary CSV : $SUMMARY_FILE"
