#!/bin/bash
# Compare different GPU allocation strategies for game server deployment.
#
# Tests each configuration with simulated multi-agent workload and
# AIPerf benchmarks to quantify throughput differences.
#
# Runs against sequentially started configs — not designed to run
# all configs simultaneously (that would need >4 GPUs).
#
# Usage:
#   bash nodes/ubuntu26-node1-server/game-server/test/compare-configs.sh [MODE]
#
# MODE:
#   quick  — 20 requests per test, ~10 min per config  (default)
#   full   — 100 requests per test, ~30 min per config
#   aip perf-only — AIPerf only, no agent simulation (~5 min per config)
#
# Output: comparison CSV + summary in game-server/results/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GAME_SERVER_DIR="$SCRIPT_DIR/.."
RESULT_DIR="$GAME_SERVER_DIR/results"
mkdir -p "$RESULT_DIR"

MODE="${1:-quick}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
COMPARISON_CSV="$RESULT_DIR/comparison_${TIMESTAMP}.csv"
MAIN_LOG="$RESULT_DIR/comparison_${TIMESTAMP}.log"

SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
AIPERF_IMAGE="aiperf:latest"
CACHE_DIR="/data/cache/sglang_jit"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$MAIN_LOG"; }

# ── Pre-checks ──
if ! docker info &>/dev/null; then echo "ERROR: Docker not accessible." >&2; exit 1; fi
for img in "$SGLANG_IMAGE" "$AIPERF_IMAGE"; do
    if ! docker image inspect "$img" &>/dev/null; then
        echo "ERROR: Image not found: $img" >&2; exit 1
    fi
done

# ── Config definitions ──
# Each config defines: name, description, and per-instance (gpu, model_dir, port, tp)
# Comparison now includes FP8 quantization as a key variable.

declare -A CFG_NAME CFG_DESC
CONFIG_NAMES=()

# Config A: Plan A — 2× 27B FP8 TP=1 + 2× 4B FP8 TP=1 (zero-download)
CFG_NAME[A]="plan-a-zero-dl"
CFG_DESC[A]="Plan A: 2× 27B FP8 TP=1 + 2× 4B FP8 TP=1"
CONFIG_NAMES+=(A)

# Config B: 4× 4B BF16 TP=1 (baseline max throughput)
CFG_NAME[B]="baseline-4x4B-bf16"
CFG_DESC[B]="Baseline: 4× 4B BF16 TP=1 (no FP8)"
CONFIG_NAMES+=(B)

# Config C: 4× 4B FP8 TP=1 (max throughput with FP8)
CFG_NAME[C]="max-tput-4x4B-fp8"
CFG_DESC[C]="Max TP: 4× 4B FP8 TP=1"
CONFIG_NAMES+=(C)

# Config D: 2× 27B FP8 TP=1 (dual 27B, no 4B)
CFG_NAME[D]="dual-27b-fp8"
CFG_DESC[D]="Dual 27B FP8: 2× 27B FP8 TP=1"
CONFIG_NAMES+=(D)

# Config E: 27B BF16 TP=2 + 2× 4B BF16 (old phase1, for reference)
CFG_NAME[E]="old-phase1-bf16"
CFG_DESC[E]="Old Phase1: 27B BF16 TP=2 + 2× 4B BF16"
CONFIG_NAMES+=(E)

declare -A CFG_FP8
CFG_FP8[A]=1
CFG_FP8[B]=0
CFG_FP8[C]=1
CFG_FP8[D]=1
CFG_FP8[E]=0

# ── Helper: cleanup all SGLang containers ──
cleanup_all() {
    log "  [cleanup] Stopping all SGLang containers..."
    for cid in $(docker ps -q --filter "name=gs-compare-" 2>/dev/null); do
        docker stop "$cid" 2>/dev/null || true
    done
    # Also stop any on our test ports
    for port in 8000 8001 8002 8003; do
        local cid
        cid=$(docker ps -q --filter "publish=$port" 2>/dev/null)
        [[ -n "$cid" ]] && docker stop "$cid" 2>/dev/null || true
    done
}

# ── Helper: start instances for a given config ──
start_config() {
    local cfg="$1"
    local -n instances="$2"  # array of "gpu:model:port:tp:name"

    log "  Starting instances for config: $cfg"

    for inst in "${instances[@]}"; do
        IFS=':' read -r gpu model_path port tp name <<< "$inst"

        local existing
        existing=$(docker ps -q --filter "name=$name" 2>/dev/null)
        [[ -n "$existing" ]] && docker stop "$existing" 2>/dev/null || true

        log "    $name: GPU=$gpu model=$(basename "$model_path") TP=$tp port=$port"
        local fp8_quant=""; [[ "${CFG_FP8[$cfg]:-0}" == "1" ]] && fp8_quant="--quantization fp8"

        docker run --rm -d \
            --name "$name" \
            --gpus all \
            -e "CUDA_VISIBLE_DEVICES=$gpu" \
            -e "SGLANG_ENABLE_JIT_DEEPGEMM=0" \
            -e "NCCL_P2P_LEVEL=PHB" \
            -e "NCCL_MIN_NCHANNELS=8" \
            -e "NCCL_MAX_NCHANNELS=8" \
            -e "NCCL_IB_DISABLE=1" \
            -e "NCCL_CUMEM_HOST_ENABLE=0" \
            -e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=1" \
            -e "OMP_NUM_THREADS=8" \
            -e "HOME=/cache" \
            -e "XDG_CACHE_HOME=/cache" \
            -e "FLASHINFER_WORKSPACE_BASE=/cache/flashinfer" \
            -e "TORCH_EXTENSIONS_DIR=/cache/torch_extensions" \
            -e "TRITON_CACHE_DIR=/cache/triton" \
            -e "TVM_FFI_CACHE_DIR=/cache/tvm-ffi" \
            --user "$(id -u):$(id -g)" \
            --ipc=host \
            -v /etc/passwd:/etc/passwd:ro \
            -v /etc/group:/etc/group:ro \
            -p "$port:8000" \
            -v "$model_path:/models:ro" \
            -v "$CACHE_DIR:/cache:rw" \
            "$SGLANG_IMAGE" \
            sglang serve \
                --model-path "/models" \
                --served-model-name "$(basename "$model_path")" \
                --tp-size "$tp" \
                --context-length 32768 \
                --host 0.0.0.0 \
                --port 8000 \
                --attention-backend flashinfer \
                --kv-cache-dtype fp8_e5m2 \
                ${fp8_quant} \
                --mem-fraction-static 0.85 \
                > /dev/null 2>&1
    done
}

# ── Helper: wait for a list of ports ──
wait_ports() {
    local -n pports="$1"
    for attempt in $(seq 1 300); do
        local all_ready=1
        for port in "${pports[@]}"; do
            if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/health" 2>/dev/null)" != "200" ]]; then
                all_ready=0
                break
            fi
        done
        if [[ "$all_ready" == "1" ]]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# ── Helper: run AIPerf on a port ──
run_aiperf() {
    local port="$1" model_name="$2" result_prefix="$3"
    local num_req="$4" concurrency="$5" osl="$6" warmup="$7"

    local result_file="$RESULT_DIR/${result_prefix}_aiperf_${TIMESTAMP}.log"
    local model_id="Qwen/$model_name"

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
            --model '$model_name' \
            --tokenizer '$model_id' \
            --num-prompts '$num_req' \
            --num-requests '$num_req' \
            --num-warmup-requests '$warmup' \
            --concurrency '$concurrency' \
            --osl '$osl' \
            --artifact-dir /results" \
        2>&1 | tee "$result_file"

    # Parse AIPerf output for key metrics
    python3 -c "
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
        if matched == len(kw_parts): return p
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
print(f'{c(r1,2)}|{c(r2,2)}|{c(r2,7)}|{c(r3,2)}|{du}')
"
}

# ── Main ──
echo ""
echo "============================================"
echo "  Configuration Comparison"
echo "  Mode : $MODE"
echo "============================================"
echo ""

# Set test parameters based on mode
case "$MODE" in
    quick)
        NUM_REQ=20; CONCURRENCY=8; OSL=2048; WARMUP=5
        ;;
    full)
        NUM_REQ=100; CONCURRENCY=16; OSL=4096; WARMUP=10
        ;;
    aip)
        NUM_REQ=30; CONCURRENCY=16; OSL=4096; WARMUP=5
        ;;
    *)
        echo "ERROR: Unknown mode '$MODE'. Choose: quick, full, aip" >&2
        exit 1
        ;;
esac

# CSV header
echo "config,instance,gpu,model,tp,tok_s,lat_avg_ms,lat_p50_ms,e2e_tok_s,duration_sec" > "$COMPARISON_CSV"

# ── Test each config ──
for cfg in "${CONFIG_NAMES[@]}"; do
    cfg_name="${CFG_NAME[$cfg]}"
    cfg_desc="${CFG_DESC[$cfg]}"

    log ""
    log "============================================"
    log "  Config: $cfg_name"
    log "  $cfg_desc"
    log "============================================"

    cleanup_all

    # Build instance list for this config
    declare -a instances
    declare -a test_ports

    MODELS_BASE="/data/work/models/Qwen"

    case "$cfg" in
        A)
            # Plan A: 2x 27B FP8 TP=1 + 2x 4B FP8 TP=1
            instances=(
                "0:${MODELS_BASE}/Qwen3.6-27B:8000:1:gs-compare-A-27b0"
                "1:${MODELS_BASE}/Qwen3.6-27B:8001:1:gs-compare-A-27b1"
                "2:${MODELS_BASE}/Qwen3.5-4B:8002:1:gs-compare-A-4b0"
                "3:${MODELS_BASE}/Qwen3.5-4B:8003:1:gs-compare-A-4b1"
            )
            test_ports=(8000 8001 8002 8003)
            ;;
        B)
            # Baseline: 4x 4B BF16 TP=1 (no FP8)
            instances=(
                "0:${MODELS_BASE}/Qwen3.5-4B:8000:1:gs-compare-B-4b0"
                "1:${MODELS_BASE}/Qwen3.5-4B:8001:1:gs-compare-B-4b1"
                "2:${MODELS_BASE}/Qwen3.5-4B:8002:1:gs-compare-B-4b2"
                "3:${MODELS_BASE}/Qwen3.5-4B:8003:1:gs-compare-B-4b3"
            )
            test_ports=(8000 8001 8002 8003)
            ;;
        C)
            # Max throughput: 4x 4B FP8 TP=1
            instances=(
                "0:${MODELS_BASE}/Qwen3.5-4B:8000:1:gs-compare-C-4b0"
                "1:${MODELS_BASE}/Qwen3.5-4B:8001:1:gs-compare-C-4b1"
                "2:${MODELS_BASE}/Qwen3.5-4B:8002:1:gs-compare-C-4b2"
                "3:${MODELS_BASE}/Qwen3.5-4B:8003:1:gs-compare-C-4b3"
            )
            test_ports=(8000 8001 8002 8003)
            ;;
        D)
            # Dual 27B FP8: 2x 27B FP8 TP=1
            instances=(
                "0:${MODELS_BASE}/Qwen3.6-27B:8000:1:gs-compare-D-27b0"
                "1:${MODELS_BASE}/Qwen3.6-27B:8001:1:gs-compare-D-27b1"
            )
            test_ports=(8000 8001)
            ;;
        E)
            # Old Phase1: 27B BF16 TP=2 + 2x 4B BF16 (reference)
            instances=(
                "0,1:${MODELS_BASE}/Qwen3.6-27B:8000:2:gs-compare-E-27b"
                "2:${MODELS_BASE}/Qwen3.5-4B:8001:1:gs-compare-E-4b0"
                "3:${MODELS_BASE}/Qwen3.5-4B:8002:1:gs-compare-E-4b1"
            )
            test_ports=(8000 8001 8002)
            ;;
    esac

    # Verify all models exist
    local missing=0
    for inst in "${instances[@]}"; do
        IFS=':' read -r _ model_path _ _ _ <<< "$inst"
        if [[ ! -f "$model_path/config.json" ]]; then
            log "  MISSING: $model_path"
            missing=1
        fi
    done
    if [[ "$missing" == "1" ]]; then
        log "  Skipping config $cfg_name — models missing."
        unset instances
        continue
    fi

    # Start config
    start_config "$cfg" instances
    log "  Waiting for servers to be ready..."
    if ! wait_ports test_ports; then
        log "  FAILED: servers did not become ready."
        cleanup_all
        unset instances
        continue
    fi
    log "  All servers ready."

    # Sequential AIPerf benchmark each instance
    log ""
    log "  === AIPerf benchmarks (sequential) ==="
    for inst in "${instances[@]}"; do
        IFS=':' read -r gpu model_path port tp _ <<< "$inst"
        local model_name
        model_name=$(basename "$model_path")
        local label="${cfg_name}_${model_name}_gpu${gpu//,/-}"

        log "    Benchmarking $model_name (GPU=$gpu TP=$tp port=$port)..."
        result=$(run_aiperf "$port" "$model_name" "$label" "$NUM_REQ" "$CONCURRENCY" "$OSL" "$WARMUP")

        IFS='|' read -r out_tok_s lat_avg lat_p50 e2e_tok_s duration <<< "$result"
        log "    → output=${out_tok_s} tok/s, p50=${lat_p50}ms, e2e=${e2e_tok_s} tok/s, duration=${duration}s"
        echo "$cfg_name,$label,$gpu,$model_name,$tp,$out_tok_s,$lat_avg,$lat_p50,$e2e_tok_s,$duration" >> "$COMPARISON_CSV"
    done

    # Parallel AIPerf — all instances simultaneously
    log ""
    log "  === AIPerf benchmarks (parallel) ==="
    local parallel_pids=()
    local parallel_tmp="$RESULT_DIR/parallel_${cfg_name}_${TIMESTAMP}.tmp"
    > "$parallel_tmp"

    for inst in "${instances[@]}"; do
        IFS=':' read -r gpu model_path port tp _ <<< "$inst"
        local model_name
        model_name=$(basename "$model_path")
        local label="${cfg_name}_${model_name}_gpu${gpu//,/-}"

        (
            result=$(run_aiperf "$port" "$model_name" "${label}_parallel" "$NUM_REQ" "$CONCURRENCY" "$OSL" "$WARMUP")
            IFS='|' read -r out_tok_s lat_avg lat_p50 e2e_tok_s duration <<< "$result"
            echo "$label|$out_tok_s|$e2e_tok_s|$duration" >> "$parallel_tmp"
            log "    Parallel $model_name (GPU=$gpu): output=${out_tok_s} tok/s, e2e=${e2e_tok_s}, duration=${duration}s"
        ) &
        parallel_pids+=($!)
    done

    for pid in "${parallel_pids[@]}"; do
        wait "$pid" || true
    done

    # Aggregate parallel results
    local agg_out=0 agg_e2e=0
    while IFS='|' read -r _ out_tok_s e2e_tok_s _; do
        [[ "$out_tok_s" =~ ^[0-9.]+$ ]] && agg_out=$(python3 -c "print($agg_out + $out_tok_s)")
        [[ "$e2e_tok_s" =~ ^[0-9.]+$ ]] && agg_e2e=$(python3 -c "print($agg_e2e + $e2e_tok_s)")
    done < "$parallel_tmp"
    rm -f "$parallel_tmp"

    log "  Parallel aggregate: output=${agg_out} tok/s, e2e=${agg_e2e} tok/s"

    # Cleanup this config
    cleanup_all
    unset instances
done

# ── Final comparison summary ──
log ""
log "============================================"
log "  Comparison Complete"
log "============================================"
log ""
log "Results CSV: $COMPARISON_CSV"
log ""

# Summarize
python3 -c "
import csv, sys
from collections import defaultdict

rows = list(csv.DictReader(open('$COMPARISON_CSV')))
configs = defaultdict(lambda: {'instances': 0, 'total_tok_s': 0, 'total_e2e': 0, 'models': set()})

for r in rows:
    cfg = r['config']
    configs[cfg]['instances'] += 1
    configs[cfg]['models'].add(r['model'])
    if r['tok_s'] != 'N/A':
        configs[cfg]['total_tok_s'] += float(r['tok_s'])
    if r['e2e_tok_s'] != 'N/A':
        configs[cfg]['total_e2e'] += float(r['e2e_tok_s'])

print('Config Comparison Summary:')
print(f'  {\"Config\":<35} {\"Instances\":>10} {\"Agg Tok/s\":>12} {\"Models\":>30}')
print(f'  {\"-\"*35} {\"-\"*10} {\"-\"*12} {\"-\"*30}')
for cfg, data in sorted(configs.items()):
    models_str = ', '.join(sorted(data['models']))
    print(f'  {cfg:<35} {data[\"instances\"]:>10} {data[\"total_tok_s\"]:>12.1f} {models_str:>30}')

print('')
print('Notes:')
print('  - Sequential results measure per-instance throughput.')
print('  - For parallel aggregate, see the test output above.')
print('  - Config B (4× 4B) should show highest tok/s but lowest per-request quality.')
print('  - Config A (mixed) provides quality spectrum for routing by task complexity.')
"

log ""
log "Full results: $RESULT_DIR/"
