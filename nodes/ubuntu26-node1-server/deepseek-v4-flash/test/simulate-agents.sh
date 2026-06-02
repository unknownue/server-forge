#!/bin/bash
# Simulate multi-agent workload against DeepSeek-V4-Flash endpoint.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/deepseek-v4-flash/test/simulate-agents.sh [ENDPOINT]
#
# Default: http://localhost:8000
#
# Environment:
#   NUM_AGENTS=4       — number of concurrent agent processes
#   AGENT_REQUESTS=10  — requests per agent
#   OSL=2048           — max output tokens per request

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ENDPOINT="${1:-http://localhost:8000}"
NUM_AGENTS="${NUM_AGENTS:-4}"
AGENT_REQUESTS="${AGENT_REQUESTS:-10}"
OSL="${OSL:-2048}"

MODEL_NAME="${MODEL_NAME:-deepseek-v4-flash}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/dsv4-flash/agent-simulation"
mkdir -p "$RESULT_DIR"
MAIN_LOG="$RESULT_DIR/simulation_${TIMESTAMP}.log"
METRICS_FILE="$RESULT_DIR/metrics_${TIMESTAMP}.csv"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$MAIN_LOG"; }

# ── Agent persona prompts ──
get_agent_prompt() {
    case "$1" in
        code-reviewer) cat << 'PROMPT_EOF'
You are a senior code reviewer. Review the following Python function and identify:
1. Potential bugs and edge cases
2. Performance concerns
3. Suggested improvements

```python
def process_transactions(transactions: list[dict]) -> dict:
    results = {}
    for t in transactions:
        tid = t["id"]
        amount = t["amount"]
        if t["type"] == "credit":
            results[tid] = amount * 1.05
        elif t["type"] == "debit":
            results[tid] = -amount
        else:
            results[tid] = 0
    return results
```

Write a detailed review with specific recommendations.
PROMPT_EOF
            ;;
        architect) cat << 'PROMPT_EOF'
You are a software architect designing a microservices system.
Design the architecture for an e-commerce platform with the following requirements:

- User authentication and authorization
- Product catalog with search
- Shopping cart and checkout
- Order processing and inventory management
- Real-time notifications

Describe:
1. Service decomposition and boundaries
2. Communication patterns (sync vs async)
3. Data consistency strategy
4. Error handling and resilience patterns

Write a structured architecture document.
PROMPT_EOF
            ;;
        developer) cat << 'PROMPT_EOF'
You are a backend developer implementing a REST API.
Write a complete FastAPI implementation for a task management system with:

- CRUD endpoints for tasks (title, description, status, priority, due_date)
- Filtering by status and priority
- Pagination support
- Input validation
- Proper HTTP status codes and error responses

Include the full Python code with type hints and docstrings.
PROMPT_EOF
            ;;
        data-analyst) cat << 'PROMPT_EOF'
You are a data analyst. Given the following sales data structure, write a comprehensive analysis query plan:

Tables:
- orders (id, customer_id, total_amount, status, created_at)
- order_items (id, order_id, product_id, quantity, unit_price)
- products (id, name, category, cost_price)
- customers (id, name, segment, created_at)

Provide SQL queries for:
1. Monthly revenue by product category
2. Top 10 customers by lifetime value
3. Product profit margins (weighted by sales volume)
4. Customer retention cohort analysis

Explain each query's approach and expected output format.
PROMPT_EOF
            ;;
        *) echo "ERROR: Unknown agent type: $1" >&2; return 1 ;;
    esac
}

# ── Run one agent's workload ──
run_agent() {
    local agent_name="$1"
    local agent_type="${agent_name%-*}"

    local prompt
    prompt=$(get_agent_prompt "$agent_type")

    local total_time=0
    local success_count=0
    local fail_count=0
    local total_output_tokens=0

    for req_num in $(seq 1 "$AGENT_REQUESTS"); do
        local start_time
        start_time=$(python3 -c "import time; print(time.time())")

        local resp_file
        resp_file=$(mktemp)

        local http_code
        http_code=$(curl -s --max-time 120 -o "$resp_file" -w '%{http_code}' \
            -X POST "$ENDPOINT/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$prompt")}],\"max_tokens\":$OSL,\"temperature\":0.3}" \
            2>/dev/null)

        local end_time
        end_time=$(python3 -c "import time; print(time.time())")
        local elapsed
        elapsed=$(python3 -c "print(f'{${end_time} - ${start_time}:.2f}')")

        if [[ "$http_code" == "200" ]]; then
            success_count=$((success_count + 1))
            local tok_count
            tok_count=$(python3 -c "
import json
try:
    d = json.load(open('$resp_file'))
    usage = d.get('usage', {})
    print(usage.get('completion_tokens', 0))
except: print(0)
" 2>/dev/null)
            total_output_tokens=$((total_output_tokens + tok_count))
        else
            fail_count=$((fail_count + 1))
        fi

        total_time=$(python3 -c "print($total_time + $elapsed)")
        rm -f "$resp_file"

        if [[ $((req_num % 5)) -eq 0 ]]; then
            echo "    [$agent_name] $req_num/$AGENT_REQUESTS done (${success_count} ok, ${fail_count} fail)"
        fi
    done

    local avg_time
    avg_time=$(python3 -c "print(f'${total_time} / max(${AGENT_REQUESTS}, 1):.2f}')" 2>/dev/null || echo "0")
    local tok_per_sec
    tok_per_sec=$(python3 -c "print(f'${total_output_tokens} / max(${total_time}, 0.01):.1f}')" 2>/dev/null || echo "0")

    echo "$agent_name,$success_count,$fail_count,$total_time,$avg_time,$total_output_tokens,$tok_per_sec" >> "$METRICS_FILE"

    log "  Agent [$agent_name] complete: $success_count/$AGENT_REQUESTS success, ${avg_time}s avg, ${tok_per_sec} tok/s"
}

# ── Main ──
echo ""
echo "============================================"
echo "  Agent Team Simulation"
echo "  Endpoint : $ENDPOINT"
echo "  Model    : $MODEL_NAME"
echo "  Agents   : $NUM_AGENTS"
echo "  Req/Agent: $AGENT_REQUESTS"
echo "  OSL      : $OSL"
echo "============================================"
echo ""

if ! curl -s --max-time 10 "$ENDPOINT/health" -o /dev/null 2>/dev/null; then
    echo "ERROR: Endpoint $ENDPOINT not reachable." >&2
    exit 1
fi
log "Endpoint health: OK"

AGENTS=("code-reviewer" "architect" "developer" "data-analyst")
if [[ "$NUM_AGENTS" -gt "${#AGENTS[@]}" ]]; then
    for i in $(seq "${#AGENTS[@]}" $((NUM_AGENTS - 1))); do
        AGENTS+=("${AGENTS[$((i % ${#AGENTS[@]}))]}")
    done
fi

echo "agent,success,fail,total_time_sec,avg_time_sec,output_tokens,output_tok_per_sec" > "$METRICS_FILE"

log "=== Starting $NUM_AGENTS parallel agent workloads ==="
echo ""

AGENT_PIDS=()
for i in $(seq 0 $((NUM_AGENTS - 1))); do
    agent="${AGENTS[$i]}"
    run_agent "$agent-$i" &
    AGENT_PIDS+=($!)
done

log "  Waiting for all agents to complete..."
for pid in "${AGENT_PIDS[@]}"; do
    wait "$pid" || true
done

# ── Aggregate results ──
log ""
log "============================================"
log "  Simulation Results"
log "============================================"

python3 -c "
import csv

rows = list(csv.DictReader(open('$METRICS_FILE')))
total_success = sum(int(r['success']) for r in rows)
total_fail = sum(int(r['fail']) for r in rows)
total_time = sum(float(r['total_time_sec']) for r in rows)
total_out_tok = sum(int(r['output_tokens']) for r in rows)

agg_tok_per_sec = total_out_tok / max(total_time / len(rows), 0.01)

print('')
print('Per-Agent Results:')
print(f'  {\"Agent\":<25} {\"Success\":>8} {\"Fail\":>6} {\"AvgTime\":>8} {\"Tok/s\":>8}')
print(f'  {\"-\"*25} {\"-\"*8} {\"-\"*6} {\"-\"*8} {\"-\"*8}')
for r in rows:
    print(f'  {r[\"agent\"]:<25} {r[\"success\"]:>8} {r[\"fail\"]:>6} {r[\"avg_time_sec\"]:>8}s {r[\"output_tok_per_sec\"]:>8}')

print('')
print(f'Aggregate Results:')
print(f'  Total Requests       : {total_success + total_fail}')
print(f'  Success Rate         : {total_success / max(total_success + total_fail, 1) * 100:.1f}%')
print(f'  Total Output Tokens  : {total_out_tok}')
print(f'  Concurrent Agents    : {len(rows)}')
print(f'  Effective Throughput : {agg_tok_per_sec:.1f} tok/s')
"

log ""
log "Raw metrics: $METRICS_FILE"
