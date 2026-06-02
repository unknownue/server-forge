#!/bin/bash
# One-click deployment script for Web Studio Server.
# Starts 4× SGLang text inference services (no image generation).
#
# Usage:
#   bash nodes/ubuntu26-node1-server/web-server/deploy.sh [PLAN]
#
# Default PLAN: 3×27B + 35B-A3B(MoE)
#   GPU 0: Qwen3.6-27B    FP8 TP=1 → :8000
#   GPU 1: Qwen3.6-35B-A3B BF16 TP=1 → :8001 (MoE, code gen)
#   GPU 2: Qwen3.6-27B    FP8 TP=1 → :8002
#   GPU 3: Qwen3.6-27B    FP8 TP=1 → :8003

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLAN="${1:-default}"

SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
PROXY_IMAGE="server-forge/anthropic-proxy:latest"
PROXY_PORT="8090"
CACHE_DIR="/data/cache/sglang_jit"
MODELS_BASE="/data/work/models"

mkdir -p "$CACHE_DIR"

declare -A INSTANCE_NAME INSTANCE_GPUS INSTANCE_PORT INSTANCE_MODEL INSTANCE_TP INSTANCE_EXTRA_ARGS

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Shared SGLang flags ──
SHARED_ARGS="--host 0.0.0.0 --port 8000 \
--attention-backend flashinfer --kv-cache-dtype fp8_e5m2 \
--mem-fraction-static 0.85"

# ── Pre-flight checks ──
preflight() {
    log "=== Pre-flight checks ==="

    if ! docker info &>/dev/null; then
        echo "ERROR: Docker not accessible." >&2; exit 1
    fi
    if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
        echo "ERROR: Image '$SGLANG_IMAGE' not found." >&2
        echo "Pull with: docker pull $SGLANG_IMAGE" >&2
        exit 1
    fi
    log "  Docker + SGLang image: OK"
}

# ── Load plan configuration ──
load_plan() {
    log "=== Loading plan: $PLAN ==="

    case "$PLAN" in
        default)
            log "  GPU 0: Qwen3.6-27B    FP8 → :8000"
            log "  GPU 1: Qwen3.6-35B-A3B FP8 → :8001 (MoE 35B→3B)"
            log "  GPU 2: Qwen3.6-27B    FP8 → :8002"
            log "  GPU 3: Qwen3.6-27B    FP8 → :8003"
            log "  Aggregate: ~586 tok/s (text), concurrent ~150 @8K"
            log "  Note: MoE FP8 reduces weights 70→35 GB, KV Cache 13.6→48.6 GB (+257%)"

            INSTANCE_NAME[0]="ws-27b-a"
            INSTANCE_GPUS[0]="0"
            INSTANCE_PORT[0]="8000"
            INSTANCE_MODEL[0]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[0]="1"
            INSTANCE_EXTRA_ARGS[0]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"

            INSTANCE_NAME[1]="ws-35b-moe-code"
            INSTANCE_GPUS[1]="1"
            INSTANCE_PORT[1]="8001"
            INSTANCE_MODEL[1]="${MODELS_BASE}/Qwen/Qwen3.6-35B-A3B"
            INSTANCE_TP[1]="1"
            INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-35B-A3B-FP8"

            INSTANCE_NAME[2]="ws-27b-b"
            INSTANCE_GPUS[2]="2"
            INSTANCE_PORT[2]="8002"
            INSTANCE_MODEL[2]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[2]="1"
            INSTANCE_EXTRA_ARGS[2]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"

            INSTANCE_NAME[3]="ws-27b-c"
            INSTANCE_GPUS[3]="3"
            INSTANCE_PORT[3]="8003"
            INSTANCE_MODEL[3]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[3]="1"
            INSTANCE_EXTRA_ARGS[3]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"
            ;;

        plan-72b)
            log "  GPU 0,1: Qwen3-72B FP8 TP=2 → :8000"
            log "  GPU 2:   Qwen3.6-27B FP8    → :8001"
            log "  GPU 3:   Qwen3.6-27B FP8    → :8002"
            log "  Requires: Qwen/Qwen3-72B downloaded"

            INSTANCE_NAME[0]="ws-72b"
            INSTANCE_GPUS[0]="0,1"
            INSTANCE_PORT[0]="8000"
            INSTANCE_MODEL[0]="${MODELS_BASE}/Qwen/Qwen3-72B"
            INSTANCE_TP[0]="2"
            INSTANCE_EXTRA_ARGS[0]="$SHARED_ARGS --quantization fp8 --context-length 65536 --reasoning-parser qwen3 --served-model-name Qwen3-72B-FP8"

            INSTANCE_NAME[1]="ws-27b-a"
            INSTANCE_GPUS[1]="2"
            INSTANCE_PORT[1]="8001"
            INSTANCE_MODEL[1]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[1]="1"
            INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"

            INSTANCE_NAME[2]="ws-27b-b"
            INSTANCE_GPUS[2]="3"
            INSTANCE_PORT[2]="8002"
            INSTANCE_MODEL[2]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[2]="1"
            INSTANCE_EXTRA_ARGS[2]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"
            ;;

        plan-reasoning)
            log "  GPU 0: R1-Distill-32B  FP8 → :8000"
            log "  GPU 1: Qwen3.6-35B-A3B FP8 → :8001 (MoE)"
            log "  GPU 2: Qwen3.6-27B     FP8 → :8002"
            log "  GPU 3: Qwen3.6-27B     FP8 → :8003"
            log "  Requires: deepseek-ai/DeepSeek-R1-Distill-Qwen-32B downloaded"

            INSTANCE_NAME[0]="ws-r1-reason"
            INSTANCE_GPUS[0]="0"
            INSTANCE_PORT[0]="8000"
            INSTANCE_MODEL[0]="${MODELS_BASE}/deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
            INSTANCE_TP[0]="1"
            INSTANCE_EXTRA_ARGS[0]="$SHARED_ARGS --context-length 65536 --quantization fp8 --served-model-name DeepSeek-R1-Distill-Qwen-32B-FP8"

            INSTANCE_NAME[1]="ws-35b-moe-code"
            INSTANCE_GPUS[1]="1"
            INSTANCE_PORT[1]="8001"
            INSTANCE_MODEL[1]="${MODELS_BASE}/Qwen/Qwen3.6-35B-A3B"
            INSTANCE_TP[1]="1"
            INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-35B-A3B-FP8"

            INSTANCE_NAME[2]="ws-27b-a"
            INSTANCE_GPUS[2]="2"
            INSTANCE_PORT[2]="8002"
            INSTANCE_MODEL[2]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[2]="1"
            INSTANCE_EXTRA_ARGS[2]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"

            INSTANCE_NAME[3]="ws-27b-b"
            INSTANCE_GPUS[3]="3"
            INSTANCE_PORT[3]="8003"
            INSTANCE_MODEL[3]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[3]="1"
            INSTANCE_EXTRA_ARGS[3]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"
            ;;

        *)
            echo "ERROR: Unknown plan '$PLAN'." >&2
            echo "Choose: default, plan-72b, plan-reasoning" >&2
            exit 1
            ;;
    esac

    local count=0
    for i in "${!INSTANCE_NAME[@]}"; do count=$((count + 1)); done
    log "  $count text instances configured:"
    for i in "${!INSTANCE_NAME[@]}"; do
        log "    ${INSTANCE_NAME[$i]}: GPU=${INSTANCE_GPUS[$i]} TP=${INSTANCE_TP[$i]} port=${INSTANCE_PORT[$i]}"
    done
}

# ── Validate models exist ──
validate_models() {
    log ""
    log "=== Validating models ==="
    local all_ok=1
    local seen=()
    for i in "${!INSTANCE_NAME[@]}"; do
        local model_dir="${INSTANCE_MODEL[$i]}"
        if [[ " ${seen[*]} " =~ " ${model_dir} " ]]; then
            continue
        fi
        seen+=("$model_dir")
        if [[ -f "$model_dir/config.json" ]]; then
            log "  OK: $model_dir"
        else
            log "  MISSING: $model_dir"
            log "    → bash scripts/lib/download-model.sh"
            all_ok=0
        fi
    done
    if [[ "$all_ok" == "0" ]]; then
        echo ""
        echo "ERROR: Some models are missing. Download them first." >&2
        exit 1
    fi
}

# ── Start a single SGLang instance ──
start_instance() {
    local idx="$1"
    local name="${INSTANCE_NAME[$idx]}"
    local gpus="${INSTANCE_GPUS[$idx]}"
    local port="${INSTANCE_PORT[$idx]}"
    local model="${INSTANCE_MODEL[$idx]}"
    local tp="${INSTANCE_TP[$idx]}"
    local extra_args="${INSTANCE_EXTRA_ARGS[$idx]}"

    local existing
    existing=$(docker ps -q --filter "name=$name" 2>/dev/null)
    [[ -n "$existing" ]] && docker stop "$existing" 2>/dev/null || true
    existing=$(docker ps -q --filter "publish=$port" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Stopping existing container on port $port..."
        docker stop "$existing" 2>/dev/null || true
    fi

    log "  Starting $name (GPU=$gpus TP=$tp port=$port)..."

    docker run --rm -d \
        --name "$name" \
        --gpus all \
        -e "CUDA_VISIBLE_DEVICES=$gpus" \
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
        -v "$model:/models:ro" \
        -v "$CACHE_DIR:/cache:rw" \
        "$SGLANG_IMAGE" \
        bash -c "sglang serve $extra_args --model-path /models --tp-size $tp" \
        > /dev/null 2>&1
}

# ── Start Anthropic↔OpenAI translation proxy ──
start_proxy() {
    log ""
    log "=== Starting API translation proxy ==="

    local existing
    existing=$(docker ps -q --filter "name=ws-proxy" 2>/dev/null)
    [[ -n "$existing" ]] && docker stop "$existing" 2>/dev/null || true
    existing=$(docker ps -q --filter "publish=$PROXY_PORT" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Stopping existing container on port $PROXY_PORT..."
        docker stop "$existing" 2>/dev/null || true
    fi

    # Build proxy image if not present
    if ! docker image inspect "$PROXY_IMAGE" &>/dev/null; then
        log "  Building proxy image..."
        docker build -f "$SCRIPT_DIR/config/proxy.dockerfile" -t "$PROXY_IMAGE" "$REPO_ROOT" || {
            log "  WARN: Proxy image build failed. Skipping proxy."
            return 1
        }
    fi

    local backend_8000="http://localhost:8000/v1"
    local backend_8001="http://localhost:8001/v1"
    local backend_8002="http://localhost:8002/v1"
    local default_backend="http://localhost:8000/v1"

    if [[ "$PLAN" == "plan-72b" ]]; then
        backend_8001="http://localhost:8001/v1"
    fi

    log "  Starting ws-proxy (port $PROXY_PORT)..."
    docker run --rm -d \
        --name "ws-proxy" \
        --network host \
        -e "BACKEND_8000=$backend_8000" \
        -e "BACKEND_8001=$backend_8001" \
        -e "BACKEND_8002=$backend_8002" \
        -e "DEFAULT_BACKEND=$default_backend" \
        -e "PROXY_PORT=$PROXY_PORT" \
        "$PROXY_IMAGE" \
        > /dev/null 2>&1

    log "  Proxy started. Anthropic endpoint: http://localhost:$PROXY_PORT/v1/messages"
}

# ── Wait for all instances to be healthy ──
wait_all() {
    log ""
    log "=== Waiting for all instances to be ready ==="

    local ports=()
    for i in "${!INSTANCE_NAME[@]}"; do
        ports+=("${INSTANCE_PORT[$i]}")
    done

    for attempt in $(seq 1 300); do
        local all_ready=1
        for port in "${ports[@]}"; do
            if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/health" 2>/dev/null)" != "200" ]]; then
                all_ready=0
                break
            fi
        done
        if [[ "$all_ready" == "1" ]]; then
            log "  All text instances ready (${attempt}x2s)."
            return 0
        fi
        if [[ $((attempt % 30)) -eq 0 ]]; then
            log "  Still waiting... ($((attempt * 2))s elapsed)"
        fi
        sleep 2
    done
    log "  ERROR: Not all instances became ready within 600s."
    return 1
}

# ── Smoke test all text instances ──
smoke_all() {
    log ""
    log "=== Smoke tests ==="
    local all_pass=1

    for i in "${!INSTANCE_NAME[@]}"; do
        local name="${INSTANCE_NAME[$i]}"
        local port="${INSTANCE_PORT[$i]}"

        local http_code
        http_code=$(curl -s --max-time 60 -o /dev/null -w '%{http_code}' \
            "http://localhost:$port/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$(basename "${INSTANCE_MODEL[$i]}")\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":8}" \
            2>/dev/null)

        if [[ "$http_code" == "200" ]]; then
            log "  PASS: $name (port $port)"
        else
            log "  FAIL: $name (port $port) — HTTP $http_code"
            all_pass=0
        fi
    done

    [[ "$all_pass" == "0" ]] && { echo "ERROR: Smoke tests failed." >&2; return 1; }
}

# ── Print status ──
print_status() {
    log ""
    log "============================================"
    log "  Web Studio Server — READY"
    log "  Plan: $PLAN"
    log "============================================"
    log ""
    log "Text Inference (OpenAI-compatible /v1):"
    for i in "${!INSTANCE_NAME[@]}"; do
        log "  http://localhost:${INSTANCE_PORT[$i]}/v1  ($(basename "${INSTANCE_MODEL[$i]}"))"
    done
    log ""
    log "API Translation Proxy (Anthropic + OpenAI, unified port):"
    log "  http://localhost:$PROXY_PORT/v1/messages       (Anthropic Messages API)"
    log "  http://localhost:$PROXY_PORT/v1/chat/completions (OpenAI passthrough)"
    log "  Model routing (real names → backend):"
    log "    Qwen3.6-27B-FP8        → :8000 (default, 3× pool on :8000/:8002/:8003)"
    log "    Qwen3.6-35B-A3B-FP8    → :8001 (MoE)"
    log "  Fuzzy: 35B/A3B/MoE → :8001 | 27B/72B/32B → :8000"
    log "  Claude Code config: export ANTHROPIC_BASE_URL=http://localhost:$PROXY_PORT/v1"
    log ""
    log "Load distribution:"
    log "  The 3× 27B instances (:8000, :8002, :8003) are interchangeable."
    log "  Distribute via Nginx least_conn or direct port routing."
    log ""
    log "To stop: bash $SCRIPT_DIR/stop.sh"
}

# ── Stop script ──
write_stop_script() {
    cat > "$SCRIPT_DIR/stop.sh" << 'STOPEOF'
#!/bin/bash
echo "Stopping Web Studio Server..."
for cid in $(docker ps -q --filter "name=ws-"); do
    docker stop "$cid" 2>/dev/null || true
done
echo "All stopped."
STOPEOF
    chmod +x "$SCRIPT_DIR/stop.sh"
}

# ── Main ──
main() {
    echo ""
    echo "============================================"
    echo "  Web Studio Server — Deployment"
    echo "  Plan  : $PLAN"
    echo "  Image : $SGLANG_IMAGE (CUDA 13.2, FP8)"
    echo "============================================"
    echo ""

    preflight
    load_plan
    validate_models

    log ""
    log "=== Starting text inference services ==="
    for i in "${!INSTANCE_NAME[@]}"; do
        start_instance "$i"
    done

    wait_all || { log "Startup failed. Check docker logs for details."; exit 1; }
    smoke_all || { log "Smoke tests failed."; exit 1; }

    start_proxy || log "  Translation proxy skipped (build failed or unavailable)."

    write_stop_script
    print_status
}

main
