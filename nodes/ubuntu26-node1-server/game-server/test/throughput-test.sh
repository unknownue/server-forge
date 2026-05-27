#!/bin/bash
# Throughput benchmark: test a running SGLang endpoint with AIPerf.
# Measures output tok/s, latency, and E2E throughput.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/game-server/test/throughput-test.sh [ENDPOINT] [CONCURRENCY] [NUM_REQUESTS]
#
# Default: http://localhost:8000, concurrency=16, 100 requests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ENDPOINT="${1:-http://localhost:8000}"
CONCURRENCY="${2:-16}"
NUM_REQUESTS="${3:-100}"
OSL="${4:-4096}"
WARMUP="${5:-10}"

MODEL_NAME="${MODEL_NAME:-$(curl -s "$ENDPOINT/v1/models" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo 'Qwen3.6-27B')}"
TOKENIZER="${TOKENIZER:-Qwen/$MODEL_NAME}"

AIPERF_IMAGE="aiperf:latest"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/game-server-throughput"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/throughput_${TIMESTAMP}.log"

if ! docker image inspect "$AIPERF_IMAGE" &>/dev/null; then
    echo "ERROR: aiperf image not found. Build with: bash benchmark/llm/bench/build-aiperf.sh" >&2
    exit 1
fi

echo ""
echo "============================================"
echo "  Throughput Benchmark"
echo "  Endpoint  : $ENDPOINT"
echo "  Model     : $MODEL_NAME"
echo "  Tokenizer : $TOKENIZER"
echo "  Requests  : $NUM_REQUESTS (warmup=$WARMUP)"
echo "  Concurrency: $CONCURRENCY"
echo "  OSL       : $OSL"
echo "============================================"
echo ""

# Quick connectivity check
if ! curl -s --max-time 10 "$ENDPOINT/health" >/dev/null 2>&1; then
    echo "ERROR: Endpoint $ENDPOINT not reachable." >&2
    exit 1
fi
echo "  Endpoint health: OK"
echo ""

HF_MIRROR="${HF_ENDPOINT:-https://hf-mirror.com}"

echo "  Running AIPerf..."
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
        --url '$ENDPOINT' \
        --model '$MODEL_NAME' \
        --tokenizer '$TOKENIZER' \
        --num-prompts '$NUM_REQUESTS' \
        --num-requests '$NUM_REQUESTS' \
        --num-warmup-requests '$WARMUP' \
        --concurrency '$CONCURRENCY' \
        --osl '$OSL' \
        --artifact-dir /results" \
    2>&1 | tee "$RESULT_FILE"

# Parse results
echo ""
echo "============================================"
echo "  Results"
echo "============================================"

python3 -c "
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

print(f'  Output Token Throughput: {c(r1,2)} tok/s')
print(f'  Avg Request Latency   : {c(r2,2)} ms')
print(f'  P50 Request Latency   : {c(r2,7)} ms')
print(f'  E2E Token Throughput  : {c(r3,2)} tok/s')
"

echo ""
echo "  Full log: $RESULT_FILE"
