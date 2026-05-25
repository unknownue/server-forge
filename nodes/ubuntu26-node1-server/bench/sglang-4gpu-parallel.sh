#!/bin/bash
# 4-GPU parallel TP=1 test — run 4 independent SGLang instances
# (one per GPU) and benchmark them in parallel.
#
# This validates that each GPU can independently serve Qwen3.5-7B
# and measures per-GPU + aggregate throughput.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/bench/sglang-4gpu-parallel.sh [QUICK|FULL]
#
#   QUICK (default): 30 req/instance, ~15 min
#   FULL           : 100 req/instance, ~30 min
#
# Results saved to tmp/benchmark-results/sglang-4gpu-parallel/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MODE="${1:-QUICK}"

MODEL_ID="${AIPERF_MODEL_ID:-Qwen/Qwen3.5-4B}"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="${AIPERF_MODEL_DIR:-/data/work/models/Qwen/$MODEL_NAME}"
SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
AIPERF_IMAGE="aiperf:latest"
CACHE_DIR="/data/cache/sglang_jit"

# ── Per-instance config ──
# Each GPU gets its own server on a dedicated port.
GPUS=(0 1 2 3)
PORTS=(8000 8001 8002 8003)
NUM_GPUS="${#GPUS[@]}"

if [[ "$MODE" == "FULL" ]]; then
    NUM_PROMPTS=100; NUM_REQUESTS=100; WARMUP=10
else
    NUM_PROMPTS=30;  NUM_REQUESTS=30;  WARMUP=5
fi
CONCURRENCY=16
OSL=4096

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/sglang-4gpu-parallel"
mkdir -p "$RESULT_DIR"
SUMMARY_FILE="$RESULT_DIR/parallel_${TIMESTAMP}.csv"
MAIN_LOG="$RESULT_DIR/parallel_${TIMESTAMP}.log"

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

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$MAIN_LOG"; }

cleanup_all() {
    log "[cleanup] Stopping all SGLang instances..."
    for p in "${PORTS[@]}"; do
        local cid
        cid=$(docker ps -q --filter "publish=$p" 2>/dev/null)
        [[ -n "$cid" ]] && docker stop "$cid" 2>/dev/null || true
    done
}
trap cleanup_all EXIT

# ── Start all instances ──
start_all() {
    mkdir -p "$CACHE_DIR"

    local nccl_common=(
        -e "NCCL_P2P_LEVEL=PHB"
        -e "NCCL_MIN_NCHANNELS=8"
        -e "NCCL_MAX_NCHANNELS=8"
        -e "NCCL_IB_DISABLE=1"
        -e "NCCL_CUMEM_HOST_ENABLE=0"
        -e "OMP_NUM_THREADS=8"
        -e "SGLANG_ENABLE_JIT_DEEPGEMM=0"
        -e "HOME=/cache"
        -e "XDG_CACHE_HOME=/cache" \
        -e "FLASHINFER_WORKSPACE_BASE=/cache/flashinfer" \
        -e "TORCH_EXTENSIONS_DIR=/cache/torch_extensions" \
        -e "TRITON_CACHE_DIR=/cache/triton" \
        -e "TVM_FFI_CACHE_DIR=/cache/tvm-ffi" \
    )
    HF_ENV=()
    [[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

    log "Starting $NUM_GPUS SGLang instances (TP=1, one per GPU)..."
    for i in "${!GPUS[@]}"; do
        local gpu="${GPUS[$i]}"
        local port="${PORTS[$i]}"
        local name="sglang-gpu${gpu}"

        log "  GPU $gpu → port $port (container: $name)"
        docker run --rm -d \
            --name "$name" \
            --gpus all \
            -e "CUDA_VISIBLE_DEVICES=$gpu" \
            "${nccl_common[@]}" \
            "${HF_ENV[@]}" \
            --user "$(id -u):$(id -g)" \
            --ipc=host \
            -v /etc/passwd:/etc/passwd:ro \
            -v /etc/group:/etc/group:ro \
            -p "$port:8000" \
            -v "$MODEL_DIR:/models:ro" \
            -v "$CACHE_DIR:/cache:rw" \
            "$SGLANG_IMAGE" \
            sglang serve \
                --model-path "/models" \
                --served-model-name "$MODEL_NAME" \
                --tp-size 1 \
                --context-length 32768 \
                --host 0.0.0.0 \
                --port 8000 \
                --attention-backend flashinfer \
                --kv-cache-dtype fp8_e5m2
    done
}

# ── Wait for all instances to be healthy ──
wait_all() {
    log "Waiting for all $NUM_GPUS instances to be ready..."
    local all_ready=0
    for i in $(seq 1 300); do
        all_ready=1
        for port in "${PORTS[@]}"; do
            if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/health" 2>/dev/null)" != "200" ]]; then
                all_ready=0
                break
            fi
        done
        if [[ "$all_ready" == "1" ]]; then
            log "All $NUM_GPUS instances ready (${i}x2s)."
            return 0
        fi
        sleep 2
    done
    log "ERROR: Not all instances became ready."
    return 1
}

# ── Smoke test all instances ──
smoke_all() {
    local all_pass=1
    for i in "${!GPUS[@]}"; do
        local gpu="${GPUS[$i]}"
        local port="${PORTS[$i]}"
        if curl -s --max-time 30 "http://localhost:$port/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":8}" \
            >/dev/null 2>&1; then
            log "  Smoke PASS  GPU$gpu (port $port)"
        else
            log "  Smoke FAIL  GPU$gpu (port $port)"
            all_pass=0
        fi
    done
    return $(( 1 - all_pass ))
}

# ── Run benchmark on a single instance ──
bench_one() {
    local gpu="$1" port="$2" label="$3"
    local result_file="$RESULT_DIR/aiperf_${label}_${TIMESTAMP}.log"

    local out_tok_s lat_p50 e2e_tok_s duration errors
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
            --url 'http://localhost:$port' \
            --model '$MODEL_NAME' \
            --tokenizer '$MODEL_ID' \
            --num-prompts '$NUM_PROMPTS' \
            --num-requests '$NUM_REQUESTS' \
            --num-warmup-requests '$WARMUP' \
            --concurrency '$CONCURRENCY' \
            --osl '$OSL' \
            --artifact-dir /results" \
        2>&1 | tee "$result_file"

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
du = re.search(r'Benchmark Duration:\s+([0-9.]+)', t)
du = du.group(1) if du else 'N/A'
er = t.count('InvalidInferenceResultError') + t.count('Traceback')
print(f'{c(r1,2)}|{c(r2,7)}|{c(r3,2)}|{du}|{er}')
")
    echo "$parsed"
}

# ── Main ──
echo ""
echo "============================================"
echo "  4-GPU Parallel TP=1 Test"
echo "  Model    : $MODEL_ID"
echo "  GPUs     : ${GPUS[*]}  (TP=1 each)"
echo "  Image    : $SGLANG_IMAGE (CUDA 13.2)"
echo "  Mode     : $MODE ($NUM_REQUESTS req/instance)"
echo "  Instances: $NUM_GPUS"
echo "  Results  : $RESULT_DIR/"
echo "============================================"
echo ""

# ── Phase 1: Start all instances ──
log "=== Phase 1: Starting $NUM_GPUS instances ==="
start_all
wait_all || { log "ERROR: Startup failed."; exit 1; }

# ── Phase 2: Smoke test ──
log ""
log "=== Phase 2: Smoke tests ==="
smoke_all || log "WARNING: Some smoke tests failed."

# ── Phase 3: Sequential benchmark (per-GPU baseline) ──
log ""
log "=== Phase 3: Sequential per-GPU benchmarks ==="

# CSV header
echo "gpu,port,output_tok_s,latency_p50_ms,e2e_tok_s,duration_sec,errors" > "$SUMMARY_FILE"

declare -A TOK_S
declare -A E2E_TOK_S
total_tok_s=0
total_e2e=0
for i in "${!GPUS[@]}"; do
    gpu="${GPUS[$i]}"
    port="${PORTS[$i]}"
    log ""
    log "  Benchmarking GPU$gpu (port $port)..."

    result=$(bench_one "$gpu" "$port" "gpu${gpu}")
    IFS='|' read -r out_tok_s lat_p50 e2e_tok_s duration errors <<< "$result"

    log "  GPU$gpu: out_tok_s=$out_tok_s  p50=$lat_p50  e2e=$e2e_tok_s  duration=$duration"

    echo "$gpu,$port,$out_tok_s,$lat_p50,$e2e_tok_s,$duration,$errors" >> "$SUMMARY_FILE"
    TOK_S[$gpu]="$out_tok_s"
    E2E_TOK_S[$gpu]="$e2e_tok_s"

    if [[ "$out_tok_s" =~ ^[0-9.]+$ ]]; then
        total_tok_s=$(python3 -c "print($total_tok_s + $out_tok_s)")
    fi
    if [[ "$e2e_tok_s" =~ ^[0-9.]+$ ]]; then
        total_e2e=$(python3 -c "print($total_e2e + $e2e_tok_s)")
    fi
done

# ── Phase 4: Parallel benchmark (all instances simultaneously) ──
log ""
log "=== Phase 4: Parallel benchmark (all $NUM_GPUS instances) ==="

parallel_pids=()
parallel_results="$RESULT_DIR/parallel_tok_s_${TIMESTAMP}.tmp"
> "$parallel_results"

for i in "${!GPUS[@]}"; do
    gpu="${GPUS[$i]}"
    port="${PORTS[$i]}"
    (
        result=$(bench_one "$gpu" "$port" "parallel-gpu${gpu}")
        IFS='|' read -r out_tok_s lat_p50 e2e_tok_s duration errors <<< "$result"
        echo "$gpu|$out_tok_s|$e2e_tok_s|$duration" >> "$parallel_results"
        log "  Parallel GPU$gpu: out_tok_s=$out_tok_s  e2e=$e2e_tok_s  duration=$duration"
    ) &
    parallel_pids+=($!)
done

log "  Waiting for all parallel benchmarks to complete..."
for pid in "${parallel_pids[@]}"; do
    wait "$pid" || true
done

# Aggregate parallel results
parallel_agg_out=0
parallel_agg_e2e=0
while IFS='|' read -r gpu out_tok_s e2e_tok_s duration; do
    if [[ "$out_tok_s" =~ ^[0-9.]+$ ]]; then
        parallel_agg_out=$(python3 -c "print($parallel_agg_out + $out_tok_s)")
    fi
    if [[ "$e2e_tok_s" =~ ^[0-9.]+$ ]]; then
        parallel_agg_e2e=$(python3 -c "print($parallel_agg_e2e + $e2e_tok_s)")
    fi
done < "$parallel_results"
rm -f "$parallel_results"

# ── Summary ──
log ""
log "============================================"
log "  Test Complete!"
log "============================================"
log ""
log "=== Per-GPU Results (sequential) ==="
column -t -s',' "$SUMMARY_FILE"
log ""
log "Aggregate sequential: output=${total_tok_s} tok/s  e2e=${total_e2e} tok/s"
log "Aggregate parallel  : output=${parallel_agg_out} tok/s  e2e=${parallel_agg_e2e} tok/s"
log ""
echo ""
echo "=== 4-GPU Parallel Test Results ==="
column -t -s',' "$SUMMARY_FILE"
echo ""
echo "Sequential aggregate : output=${total_tok_s} tok/s  e2e=${total_e2e} tok/s"
echo "Parallel aggregate   : output=${parallel_agg_out} tok/s  e2e=${parallel_agg_e2e} tok/s"
echo ""
echo "Full logs: $RESULT_DIR/"
echo "Summary  : $SUMMARY_FILE"
