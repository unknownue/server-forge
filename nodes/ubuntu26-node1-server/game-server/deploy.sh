#!/bin/bash
# One-click deployment script for Game Studio Server.
# Starts SGLang inference services (FP8) + ComfyUI image generation.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/game-server/deploy.sh [PLAN]
#
# Default PLAN: 2×27B + 35B-A3B(MoE) + FLUX.2 FP8
#   GPU 0: Qwen3.6-27B    FP8 TP=1 → :8000  统筹规划 + 多模态
#   GPU 1: Qwen3.6-35B-A3B FP8 TP=1 → :8001  代码生成主力(MoE)
#   GPU 2: Qwen3.6-27B    FP8 TP=1 → :8002  多模态 + 深度推理
#   GPU 3: FLUX.2 FP8              → :8188  图像生成(ComfyUI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLAN="${1:-default}"

SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
COMFYUI_IMAGE="yanwk/comfyui-boot:cu128-slim"
CACHE_DIR="/data/cache/sglang_jit"
MOE_CONFIG_DIR="$CACHE_DIR/moe_configs"
COMFYUI_HOME="/data/cache/comfyui"
FLUX_SRC_DIR="/data/work/models/Comfy-Org/flux2-dev/split_files"
MODELS_BASE="/data/work/models"
SGLANG_PATCH_DIR="$SCRIPT_DIR/config/sglang-patches/anthropic"

mkdir -p "$CACHE_DIR" "$COMFYUI_HOME"

# ── Setup MoE kernel configs for RTX 6000D (Ada Lovelace, 99KB shared mem/SM) ──
# Without these, the Triton fused MoE kernel crashes with OutOfResources under concurrent load.
# Default config uses num_stages=4 → ~144KB shared memory, exceeding the 99KB hardware limit.
setup_moe_configs() {
    local configs_dir="$MOE_CONFIG_DIR/configs/triton_3_6_0"
    local fp8_config="$configs_dir/E=256,N=512,device_name=NVIDIA_RTX_6000D,dtype=fp8_w8a8.json"
    local fp8_down_config="${fp8_config%.json}_down.json"

    if [[ -f "$fp8_config" ]] && [[ -f "$fp8_down_config" ]]; then
        return 0
    fi

    mkdir -p "$configs_dir"

    local config_json
    config_json='{
    "1": {"BLOCK_SIZE_M": 16, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 64, "GROUP_SIZE_M": 1, "num_warps": 4, "num_stages": 2},
    "2": {"BLOCK_SIZE_M": 16, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 1, "num_warps": 4, "num_stages": 2},
    "4": {"BLOCK_SIZE_M": 16, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "8": {"BLOCK_SIZE_M": 16, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "16": {"BLOCK_SIZE_M": 16, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 256, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "24": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "32": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "48": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 256, "GROUP_SIZE_M": 1, "num_warps": 4, "num_stages": 2},
    "64": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 256, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "96": {"BLOCK_SIZE_M": 32, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 256, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "128": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "256": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "512": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 256, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "1024": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 256, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "1536": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 128, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "2048": {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 128, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 32, "num_warps": 4, "num_stages": 2},
    "3072": {"BLOCK_SIZE_M": 128, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 16, "num_warps": 4, "num_stages": 2},
    "4096": {"BLOCK_SIZE_M": 128, "BLOCK_SIZE_N": 64, "BLOCK_SIZE_K": 128, "GROUP_SIZE_M": 1, "num_warps": 4, "num_stages": 2}
}'
    echo "$config_json" > "$fp8_config"
    echo "$config_json" > "$fp8_down_config"
    log "  MoE kernel configs initialized."
}

setup_moe_configs

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
            log "  GPU 1: Qwen3.6-35B-A3B FP8 → :8001 (MoE 35B→3B, tuned kernel config)"
            log "  GPU 2: Qwen3.6-27B    FP8 → :8002"
            log "  GPU 3: FLUX.2 FP8          → :8188 (ComfyUI)"
            log "  Aggregate: ~484 tok/s (text), concurrent ~97 @8K"
            
            INSTANCE_NAME[0]="gs-27b-coord"
            INSTANCE_GPUS[0]="0"
            INSTANCE_PORT[0]="8000"
            INSTANCE_MODEL[0]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[0]="1"
            INSTANCE_EXTRA_ARGS[0]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"

            INSTANCE_NAME[1]="gs-35b-moe-code"
            INSTANCE_GPUS[1]="1"
            INSTANCE_PORT[1]="8001"
            INSTANCE_MODEL[1]="${MODELS_BASE}/Qwen/Qwen3.6-35B-A3B"
            INSTANCE_TP[1]="1"
            INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 65536 --quantization fp8 --cuda-graph-max-bs 8 --max-running-requests 4 --reasoning-parser qwen3 --served-model-name Qwen3.6-35B-A3B-FP8"

            INSTANCE_NAME[2]="gs-27b-multimodal"
            INSTANCE_GPUS[2]="2"
            INSTANCE_PORT[2]="8002"
            INSTANCE_MODEL[2]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[2]="1"
            INSTANCE_EXTRA_ARGS[2]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"
            ;;

        plan-72b)
            log "  GPU 0,1: Qwen3-72B FP8 TP=2 → :8000"
            log "  GPU 2:   Qwen3.6-27B FP8    → :8001"
            log "  GPU 3:   FLUX.2 FP8         → :8188 (ComfyUI)"
            log "  Requires: Qwen/Qwen3-72B downloaded"

            INSTANCE_NAME[0]="gs-72b-coord"
            INSTANCE_GPUS[0]="0,1"
            INSTANCE_PORT[0]="8000"
            INSTANCE_MODEL[0]="${MODELS_BASE}/Qwen/Qwen3-72B"
            INSTANCE_TP[0]="2"
            INSTANCE_EXTRA_ARGS[0]="$SHARED_ARGS --quantization fp8 --context-length 65536 --reasoning-parser qwen3 --served-model-name Qwen3-72B-FP8"

            INSTANCE_NAME[1]="gs-27b-multimodal"
            INSTANCE_GPUS[1]="2"
            INSTANCE_PORT[1]="8001"
            INSTANCE_MODEL[1]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[1]="1"
            INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"
            ;;

        plan-reasoning)
            log "  GPU 0: R1-Distill-32B  FP8 → :8000"
            log "  GPU 1: Qwen3.6-35B-A3B FP8 → :8001 (MoE, tuned kernel config)"
            log "  GPU 2: Qwen3.6-27B     FP8 → :8002"
            log "  GPU 3: FLUX.2 FP8           → :8188 (ComfyUI)"
            log "  Requires: deepseek-ai/DeepSeek-R1-Distill-Qwen-32B downloaded"

            INSTANCE_NAME[0]="gs-r1-reason"
            INSTANCE_GPUS[0]="0"
            INSTANCE_PORT[0]="8000"
            INSTANCE_MODEL[0]="${MODELS_BASE}/deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
            INSTANCE_TP[0]="1"
            INSTANCE_EXTRA_ARGS[0]="$SHARED_ARGS --context-length 65536 --quantization fp8 --served-model-name DeepSeek-R1-Distill-Qwen-32B-FP8"

            INSTANCE_NAME[1]="gs-35b-moe-code"
            INSTANCE_GPUS[1]="1"
            INSTANCE_PORT[1]="8001"
            INSTANCE_MODEL[1]="${MODELS_BASE}/Qwen/Qwen3.6-35B-A3B"
            INSTANCE_TP[1]="1"
            INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 65536 --quantization fp8 --cuda-graph-max-bs 8 --max-running-requests 4 --reasoning-parser qwen3 --served-model-name Qwen3.6-35B-A3B-FP8"

            INSTANCE_NAME[2]="gs-27b-multimodal"
            INSTANCE_GPUS[2]="2"
            INSTANCE_PORT[2]="8002"
            INSTANCE_MODEL[2]="${MODELS_BASE}/Qwen/Qwen3.6-27B"
            INSTANCE_TP[2]="1"
            INSTANCE_EXTRA_ARGS[2]="$SHARED_ARGS --context-length 40960 --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-27B-FP8"
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
        -v "$MOE_CONFIG_DIR:/moe_configs:ro" \
        -e "SGLANG_MOE_CONFIG_DIR=/moe_configs" \
        -v "$SGLANG_PATCH_DIR/protocol.py:/opt/sglang/python/sglang/srt/entrypoints/anthropic/protocol.py:ro" \
        -v "$SGLANG_PATCH_DIR/serving.py:/opt/sglang/python/sglang/srt/entrypoints/anthropic/serving.py:ro" \
        "$SGLANG_IMAGE" \
        bash -c "sglang serve $extra_args --model-path /models --tp-size $tp" \
        > /dev/null 2>&1
}

# ── Setup ComfyUI model symlinks ──
setup_comfyui_models() {
    local models_dir="$COMFYUI_HOME/models"
    local workflows_dir="$COMFYUI_HOME/user/default/workflows"

    mkdir -p "$models_dir"/{diffusion_models,text_encoders,vae,loras}
    mkdir -p "$workflows_dir"

    ln -sf "$FLUX_SRC_DIR/diffusion_models/flux2_dev_fp8mixed.safetensors"  "$models_dir/diffusion_models/"  2>/dev/null || true
    ln -sf "$FLUX_SRC_DIR/text_encoders/mistral_3_small_flux2_fp8.safetensors" "$models_dir/text_encoders/" 2>/dev/null || true
    ln -sf "$FLUX_SRC_DIR/vae/flux2-vae.safetensors"                           "$models_dir/vae/"            2>/dev/null || true
    for lora in "$FLUX_SRC_DIR/loras/"*.safetensors; do
        [[ -f "$lora" ]] && ln -sf "$lora" "$models_dir/loras/" 2>/dev/null || true
    done

    # Download official workflows
    if [[ ! -f "$workflows_dir/image_flux2_fp8.json" ]]; then
        curl -sL "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/templates/image_flux2_fp8.json" \
            -o "$workflows_dir/image_flux2_fp8.json" || true
    fi
    if [[ ! -f "$workflows_dir/image_flux2.json" ]]; then
        curl -sL "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/templates/image_flux2.json" \
            -o "$workflows_dir/image_flux2.json" || true
    fi
}

# ── Start ComfyUI with FLUX.2 FP8 on GPU 3 ──
start_comfyui() {
    log ""
    log "=== Starting ComfyUI (FLUX.2 FP8) on GPU 3 ==="

    local existing
    existing=$(docker ps -q --filter "name=gs-comfyui" 2>/dev/null)
    [[ -n "$existing" ]] && docker stop "$existing" 2>/dev/null || true
    existing=$(docker ps -q --filter "publish=8188" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        log "  Stopping existing container on port 8188..."
        docker stop "$existing" 2>/dev/null || true
    fi

    if ! docker image inspect "$COMFYUI_IMAGE" &>/dev/null; then
        log "  WARN: Image '$COMFYUI_IMAGE' not found. Image gen skipped."
        log "  Pull with: docker pull $COMFYUI_IMAGE"
        return 1
    fi

    setup_comfyui_models

    # ACL: container runs as root, files must be accessible to host user
    HOST_USER="$(id -un)"
    setfacl -R -m "u:$HOST_USER:rwx" "$COMFYUI_HOME" 2>/dev/null || true
    setfacl -R -m "d:u:$HOST_USER:rwx" "$COMFYUI_HOME" 2>/dev/null || true

    log "  Starting gs-comfyui (GPU=3 port=8188)..."

    docker run --rm -d \
        --name "gs-comfyui" \
        --gpus all \
        -e "CUDA_VISIBLE_DEVICES=3" \
        --ipc=host \
        -p "8188:8188" \
        -v "$COMFYUI_HOME:/root/ComfyUI" \
        -v "$FLUX_SRC_DIR:/data/work/models/Comfy-Org/flux2-dev/split_files:ro" \
        "$COMFYUI_IMAGE" \
        > /dev/null 2>&1
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
        local model_name
        model_name=$(basename "${INSTANCE_MODEL[$i]}")

        local http_code
        http_code=$(curl -s --max-time 60 -o /dev/null -w '%{http_code}' \
            "http://localhost:$port/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$model_name\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":8}" \
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
    log "  Game Studio Server — READY"
    log "  Plan: $PLAN"
    log "============================================"
    log ""
    log "Text Inference (OpenAI-compatible /v1):"
    for i in "${!INSTANCE_NAME[@]}"; do
        local model_name
        model_name=$(basename "${INSTANCE_MODEL[$i]}")
        log "  http://localhost:${INSTANCE_PORT[$i]}/v1  ($model_name)"
    done
    log ""
    log "All endpoints serve native Anthropic /v1/messages + OpenAI /v1/chat/completions"
    log "Claude Code config: export ANTHROPIC_BASE_URL=http://localhost:8001"
    log ""
    log "Image Generation (ComfyUI API):"
    log "  http://localhost:8188/prompt  (POST workflow JSON)"
    log "  http://localhost:8188/history/{id}"
    log ""
    log "Nginx LB config: $SCRIPT_DIR/config/nginx-lb.template.conf"
    log ""
    log "Multimodal test (image understanding):"
    log '  curl http://localhost:8000/v1/chat/completions \'
    log '    -H "Content-Type: application/json" \'
    log '    -d '"'"'{"model":"Qwen3.6-27B-FP8","messages":[{"role":"user","content":[{"type":"text","text":"Describe this game screenshot."},{"type":"image_url","image_url":{"url":"https://example.com/screenshot.png"}}]}]}'"'"
    log ""
    log "To stop: bash $SCRIPT_DIR/stop.sh"
}

# ── Stop script ──
write_stop_script() {
    cat > "$SCRIPT_DIR/stop.sh" << 'STOPEOF'
#!/bin/bash
echo "Stopping Game Studio Server..."
for cid in $(docker ps -q --filter "name=gs-"); do
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
    echo "  Game Studio Server — Deployment"
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

    start_comfyui || log "  Image generation service skipped (ComfyUI unavailable)."

    write_stop_script
    print_status
}

main
