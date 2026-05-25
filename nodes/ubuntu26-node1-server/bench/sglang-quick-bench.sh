#!/bin/bash
# Quick single-config SGLang benchmark — fastest path to validate
# throughput of voipmonitor/sglang:test-cu132.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/bench/sglang-quick-bench.sh [TP_SIZE] [NCCL_PROFILE]
#
#   TP_SIZE:      1 (default), 2, or 4
#   NCCL_PROFILE: Name of a preset NCCL config (see below), or "default"
#
# Examples:
#   bash sglang-quick-bench.sh              # TP=1, default NCCL
#   bash sglang-quick-bench.sh 2            # TP=2, default NCCL
#   bash sglang-quick-bench.sh 4 phb+nch8   # TP=4, optimized NCCL
#
# Preset NCCL profiles:
#   default      No overrides (use image defaults)
#   phb+nch8     P2P=PHB, NCH=8    (single-socket optimal)
#   phb+nch8+LL  P2P=PHB, NCH=8, PROTO=LL
#   p2p-off      P2P_DISABLE=1, NCH=16
#
# Results saved to tmp/benchmark-results/sglang-quick/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TP_SIZE="${1:-1}"
NCCL_PROFILE="${2:-default}"

MODEL_ID="${AIPERF_MODEL_ID:-Qwen/Qwen3.5-4B}"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="${AIPERF_MODEL_DIR:-/data/work/models/Qwen/$MODEL_NAME}"
SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
AIPERF_IMAGE="aiperf:latest"
CACHE_DIR="/data/cache/sglang_jit"
PORT="${AIPERF_PORT:-8000}"
CONTAINER_NAME="${AIPERF_CONTAINER_NAME:-sglang-quick}"

# Map TP_SIZE to GPU list (allow override via AIPERF_GPUS)
if [[ -n "${AIPERF_GPUS:-}" ]]; then
    GPUS="$AIPERF_GPUS"
else
    case "$TP_SIZE" in
        1) GPUS="0" ;;
        2) GPUS="0,1" ;;
        4) GPUS="0,1,2,3" ;;
        *) echo "ERROR: TP_SIZE must be 1, 2, or 4." >&2; exit 1 ;;
    esac
fi

# ── NCCL profile database ──
declare -A NCCL_P2P_LEVEL NCCL_MIN_NCHANNELS NCCL_PROTO NCCL_P2P_DISABLE NCCL_ALLOC_P2P_NET_LL_BUFFERS
case "$NCCL_PROFILE" in
    default)
        ;;
    phb+nch8)
        NCCL_P2P_LEVEL["v"]="PHB"
        NCCL_MIN_NCHANNELS["v"]=8
        NCCL_ALLOC_P2P_NET_LL_BUFFERS["v"]=1
        ;;
    phb+nch8+LL)
        NCCL_P2P_LEVEL["v"]="PHB"
        NCCL_MIN_NCHANNELS["v"]=8
        NCCL_PROTO["v"]="LL"
        NCCL_ALLOC_P2P_NET_LL_BUFFERS["v"]=1
        ;;
    p2p-off)
        NCCL_P2P_DISABLE["v"]=1
        NCCL_MIN_NCHANNELS["v"]=16
        ;;
    *)
        echo "ERROR: Unknown NCCL profile '$NCCL_PROFILE'." >&2
        echo "Available: default, phb+nch8, phb+nch8+LL, p2p-off" >&2
        exit 1
        ;;
esac

# Default values for unset vars
apply_nccl_profile() {
    local profile="${1:-default}"
    if [[ "$profile" == "default" ]]; then return; fi
    if [[ -n "${NCCL_P2P_LEVEL["v"]+x}" ]]; then             export NCCL_P2P_LEVEL="${NCCL_P2P_LEVEL["v"]}"; fi
    if [[ -n "${NCCL_MIN_NCHANNELS["v"]+x}" ]]; then          export NCCL_MIN_NCHANNELS="${NCCL_MIN_NCHANNELS["v"]}"; fi
    if [[ -n "${NCCL_PROTO["v"]+x}" ]]; then                  export NCCL_PROTO="${NCCL_PROTO["v"]}"; fi
    if [[ -n "${NCCL_P2P_DISABLE["v"]+x}" ]]; then            export NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE["v"]}"; fi
    if [[ -n "${NCCL_ALLOC_P2P_NET_LL_BUFFERS["v"]+x}" ]]; then export NCCL_ALLOC_P2P_NET_LL_BUFFERS="${NCCL_ALLOC_P2P_NET_LL_BUFFERS["v"]}"; fi
}

NUM_PROMPTS="${NUM_PROMPTS:-20}"
NUM_REQUESTS="${NUM_REQUESTS:-20}"
WARMUP="${WARMUP:-5}"
CONCURRENCY="${AIPERF_CONCURRENCY:-16}"
OSL="${OSL:-4096}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/sglang-quick"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/quick_tp${TP_SIZE}_${NCCL_PROFILE}_${TIMESTAMP}.log"

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

cleanup() {
    local cid
    cid=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
    [[ -n "$cid" ]] && docker stop "$cid" 2>/dev/null || true
}
trap cleanup EXIT

# ── Start server ──
apply_nccl_profile "$NCCL_PROFILE"

echo ""
echo "============================================"
echo "  SGLang Quick Benchmark"
echo "  Model   : $MODEL_ID"
echo "  GPU(s)  : $GPUS  (TP=$TP_SIZE)"
echo "  NCCL    : $NCCL_PROFILE"
echo "  Image   : $SGLANG_IMAGE"
echo "  Port    : $PORT"
echo "============================================"
echo ""

mkdir -p "$CACHE_DIR"

# Build NCCL env array
nccl_env=()
[[ -n "${NCCL_P2P_LEVEL:-}" ]]             && nccl_env+=(-e "NCCL_P2P_LEVEL=$NCCL_P2P_LEVEL")
[[ -n "${NCCL_MIN_NCHANNELS:-}" ]]         && nccl_env+=(-e "NCCL_MIN_NCHANNELS=$NCCL_MIN_NCHANNELS")
[[ -n "${NCCL_MAX_NCHANNELS:-}" ]]         && nccl_env+=(-e "NCCL_MAX_NCHANNELS=${NCCL_MAX_NCHANNELS:-$NCCL_MIN_NCHANNELS}")
[[ -n "${NCCL_PROTO:-}" ]]                 && nccl_env+=(-e "NCCL_PROTO=$NCCL_PROTO")
[[ -n "${NCCL_P2P_DISABLE:-}" ]]           && nccl_env+=(-e "NCCL_P2P_DISABLE=$NCCL_P2P_DISABLE")
[[ -n "${NCCL_ALLOC_P2P_NET_LL_BUFFERS:-}" ]] && nccl_env+=(-e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=$NCCL_ALLOC_P2P_NET_LL_BUFFERS")
nccl_env+=(-e "NCCL_IB_DISABLE=1")
nccl_env+=(-e "NCCL_CUMEM_HOST_ENABLE=0")
nccl_env+=(-e "OMP_NUM_THREADS=8")

# Override image's built-in cache paths (default: /cache/jit/*) to match HOME.
nccl_env+=(-e "XDG_CACHE_HOME=/cache")
nccl_env+=(-e "FLASHINFER_WORKSPACE_BASE=/cache/flashinfer")
nccl_env+=(-e "TORCH_EXTENSIONS_DIR=/cache/torch_extensions")
nccl_env+=(-e "TRITON_CACHE_DIR=/cache/triton")
nccl_env+=(-e "TVM_FFI_CACHE_DIR=/cache/tvm-ffi")

HF_ENV=()
[[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

echo "[1/3] Starting SGLang server..."
docker run --rm -d \
    --name "$CONTAINER_NAME" \
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

echo "  Waiting for server..."
for i in $(seq 1 300); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" == "200" ]]; then
        echo "  Ready (${i}x2s)."
        break
    fi
    sleep 2
done

if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" != "200" ]]; then
    echo "ERROR: Server failed to start." >&2
    exit 1
fi

# ── Smoke test ──
echo ""
echo "[2/3] Smoke test..."
if curl -s --max-time 30 "http://localhost:$PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":8}" \
    >/dev/null 2>&1; then
    echo "  PASS"
else
    echo "  FAIL"
    exit 1
fi

# ── Benchmark ──
echo ""
echo "[3/3] Running benchmark ($NUM_REQUESTS req, conc=$CONCURRENCY)..."

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
    2>&1 | tee "$RESULT_FILE"

# ── Summary ──
echo ""
echo "============================================"
echo "  Quick Benchmark Complete"
echo "============================================"
echo "  TP=$TP_SIZE | NCCL=$NCCL_PROFILE | GPU(s)=$GPUS"
echo "  Result: $RESULT_FILE"
echo ""

# Extract key numbers
parsed=$(python3 -c "
import re
t = open('$RESULT_FILE').read()
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
print(f'{c(r1,2)}|{c(r2,2)}|{c(r2,7)}|{c(r3,2)}')
")
IFS='|' read -r out_tok_s lat_avg lat_p50 e2e_tok_s <<< "$parsed"

echo "  Output Token Throughput: ${out_tok_s:-N/A} tok/s"
echo "  E2E Token Throughput   : ${e2e_tok_s:-N/A} tok/s"
echo "  Latency (avg / P50)    : ${lat_avg:-N/A} / ${lat_p50:-N/A} ms"
