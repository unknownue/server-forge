#!/bin/bash
# Quick smoke test for SGLang inference server.
#
# Usage:
#   bash benchmark/llm/test-sglang.sh [PORT]

set -euo pipefail

PORT="${1:-8000}"
URL="http://localhost:$PORT"
PASS=0
FAIL=0

check() {
    local name="$1" method="$2" endpoint="$3" data="${4:-}" expected="${5:-200}"
    local code
    if [[ -n "$data" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$URL$endpoint" \
               -H "Content-Type: application/json" -d "$data" --max-time 30)
    else
        code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$URL$endpoint" --max-time 10)
    fi
    if [[ "$code" == "$expected" ]]; then
        echo "  PASS  $name"
        ((PASS++))
    else
        echo "  FAIL  $name (expected $expected, got $code)"
        ((FAIL++))
    fi
}

echo "=== SGLang Smoke Test ==="
echo "  Target: $URL"
echo ""

echo "[Health Check]"
check "GET /health"    GET  "/health"
check "GET /health_generate" GET "/health_generate"
echo ""

echo "[API]"
check "GET /v1/models" GET  "/v1/models"

MODEL_ID=$(curl -s "$URL/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "")
if [[ -z "$MODEL_ID" ]]; then
    echo "  WARN   could not detect model ID, using default"
    MODEL_ID="Qwen3.6-27B-FP8"
fi

check "POST /v1/chat/completions" POST "/v1/chat/completions" \
    "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"say hello in one word\"}],\"max_tokens\":16}"
echo ""

echo "[Results]"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
