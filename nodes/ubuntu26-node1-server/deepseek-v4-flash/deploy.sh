#!/bin/bash
# One-click deployment script for DeepSeek-V4-Flash vLLM server.
# Uses the patched dsv4-flash-acti-mtp Docker image (jasl/vllm + MTP patches).
#
# Model: W4A16 (~145 GB VRAM) + MLA + MTP speculative decoding
# Hardware: 2× RTX 6000D 85.6GB = 171.2 GB total VRAM
# Reference: LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8 model card benchmarks
#             AIServerSetup DS4-Flash production config
#
# Usage:
#   bash nodes/ubuntu26-node1-server/deepseek-v4-flash/deploy.sh [PLAN]
#
# Plans (profiles validated on 2×RTX PRO 6000 96GB, scaled down for our 85.6GB):
#   default    : 128K context, 3 concurrent (balanced multi-user)
#   plan-long  : 256K context, 2 concurrent (deep analysis, RAG)
#   plan-524k  : 524K context, 1 concurrent (solo max-context)
#   plan-high  :  64K context, 5 concurrent (agent fleet)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLAN="${1:-default}"

IMAGE_NAME="dsv4-flash-acti-mtp:0.1.0"
MODEL_HOST_PATH="/data/work/models/LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8"
MODEL_CONTAINER_PATH="/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8"
CACHE_VOLUME="dsv4_cache"
HF_CACHE_HOST="$HOME/.cache/huggingface"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ═══════════════════════════════════════════════════════════════════════════
# VRAM Budget — 2× RTX 6000D 85.6 GB = 171.2 GB total
# ───────────────────────────────────────────────────────────────────────────
# Model weights (W4A16 INT4):                 ~145 GB
# DSV4 MLA KV cache (~27 KB/token FP8):       varies by profile
# ───────────────────────────────────────────────────────────────────────────
# At 0.93 util:  159.2 GB usable →  ~14.2 GB for KV → ~526K tokens total
# At 0.90 util:  154.1 GB usable →   ~9.1 GB for KV → ~337K tokens total
# ═══════════════════════════════════════════════════════════════════════════

# ── NCCL/env tuning (from Acti's validated set — reduces TTFT ~40%) ──
# These are baked into the Docker image but we pass them explicitly for visibility.
NCCL_ENV=(
    "NCCL_P2P_DISABLE=1"        # No NVLink on RTX 6000D
    "NCCL_IB_DISABLE=1"         # No InfiniBand
    "NCCL_SHM_DISABLE=0"        # Keep shared-memory transport
    "NCCL_PROTO=LL"             # Low-latency protocol for small messages
    "NCCL_ALGO=Ring"            # Ring algorithm (no NVLink tree)
    "NCCL_MIN_NCHANNELS=8"      # Tuned for Max-Q AR latency
    "NCCL_NTHREADS=512"         # Sufficient threads for 2-GPU allreduce
    "NCCL_DEBUG=WARN"           # Quiet but catches issues
)

# ── Pre-flight checks ──
preflight() {
    log "=== Pre-flight checks ==="

    if ! docker info &>/dev/null; then
        echo "ERROR: Docker not accessible." >&2; exit 1
    fi

    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "ERROR: Image '$IMAGE_NAME' not found." >&2
        echo "Build it first:" >&2
        echo "  bash $SCRIPT_DIR/docker/build.sh" >&2
        exit 1
    fi
    log "  Docker + $IMAGE_NAME: OK"

    if [[ ! -f "$MODEL_HOST_PATH/config.json" ]]; then
        echo "ERROR: Model not found at $MODEL_HOST_PATH" >&2
        echo "Download with:" >&2
        echo "  bash scripts/lib/download-model.sh LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8" >&2
        exit 1
    fi
    log "  Model: OK ($MODEL_HOST_PATH)"

    # Clean up any existing container with same name or port
    local existing
    existing=$(docker ps -a -q --filter "name=dsv4-flash" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Removing existing container dsv4-flash..."
        docker rm -f "$existing" 2>/dev/null || true
    fi
    existing=$(docker ps -a -q --filter "publish=8000" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Removing existing container on port 8000..."
        docker rm -f "$existing" 2>/dev/null || true
    fi
}

# ── Load plan configuration ──
load_plan() {
    log "=== Loading plan: $PLAN ==="

    # Defaults
    CONTAINER_NAME="dsv4-flash"
    GPU_DEVICE="0,1"
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=131072       # 128K
    MAX_NUM_SEQS=3             # concurrent requests
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION="0.93"
    BLOCK_SIZE=256              # V4-Flash requires 256
    DISABLE_CUSTOM_ALL_REDUCE=1 # Required: no NVLink → deadlocks otherwise
    ENABLE_MTP=1                # Multi-Token Prediction speculative decoding
    PORT=8000
    SHM_SIZE="64g"              # Large shared memory for KV cache + NCCL

    case "$PLAN" in
        default)
            # 128K × 3 seqs — balanced multi-user
            # KV: 131072 × 3 × ~27KB ≈ 10.6 GB → 14.2 GB budget ✅ (25% headroom)
            # Ref: 128k/8seqs/0.90 → 467 TPS on 2×96GB. Our ~60% throughput: ~200 TPS
            log "  GPU 0,1: TP=2, 128K context, 3 concurrent, 0.93 util → :8000"
            log "  Estimated: ~200 tok/s aggregate"
            ;;
        plan-long)
            # 256K × 2 seqs — deep analysis, RAG
            # KV: 262144 × 2 × ~27KB ≈ 14.2 GB → 14.2 GB budget ✅ (tight)
            # Ref: 256k/4seqs/0.95 → 296 TPS on 2×96GB. Our ~50% throughput: ~150 TPS
            MAX_MODEL_LEN=262144
            MAX_NUM_SEQS=2
            log "  GPU 0,1: TP=2, 256K context, 2 concurrent, 0.93 util → :8000"
            log "  Estimated: ~150 tok/s aggregate"
            ;;
        plan-524k)
            # 524K × 1 seq — solo max-context
            # KV: 524288 × 1 × ~27KB ≈ 14.2 GB → 14.2 GB budget ✅ (tight)
            # Ref: 524k/1seq → 87 TPS single-stream on 2×96GB
            MAX_MODEL_LEN=524288
            MAX_NUM_SEQS=1
            log "  GPU 0,1: TP=2, 524K context, 1 concurrent, 0.93 util → :8000"
            log "  Estimated: ~85 tok/s single-stream"
            ;;
        plan-high)
            # 64K × 5 seqs — agent fleet, high concurrency
            # KV: 65536 × 5 × ~27KB ≈ 8.9 GB → 9.1 GB budget ✅ (2% headroom — tight)
            MAX_MODEL_LEN=65536
            MAX_NUM_SEQS=5
            MAX_NUM_BATCHED_TOKENS=16384
            GPU_MEMORY_UTILIZATION="0.90"
            log "  GPU 0,1: TP=2, 64K context, 5 concurrent, 0.90 util → :8000"
            log "  Estimated: ~250 tok/s aggregate"
            ;;
        *)
            echo "ERROR: Unknown plan '$PLAN'." >&2
            echo "Choose: default, plan-long, plan-524k, plan-high" >&2
            exit 1
            ;;
    esac
}

# ── Start vLLM server ──
start_server() {
    log ""
    log "=== Starting DeepSeek-V4-Flash vLLM server ==="
    log "  Container  : $CONTAINER_NAME"
    log "  GPU        : $GPU_DEVICE (TP=$TENSOR_PARALLEL_SIZE)"
    log "  Port       : $PORT"
    log "  Context    : $MAX_MODEL_LEN"
    log "  Concurrent : $MAX_NUM_SEQS (max-num-seqs)"
    log "  Batch      : $MAX_NUM_BATCHED_TOKENS (max-num-batched-tokens)"
    log "  MTP        : $([ "$ENABLE_MTP" = 1 ] && echo "enabled (+1 draft token)" || echo "disabled")"
    log "  GPU mem    : $GPU_MEMORY_UTILIZATION"
    log "  Block size : $BLOCK_SIZE"
    log "  shm-size   : $SHM_SIZE"
    log "  P2P        : $([ "$DISABLE_CUSTOM_ALL_REDUCE" = 1 ] && echo "NCCL only (--disable-custom-all-reduce)" || echo "CustomAllreduce enabled")"

    # Ensure cache volume exists
    docker volume create "$CACHE_VOLUME" 2>/dev/null || true
    mkdir -p "$HF_CACHE_HOST"

    # Build env-var args array
    local -a env_args
    env_args+=(
        -e "CUDA_DEVICE_ORDER=PCI_BUS_ID"
        -e "CUDA_VISIBLE_DEVICES=$GPU_DEVICE"
        -e "MODEL_PATH=$MODEL_CONTAINER_PATH"
        -e "TENSOR_PARALLEL_SIZE=$TENSOR_PARALLEL_SIZE"
        -e "MAX_MODEL_LEN=$MAX_MODEL_LEN"
        -e "MAX_NUM_SEQS=$MAX_NUM_SEQS"
        -e "MAX_NUM_BATCHED_TOKENS=$MAX_NUM_BATCHED_TOKENS"
        -e "GPU_MEMORY_UTILIZATION=$GPU_MEMORY_UTILIZATION"
        -e "BLOCK_SIZE=$BLOCK_SIZE"
        -e "DISABLE_CUSTOM_ALL_REDUCE=$DISABLE_CUSTOM_ALL_REDUCE"
        -e "ENABLE_MTP=$ENABLE_MTP"
        -e "PORT=$PORT"
    )
    for ncc in "${NCCL_ENV[@]}"; do
        env_args+=(-e "$ncc")
    done

    docker run --rm -d \
        --name "$CONTAINER_NAME" \
        --gpus "\"device=$GPU_DEVICE\"" \
        "${env_args[@]}" \
        --ipc=host \
        --shm-size "$SHM_SIZE" \
        --ulimit memlock=-1 \
        --ulimit stack=67108864 \
        -p "$PORT:$PORT" \
        -v "$MODEL_HOST_PATH:$MODEL_CONTAINER_PATH:ro" \
        -v "${CACHE_VOLUME}:/root/.cache" \
        -v "$HF_CACHE_HOST:/root/.cache/huggingface" \
        "$IMAGE_NAME"

    log "  Container started (PID: $(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || echo '?'))"
}

# ── Wait for server to be inference-ready ──
wait_ready() {
    log ""
    log "=== Waiting for server to be ready (~75s typical, up to 600s) ==="

    for attempt in $(seq 1 120); do
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            "http://localhost:$PORT/health" 2>/dev/null)
        if [[ "$http_code" == "200" ]]; then
            log "  Health OK (${attempt}x5s)."
            # vLLM /health returns 200 before model warmup completes.
            # Wait for /v1/models to confirm model is loaded and ready.
            log "  Waiting for model warmup..."
            for warmup in $(seq 1 30); do
                local models_code
                models_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                    "http://localhost:$PORT/v1/models" 2>/dev/null)
                if [[ "$models_code" == "200" ]]; then
                    log "  Model loaded & ready (additional ${warmup}x5s)."
                    sleep 5  # let CUDA graphs settle
                    return 0
                fi
                sleep 5
            done
            log "  Model warmup timed out after health OK."
            return 1
        fi
        if [[ $((attempt % 12)) -eq 0 ]]; then
            log "  Still waiting... ($((attempt * 5))s elapsed)"
            log "  Recent logs:"
            docker logs "$CONTAINER_NAME" --tail 3 2>&1 | while IFS= read -r line; do
                log "    | $line"
            done
        fi
        sleep 5
    done
    log "  ERROR: Server did not become ready within 600s."
    return 1
}

# ── Smoke test ──
smoke_test() {
    log ""
    log "=== Smoke test ==="

    # First: list models
    local models_output
    models_output=$(curl -s --max-time 30 "http://localhost:$PORT/v1/models" 2>/dev/null || echo '')
    if [[ -n "$models_output" ]]; then
        local model_id
        model_id=$(echo "$models_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo '?')
        log "  Models endpoint: OK (served: $model_id)"
    else
        log "  Models endpoint: EMPTY (unusual but not fatal)"
    fi

    # Second: inference test
    log "  Running inference test..."
    local resp_file
    resp_file=$(mktemp)
    local http_code
    http_code=$(curl -s --max-time 120 -o "$resp_file" -w '%{http_code}' \
        -X POST "http://localhost:$PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer EMPTY" \
        -d '{"model":"deepseek-v4-flash","stream":false,"max_tokens":16,"temperature":0.0,
             "messages":[{"role":"user","content":"Reply with exactly: DOCKER_OK"}]}' \
        2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        local content
        content=$(python3 -c "
import json
d = json.load(open('$resp_file'))
print(d['choices'][0]['message']['content'].strip())
" 2>/dev/null || echo '')
        if [[ "$content" == *"DOCKER_OK"* ]]; then
            log "  PASS: inference correct (response: '$content')"
        else
            log "  WARN: HTTP 200 but unexpected content: '$content'"
        fi
    else
        log "  FAIL: HTTP $http_code"
        if [[ -s "$resp_file" ]]; then
            log "  Response body:"
            head -c 500 "$resp_file" | while IFS= read -r line; do log "    | $line"; done
        fi
        log "  Last 15 container log lines:"
        docker logs "$CONTAINER_NAME" --tail 15 2>&1 | while IFS= read -r line; do
            log "    | $line"
        done
        rm -f "$resp_file"
        return 1
    fi
    rm -f "$resp_file"
}

# ── Print status ──
print_status() {
    log ""
    log "============================================"
    log "  DeepSeek-V4-Flash — READY"
    log "============================================"
    log "  Plan     : $PLAN"
    log "  GPU      : $GPU_DEVICE (TP=$TENSOR_PARALLEL_SIZE)"
    log "  Context  : $MAX_MODEL_LEN ($((MAX_MODEL_LEN / 1024))K)"
    log "  MTP      : $([ "$ENABLE_MTP" = 1 ] && echo "enabled" || echo "disabled")"
    log "============================================"
    log ""
    log "OpenAI-compatible endpoint:"
    log "  http://localhost:$PORT/v1/chat/completions"
    log "  http://localhost:$PORT/v1/models"
    log ""
    log "Claude Code integration:"
    log "  export ANTHROPIC_BASE_URL=http://localhost:$PORT/v1"
    log "  export ANTHROPIC_API_KEY=not-needed"
    log ""
    log "Quick test:"
    log "  curl -X POST http://localhost:$PORT/v1/chat/completions \\"
    log "    -H 'Content-Type: application/json' \\"
    log "    -d '{\"model\":\"deepseek-v4-flash\",\"stream\":false,\"max_tokens\":32,\"temperature\":0.0,"
    log "         \"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
    log ""
    log "Monitor:"
    log "  docker logs -f $CONTAINER_NAME"
    log "  watch -n 5 nvidia-smi"
    log ""
    log "Stop:  bash $SCRIPT_DIR/stop.sh"
    log "Switch plan:  bash $SCRIPT_DIR/deploy.sh <plan-long|plan-524k|plan-high>"
}

# ── Main ──
main() {
    echo ""
    echo "============================================"
    echo "  DeepSeek-V4-Flash — vLLM + MTP Deployment"
    echo "============================================"
    echo "  Plan  : $PLAN"
    echo "  Image : $IMAGE_NAME"
    echo "  Model : W4A16 INT4 ~145 GB (2× GPU required)"
    echo "  Ref   : LordNeel model card + AIServerSetup"
    echo "============================================"
    echo ""

    preflight
    load_plan
    start_server
    wait_ready || { log "Startup failed. Check: docker logs $CONTAINER_NAME"; exit 1; }
    smoke_test || { log "Smoke test failed."; exit 1; }

    print_status
}

main
