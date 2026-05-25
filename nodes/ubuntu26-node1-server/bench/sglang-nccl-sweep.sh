#!/bin/bash
# SGLang NCCL sweep — test NCCL configurations for
# voipmonitor/sglang:test-cu132 with Qwen3.5-7B.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/bench/sglang-nccl-sweep.sh [QUICK|FULL] [TP_SIZE]
#
#   QUICK (default): 30 req/config, ~7 configs, ~40 min
#   FULL           : 100 req/config, ~7 configs, ~120 min
#   TP_SIZE        : 2 (default) or 4
#
# Results saved to tmp/benchmark-results/sglang-nccl-sweep/
#
# Prerequisites:
#   - Qwen3.5-7B downloaded to /data/work/models/Qwen/Qwen3.5-7B/
#   - aiperf:latest Docker image built

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MODE="${1:-QUICK}"
TP_SIZE="${2:-2}"

MODEL_ID="${AIPERF_MODEL_ID:-Qwen/Qwen3.5-4B}"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="${AIPERF_MODEL_DIR:-/data/work/models/Qwen/$MODEL_NAME}"
SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
AIPERF_IMAGE="aiperf:latest"
CACHE_DIR="/data/cache/sglang_jit"
PORT=8020

if [[ "$TP_SIZE" == "4" ]]; then
    GPUS="0,1,2,3"
elif [[ "$TP_SIZE" == "2" ]]; then
    GPUS="0,1"
else
    echo "ERROR: TP_SIZE must be 2 or 4 (got $TP_SIZE). TP=1 use sglang-4gpu-parallel.sh." >&2
    exit 1
fi

if [[ "$MODE" == "FULL" ]]; then
    NUM_PROMPTS=100; NUM_REQUESTS=100; WARMUP=10
else
    NUM_PROMPTS=30;  NUM_REQUESTS=30;  WARMUP=5
fi
CONCURRENCY=16
OSL=4096

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/sglang-nccl-sweep"
mkdir -p "$RESULT_DIR"
SUMMARY_FILE="$RESULT_DIR/sweep_${TP_SIZE}gpu_${TIMESTAMP}.csv"
MAIN_LOG="$RESULT_DIR/sweep_${TP_SIZE}gpu_${TIMESTAMP}.log"

# ── NCCL configurations ──
# Format: "label|NCCL_P2P_LEVEL|NCCL_MIN_NCHANNELS|NCCL_PROTO|NCCL_P2P_DISABLE|NCCL_ALLOC_P2P_NET_LL_BUFFERS"
CONFIGS=(
    "baseline|||||"
    "phb+nch8|PHB|8|||1"
    "phb+nch8+LL|PHB|8|LL||1"
    "phb+nch16|PHB|16|||1"
    "phb+nch16+LL|PHB|16|LL||1"
    "p2p-off+nch16||16||1|"
    "p2p-off+nch16+LL||16|LL|1|"
)

# ── Pre-checks ──
if ! docker info &>/dev/null; then echo "ERROR: Docker not accessible." >&2; exit 1; fi
for img in "$SGLANG_IMAGE" "$AIPERF_IMAGE"; do
    if ! docker image inspect "$img" &>/dev/null; then
        echo "ERROR: Image not found: $img" >&2; exit 1
    fi
done
if [[ ! -d "$MODEL_DIR" ]] || [[ ! -f "$MODEL_DIR/config.json" ]]; then
    echo "ERROR: Model not found: $MODEL_DIR" >&2; exit 1
fi

# CSV header
echo "label,p2p_level,nchannels,proto,p2p_disable,output_tok_s,latency_avg_ms,latency_p50_ms,e2e_tok_s,avg_output_len,duration_sec,errors" > "$SUMMARY_FILE"

cleanup() {
    local cid
    cid=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
    [[ -n "$cid" ]] && docker stop "$cid" 2>/dev/null || true
}
trap cleanup EXIT

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$MAIN_LOG"; }

run_test() {
    local label="$1" p2p="$2" nch="$3" proto="$4" p2pdis="$5" alloc_ll="$6"

    log ""
    log "============================================"
    log "  Config: $label  (TP=$TP_SIZE  GPUs=$GPUS)"
    log "  P2P=$p2p  NCH=$nch  Proto=$proto  P2P-dis=$p2pdis"
    log "============================================"

    cleanup
    mkdir -p "$CACHE_DIR"

    local nccl_env=()
    [[ -n "$p2p" ]]      && nccl_env+=(-e "NCCL_P2P_LEVEL=$p2p")
    [[ -n "$nch" ]]      && nccl_env+=(-e "NCCL_MIN_NCHANNELS=$nch")
    [[ -n "$nch" ]]      && nccl_env+=(-e "NCCL_MAX_NCHANNELS=$nch")
    [[ -n "$proto" ]]    && nccl_env+=(-e "NCCL_PROTO=$proto")
    [[ -n "$p2pdis" ]]   && nccl_env+=(-e "NCCL_P2P_DISABLE=$p2pdis")
    [[ -n "$alloc_ll" ]] && nccl_env+=(-e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=$alloc_ll")
    nccl_env+=(-e "NCCL_IB_DISABLE=1")
    nccl_env+=(-e "NCCL_CUMEM_HOST_ENABLE=0")
    nccl_env+=(-e "OMP_NUM_THREADS=8")
    nccl_env+=(-e "XDG_CACHE_HOME=/cache")
    nccl_env+=(-e "FLASHINFER_WORKSPACE_BASE=/cache/flashinfer")
    nccl_env+=(-e "TORCH_EXTENSIONS_DIR=/cache/torch_extensions")
    nccl_env+=(-e "TRITON_CACHE_DIR=/cache/triton")
    nccl_env+=(-e "TVM_FFI_CACHE_DIR=/cache/tvm-ffi")

    HF_ENV=()
    [[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

    log "  Starting SGLang server (TP=$TP_SIZE)..."
    docker run --rm -d \
        --name "sglang-sweep" \
        --gpus all \
        -e "CUDA_VISIBLE_DEVICES=$GPUS" \
        -e "SGLANG_ENABLE_JIT_DEEPGEMM=0" \
        "${nccl_env[@]}" \
        "${HF_ENV[@]}" \
        -e "HOME=/cache" \
        --user "$(id -u):$(id -g)" \
        --ipc=host \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -p "$PORT:8000" \
        -v "$MODEL_DIR:/models:ro" \
        -v "$CACHE_DIR:/cache:rw" \
        "$SGLANG_IMAGE" \
        sglang serve \
            --model-path "/models" \
            --served-model-name "$MODEL_NAME" \
            --tp-size "$TP_SIZE" \
            --context-length 32768 \
            --host 0.0.0.0 \
            --port 8000 \
            --attention-backend flashinfer \
            --kv-cache-dtype fp8_e5m2

    log "  Waiting for server..."
    local started=0
    for i in $(seq 1 300); do
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" == "200" ]]; then
            log "  Server ready (${i}x2s)."
            started=1
            break
        fi
        sleep 2
    done
    if [[ "$started" == "0" ]]; then
        log "  ERROR: Server failed to start."
        echo "$label,$p2p,$nch,$proto,$p2pdis,FAIL,FAIL,FAIL,FAIL,FAIL,FAIL,FAIL" >> "$SUMMARY_FILE"
        cleanup; return 1
    fi

    # Smoke test
    if ! curl -s --max-time 60 "http://localhost:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":8}" \
        >/dev/null 2>&1; then
        log "  ERROR: Smoke test failed."
        echo "$label,$p2p,$nch,$proto,$p2pdis,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL,SMOKE_FAIL" >> "$SUMMARY_FILE"
        cleanup; return 1
    fi
    log "  Smoke test PASS"

    # Run AIPerf
    local result_file="$RESULT_DIR/aiperf_${label}_tp${TP_SIZE}_${TIMESTAMP}.log"
    log "  Running benchmark ($NUM_REQUESTS req, conc=$CONCURRENCY)..."

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

    # Extract metrics via Python (AIPerf uses multi-line Unicode table rows)
    local parsed
    parsed=$(python3 -c "
import re
t = open('$result_file').read()
lines = t.split('\n')
def fm(kw_parts):
    for i, l in enumerate(lines):
        if '│' not in l: continue
        p = [c.strip() for c in l.split('│')]
        if len(p) < 3 or not p[2]: continue
        c1 = p[1]
        matched = 0
        for k in kw_parts:
            if matched == 0:
                if not c1.startswith(k): break
            elif k not in c1: break
            matched += 1
        if matched == len(kw_parts):
            return p
        elif matched > 0:
            ok = True
            for j, kw in enumerate(kw_parts[matched:], 1):
                if i + j >= len(lines): ok = False; break
                nl = lines[i + j]
                if '│' not in nl: ok = False; break
                np = [c.strip() for c in nl.split('│')]
                if len(np) < 2 or kw not in np[1]: ok = False; break
            if ok: return p
    return []
def c(r, n):
    return r[n].replace(',','') if len(r) > n else 'N/A'
r1 = fm(['Output', 'Token'])
r2 = fm(['Request', 'Latency'])
r3 = fm(['E2E', 'Output'])
r4 = fm(['Output', 'Sequence'])
du = re.search(r'Benchmark Duration:\s+([0-9.]+)', t)
du = du.group(1) if du else 'N/A'
er = t.count('InvalidInferenceResultError') + t.count('Traceback')
print(f'{c(r1,2)}|{c(r2,2)}|{c(r2,7)}|{c(r3,2)}|{c(r4,2)}|{du}|{er}')
")
    IFS='|' read -r out_tok_s lat_avg lat_p50 e2e_tok_s avg_out_len duration errors <<< "$parsed"

    log "  Result: out_tok_s=${out_tok_s:-N/A}  lat_avg=${lat_avg:-N/A}ms  duration=${duration:-N/A}s"

    echo "$label,$p2p,$nch,$proto,$p2pdis,${out_tok_s:-N/A},${lat_avg:-N/A},${lat_p50:-N/A},${e2e_tok_s:-N/A},${avg_out_len:-N/A},${duration:-N/A},${errors:-0}" >> "$SUMMARY_FILE"
    cleanup
}

# ── Main ──
echo ""
echo "============================================"
echo "  SGLang NCCL Sweep"
echo "  Model   : $MODEL_ID"
echo "  GPUs    : $GPUS  (TP=$TP_SIZE)"
echo "  Image   : $SGLANG_IMAGE (CUDA 13.2)"
echo "  Mode    : $MODE ($NUM_REQUESTS req/config)"
echo "  Configs : ${#CONFIGS[@]}"
echo "  Results : $SUMMARY_FILE"
echo "============================================"
echo ""

log "SGLang NCCL Sweep started at $(date)"
log "Mode: $MODE | TP=$TP_SIZE | GPUs=$GPUS | Req/config: $NUM_REQUESTS"
log "CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
log "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
log ""

for cfg in "${CONFIGS[@]}"; do
    IFS='|' read -r label p2p nch proto p2pdis alloc_ll <<< "$cfg"
    run_test "$label" "$p2p" "$nch" "$proto" "$p2pdis" "$alloc_ll"
done

log ""
log "============================================"
log "  Sweep Complete!"
log "============================================"
echo ""
echo "=== SGLang NCCL Sweep Results (TP=$TP_SIZE) ==="
column -t -s',' "$SUMMARY_FILE"
echo ""
echo "Full results: $RESULT_DIR/"
echo "Summary CSV : $SUMMARY_FILE"
