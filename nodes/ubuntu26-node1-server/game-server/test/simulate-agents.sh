#!/bin/bash
# Simulate real Claude Code Agent Teams workload against a running endpoint.
#
# Models the following agent patterns:
#   1. Code generation agents — frequent, medium-length requests (writing game code)
#   2. Architecture agents — infrequent, long, complex reasoning requests
#   3. QA agents — many short validation/syntax-check requests
#   4. Design agents — creative writing, moderate length
#
# The test runs these workloads in parallel to simulate multiple agents
# working simultaneously, then measures throughput and latency distribution.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/game-server/test/simulate-agents.sh [ENDPOINT] [--format openai|anthropic]
#
# Default: http://localhost:8000
#
# Environment:
#   API_FORMAT=anthropic  — use Anthropic Messages API (/v1/messages)
#   API_FORMAT=openai     — use OpenAI Chat Completions API (default)
#   NUM_AGENTS=4          — number of concurrent agent processes
#   AGENT_REQUESTS=10     — requests per agent
#   AGENT_CONCURRENCY=4   — concurrent requests within each agent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ENDPOINT="${1:-http://localhost:8000}"
NUM_AGENTS="${NUM_AGENTS:-4}"
AGENT_REQUESTS="${AGENT_REQUESTS:-10}"
AGENT_CONCURRENCY="${AGENT_CONCURRENCY:-4}"
OSL="${OSL:-2048}"
API_FORMAT="${API_FORMAT:-openai}"

# Parse --format flag
for arg in "$@"; do
    case "$arg" in
        --format) API_FORMAT="${2:-openai}"; shift ;;
        --format=*) API_FORMAT="${arg#*=}" ;;
    esac
done

MODEL_NAME="${MODEL_NAME:-$(curl -s "$ENDPOINT/v1/models" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo 'Qwen3.6-27B')}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$REPO_ROOT/tmp/benchmark-results/agent-simulation"
mkdir -p "$RESULT_DIR"
MAIN_LOG="$RESULT_DIR/simulation_${TIMESTAMP}.log"
METRICS_FILE="$RESULT_DIR/metrics_${TIMESTAMP}.csv"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$MAIN_LOG"; }

# ── Agent persona prompts ──
# These simulate what actual Claude Code Game Studio agents would ask a local LLM.
# Uses a lookup function instead of associative array — bash subshells (via &)
# don't inherit associative arrays.

get_agent_prompt() {
    case "$1" in
        gameplay-programmer) cat << 'PROMPT_EOF'
You are a gameplay programmer for a Godot 4 game similar to Animal Crossing.
Write GDScript code implementing the following:

1. A player inventory system with 20 slots, item stacking (max 99 per stack)
2. An item pickup system that adds items to the nearest empty slot
3. A drag-and-drop system for rearranging inventory items

Use typed GDScript with @export variables for configuration.
Include signal definitions for inventory_changed(item_id, slot, action).
Write complete, working code with error handling for edge cases (full inventory, invalid slot, etc.).

Please output the complete GDScript file.
PROMPT_EOF
            ;;
        systems-designer) cat << 'PROMPT_EOF'
You are a game systems designer working on a life simulation game similar to Animal Crossing.
We need to design the friendship/reputation system.

The system should track:
- Friendship level per NPC (0-100)
- Decay rate (friendship decreases when you ignore NPCs)
- Gift preferences (each NPC has liked/disliked items)
- Special events at friendship milestones (25, 50, 75, 100)

Please analyze the design and write a complete design document section covering:
1. Detailed rules for friendship calculation
2. Mathematical formulas for all interactions
3. Edge cases (what happens at max/min friendship?)
4. Dependencies on other systems (dialogue, quests, economy)

Format as a structured game design document.
PROMPT_EOF
            ;;
        qa-tester) cat << 'PROMPT_EOF'
You are a QA tester for a Godot 4 game.
For the following inventory system, identify potential bugs, edge cases, and test scenarios:

func add_item(item_id: String, quantity: int) -> bool:
    var slot = find_slot(item_id)
    if slot != -1:
        inventory[slot].quantity += quantity
        return true
    var empty = find_empty_slot()
    if empty != -1:
        inventory[empty] = {"id": item_id, "quantity": quantity}
        return true
    return false

Write a comprehensive test plan including:
- Unit test cases with expected results
- Edge cases (negative quantity, max stack overflow, null item_id)
- Performance concerns with large inventories
- Integration test scenarios
List specific test function implementations.
PROMPT_EOF
            ;;
        technical-director) cat << 'PROMPT_EOF'
As a technical director for a game project similar to Animal Crossing,
review this architecture decision:

We are choosing between an ECS (Entity Component System) architecture
versus a traditional OOP inheritance hierarchy for our game objects.

The game has:
- ~500 interactive objects (furniture, tools, NPCs)
- ~50 NPCs with complex behavior trees
- Real-time multiplayer with up to 8 players
- Dynamic environment (seasons, weather, time of day)

Analyze the trade-offs:
1. Performance implications of each approach
2. Code organization and maintainability
3. Network replication complexity
4. Extensibility for future features (new items, behaviors, interactions)

Recommend one approach with concrete justification.
Provide a migration plan from our current prototype (OOP-based).
PROMPT_EOF
            ;;
        *) echo "ERROR: Unknown agent type: $1" >&2; return 1 ;;
    esac
}

# ── Helper: run one agent's workload ──
run_agent() {
    local agent_name="$1"
    local agent_requests="$2"
    local port="$3"

    local prompt
    local agent_type="${agent_name%-*}"
    prompt=$(get_agent_prompt "$agent_type")
    local agent_log="$RESULT_DIR/${agent_name}_${TIMESTAMP}.log"
    local agent_metrics="$RESULT_DIR/${agent_name}_${TIMESTAMP}.metrics"

    echo "  Agent [$agent_name] starting ($agent_requests requests)..."

    local total_time=0
    local success_count=0
    local fail_count=0
    local total_tokens=0
    local total_output_tokens=0

    for req_num in $(seq 1 "$agent_requests"); do
        local start_time
        start_time=$(python3 -c "import time; print(time.time())")

        local resp_file
        resp_file=$(mktemp)

        # Build JSON payload and set API path
        local payload_file
        payload_file=$(mktemp)
        local api_path
        if [[ "$API_FORMAT" == "anthropic" ]]; then
            api_path="/v1/messages"
        else
            api_path="/v1/chat/completions"
        fi
        python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({
    'model': '$MODEL_NAME',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': $OSL,
    'temperature': 0.3
}))
" <<< "$prompt" > "$payload_file"

        local http_code
        http_code=$(curl -s --max-time 300 -o "$resp_file" -w '%{http_code}' \
            "http://localhost:$port${api_path}" \
            -H "Content-Type: application/json" \
            -d "@$payload_file" 2>/dev/null)
        rm -f "$payload_file"

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
    if '$API_FORMAT' == 'anthropic':
        usage = d.get('usage', {})
        prompt_tokens = usage.get('input_tokens', 0)
        completion_tokens = usage.get('output_tokens', 0)
    else:
        usage = d.get('usage', {})
        prompt_tokens = usage.get('prompt_tokens', 0)
        completion_tokens = usage.get('completion_tokens', 0)
    print(f'{prompt_tokens + completion_tokens}|{completion_tokens}')
except: print('0|0')
" 2>/dev/null)
            local tokens="${tok_count%%|*}"
            local out_tokens="${tok_count##*|}"
            total_tokens=$((total_tokens + tokens))
            total_output_tokens=$((total_output_tokens + out_tokens))
        else
            fail_count=$((fail_count + 1))
        fi

        total_time=$(python3 -c "print($total_time + $elapsed)")
        rm -f "$resp_file"

        # Progress indicator
        if [[ $((req_num % 5)) -eq 0 ]]; then
            echo "    [$agent_name] $req_num/$agent_requests done (${success_count} ok, ${fail_count} fail)"
        fi
    done

    # Write per-agent metrics
    local avg_time
    avg_time=$(python3 -c "print(f'{${total_time} / ${agent_requests}:.2f}')" 2>/dev/null || echo "0")
    local avg_tok_per_req
    avg_tok_per_req=$(python3 -c "print(f'{${total_output_tokens} / max(${success_count}, 1):.0f}')" 2>/dev/null || echo "0")
    local tok_per_sec
    tok_per_sec=$(python3 -c "print(f'{${total_output_tokens} / max(${total_time}, 0.01):.1f}')" 2>/dev/null || echo "0")

    echo "$agent_name,$success_count,$fail_count,$total_time,$avg_time,$total_output_tokens,$avg_tok_per_req,$tok_per_sec" >> "$METRICS_FILE"

    log "  Agent [$agent_name] complete: $success_count/$agent_requests success, ${avg_time}s avg, ${tok_per_sec} tok/s"
}

# ── Main ──
echo ""
echo "============================================"
echo "  Agent Team Simulation"
echo "  Endpoint  : $ENDPOINT"
echo "  API Format: $API_FORMAT"
echo "  Model     : $MODEL_NAME"
echo "  Agents    : $NUM_AGENTS"
echo "  Req/Agent : $AGENT_REQUESTS"
echo "  OSL       : $OSL"
echo "============================================"
echo ""

# Extract port from endpoint
PORT="${ENDPOINT##*:}"
ENDPOINT="${ENDPOINT}"

if ! curl -s --max-time 10 "$ENDPOINT/health" >/dev/null 2>&1; then
    echo "ERROR: Endpoint $ENDPOINT not reachable." >&2
    exit 1
fi
log "Endpoint health: OK"

# Agent roster
AGENTS=("gameplay-programmer" "systems-designer" "qa-tester" "technical-director")
if [[ "$NUM_AGENTS" -gt "${#AGENTS[@]}" ]]; then
    # Cycle through agents if more agents than unique types
    for i in $(seq "${#AGENTS[@]}" $((NUM_AGENTS - 1))); do
        AGENTS+=("${AGENTS[$((i % ${#AGENTS[@]}))]}")
    done
fi

# CSV header
echo "agent,success,fail,total_time_sec,avg_time_sec,output_tokens,avg_tok_per_req,output_tok_per_sec" > "$METRICS_FILE"

log "=== Starting $NUM_AGENTS parallel agent workloads ==="
echo ""

AGENT_PIDS=()
for i in $(seq 0 $((NUM_AGENTS - 1))); do
    agent="${AGENTS[$i]}"
    run_agent "$agent-$i" "$AGENT_REQUESTS" "$PORT" &
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

# Overall throughput
agg_tok_per_sec = total_out_tok / max(total_time / len(rows), 0.01)

# Per-agent breakdown
print('')
print('Per-Agent Results:')
print(f'  {\"Agent\":<30} {\"Success\":>8} {\"Fail\":>6} {\"AvgTime\":>8} {\"Tok/Req\":>8} {\"Tok/s\":>8}')
print(f'  {\"-\"*30} {\"-\"*8} {\"-\"*6} {\"-\"*8} {\"-\"*8} {\"-\"*8}')
for r in rows:
    print(f'  {r[\"agent\"]:<30} {r[\"success\"]:>8} {r[\"fail\"]:>6} {r[\"avg_time_sec\"]:>8}s {r[\"avg_tok_per_req\"]:>8} {r[\"output_tok_per_sec\"]:>8}')

print('')
print(f'Aggregate Results:')
print(f'  Total Requests       : {total_success + total_fail}')
print(f'  Success Rate         : {total_success / max(total_success + total_fail, 1) * 100:.1f}%')
print(f'  Total Output Tokens  : {total_out_tok}')
print(f'  Concurrent Agents    : {len(rows)}')
print(f'  Effective Throughput : {agg_tok_per_sec:.1f} tok/s')
print(f'  Requests per second  : {total_success / max(total_time / len(rows), 0.01):.2f} req/s')
"

log ""
log "Raw metrics: $METRICS_FILE"
log "Agent logs : $RESULT_DIR/"
