#!/bin/bash
# Quick throughput benchmark for DeepSeek-V4-Flash endpoint.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/deepseek-v4-flash/test/throughput-test.sh [ENDPOINT]
#
# Default: http://localhost:8000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ENDPOINT="${1:-http://localhost:8000}"
MODEL_NAME="${MODEL_NAME:-deepseek-v4-flash}"
OSL="${OSL:-2048}"
NUM_REQUESTS="${NUM_REQUESTS:-5}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/dsv4-flash"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/throughput_${TIMESTAMP}.csv"

log() { echo "[$(date +%H:%M:%S)] $*"; }

echo ""
echo "============================================"
echo "  DeepSeek-V4-Flash — Throughput Test"
echo "  Endpoint : $ENDPOINT"
echo "  Model    : $MODEL_NAME"
echo "  OSL      : $OSL"
echo "  Requests : $NUM_REQUESTS"
echo "============================================"
echo ""

if ! curl -s --max-time 10 "$ENDPOINT/health" -o /dev/null 2>/dev/null; then
    echo "ERROR: Endpoint $ENDPOINT not reachable." >&2
    exit 1
fi
log "Endpoint health: OK"

echo "req,output_tokens,total_time_sec,tok_per_sec" > "$RESULT_FILE"

log "Running $NUM_REQUESTS requests..."
total_output_tokens=0
total_time=0
success=0
fail=0

for req_num in $(seq 1 "$NUM_REQUESTS"); do
    start_time=$(python3 -c "import time; print(time.time())")

    resp_file=$(mktemp)
    http_code=$(curl -s --max-time 120 -o "$resp_file" -w '%{http_code}' \
        -X POST "$ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a Python implementation of quicksort with detailed comments.\"}],\"max_tokens\":$OSL,\"temperature\":0.0}" \
        2>/dev/null)

    end_time=$(python3 -c "import time; print(time.time())")
    elapsed=$(python3 -c "print(f'{${end_time} - ${start_time}:.2f}')")

    if [[ "$http_code" == "200" ]]; then
        output_tokens=$(python3 -c "
import json
try:
    d = json.load(open('$resp_file'))
    print(d.get('usage', {}).get('completion_tokens', 0))
except: print(0)
" 2>/dev/null)
        total_output_tokens=$((total_output_tokens + output_tokens))
        total_time=$(python3 -c "print($total_time + $elapsed)")
        tok_per_sec=$(python3 -c "print(f'{${output_tokens} / max($elapsed, 0.01):.1f}')")
        echo "$req_num,$output_tokens,$elapsed,$tok_per_sec" >> "$RESULT_FILE"
        log "  req#$req_num: $output_tokens tokens in ${elapsed}s ($tok_per_sec tok/s)"
        success=$((success + 1))
    else
        log "  req#$req_num: FAIL (HTTP $http_code)"
        fail=$((fail + 1))
    fi
    rm -f "$resp_file"
done

# Summary
avg_tok_per_sec=$(python3 -c "print(f'${total_output_tokens} / max(${total_time}, 0.01):.1f}')")
avg_latency=$(python3 -c "print(f'${total_time} / max(${success}, 1):.2f}')")

log ""
log "============================================"
log "  Results"
log "============================================"
log "  Success        : $success/$NUM_REQUESTS"
log "  Fail           : $fail"
log "  Total tokens   : $total_output_tokens"
log "  Total time     : ${total_time}s"
log "  Avg latency    : ${avg_latency}s"
log "  Throughput     : ${avg_tok_per_sec} tok/s"
log ""
log "Results saved: $RESULT_FILE"
