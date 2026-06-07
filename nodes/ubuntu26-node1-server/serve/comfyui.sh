#!/bin/bash
# Launch ComfyUI with FLUX.2 FP8 for image generation.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/serve/comfyui.sh [GPU] [PORT]
#
# Default: GPU=3, port=8188

set -euo pipefail

GPU="${1:-3}"
PORT="${2:-8188}"

MODELS_BASE="/data/work/models"
COMFYUI_HOME="/data/cache/comfyui"
FLUX_SRC="${MODELS_BASE}/Comfy-Org/flux2-dev/split_files"

COMFYUI_IMAGE="yanwk/comfyui-boot:cu128-slim"
_DEFAULT_NAME="comfyui-${PORT}"
CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-$_DEFAULT_NAME}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Pre-flight ──
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2; exit 1
fi

# ── Setup model directory structure for ComfyUI ──
setup_models() {
    log "=== Setting up ComfyUI model directories ==="

    local models_dir="$COMFYUI_HOME/models"
    local workflows_dir="$COMFYUI_HOME/user/default/workflows"

    mkdir -p "$models_dir"/{diffusion_models,text_encoders,vae,loras}
    mkdir -p "$workflows_dir"

    local src="$FLUX_SRC"

    if [[ ! -d "$src" ]]; then
        echo "ERROR: FLUX.2 model not found at $FLUX_SRC" >&2
        echo "Run: bash scripts/lib/download-model.sh Comfy-Org/flux2-dev" >&2
        exit 1
    fi

    ln -sf "$src/diffusion_models/flux2_dev_fp8mixed.safetensors"  "$models_dir/diffusion_models/"  2>/dev/null || true
    ln -sf "$src/text_encoders/mistral_3_small_flux2_fp8.safetensors" "$models_dir/text_encoders/" 2>/dev/null || true
    ln -sf "$src/vae/flux2-vae.safetensors"                           "$models_dir/vae/"            2>/dev/null || true
    for lora in "$src/loras/"*.safetensors; do
        [[ -f "$lora" ]] && ln -sf "$lora" "$models_dir/loras/" 2>/dev/null || true
    done

    log "  Models linked."

    # Download official FLUX.2 workflows if not present
    if [[ ! -f "$workflows_dir/image_flux2_fp8.json" ]]; then
        log "  Downloading FP8 workflow..."
        curl -sL "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/templates/image_flux2_fp8.json" \
            -o "$workflows_dir/image_flux2_fp8.json" || log "  WARN: Failed to download FP8 workflow"
    fi
    if [[ ! -f "$workflows_dir/image_flux2.json" ]]; then
        log "  Downloading FP16 workflow..."
        curl -sL "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/refs/heads/main/templates/image_flux2.json" \
            -o "$workflows_dir/image_flux2.json" || log "  WARN: Failed to download FP16 workflow"
    fi
}

# ── Stop existing ──
existing=$(docker ps -a -q --filter "name=$CONTAINER_NAME" 2>/dev/null)
[[ -n "$existing" ]] && docker rm -f "$existing" 2>/dev/null || true
existing=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
if [[ -n "$existing" ]]; then
    log "Stopping existing container on port $PORT..."
    docker rm -f "$existing" 2>/dev/null || true
fi

# ── Pull image if needed ──
if ! docker image inspect "$COMFYUI_IMAGE" &>/dev/null; then
    echo "ERROR: Image '$COMFYUI_IMAGE' not found." >&2
    echo "Pull with: docker pull $COMFYUI_IMAGE" >&2
    exit 1
fi

setup_models

# ── Set ACLs: container runs as root, files must be accessible to host user ──
HOST_USER="$(id -un)"
setfacl -R -m "u:$HOST_USER:rwx" "$COMFYUI_HOME" 2>/dev/null || true
setfacl -R -m "d:u:$HOST_USER:rwx" "$COMFYUI_HOME" 2>/dev/null || true

log "Starting ComfyUI (FLUX.2 FP8 on GPU $GPU, port $PORT)..."

docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=$GPU" \
    --ipc=host \
    -p "$PORT:8188" \
    -v "$COMFYUI_HOME:/root/ComfyUI" \
    -v "$FLUX_SRC:/data/work/models/Comfy-Org/flux2-dev/split_files:ro" \
    "$COMFYUI_IMAGE" \
    > /dev/null 2>&1

log "ComfyUI started. Waiting for health check..."
for attempt in $(seq 1 90); do
    if curl -s -o /dev/null "http://localhost:$PORT/system_stats" 2>/dev/null; then
        log "ComfyUI ready at http://localhost:$PORT"
        log "  Submit workflow: POST http://localhost:$PORT/prompt"
        log "  Check result:    GET  http://localhost:$PORT/history/{prompt_id}"
        exit 0
    fi
    sleep 2
done

log "WARN: ComfyUI may still be loading (FLUX.2 is large)."
log "Check: docker logs $CONTAINER_NAME"
