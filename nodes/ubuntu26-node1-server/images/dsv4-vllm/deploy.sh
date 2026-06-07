#!/usr/bin/env bash
# Deploy DSV4-Flash with profile-based configuration.
#
# Usage:
#   bash images/dsv4-vllm/deploy.sh <profile>
#
# Profiles:
#   default      — 2-GPU TP=2, 128K context, 3 concurrent
#   plan-long    — 2-GPU TP=2, 256K context, 2 concurrent
#   plan-524k    — 2-GPU TP=2, 524K context, 1 concurrent
#   plan-high    — 2-GPU TP=2, 64K context, 8 concurrent
#   plan-4gpu-524k — 4-GPU TP=4, 524K context, 2 concurrent
#   plan-4gpu-256k — 4-GPU TP=4, 256K context, 4 concurrent
#
# Environment:
#   SERVICE_HUB_CONTAINER_NAME — override container name (set by service-hub)

set -euo pipefail

PROFILE="${1:-default}"
IMAGE="dsv4-flash-acti-mtp:0.1.0"
MODEL_PATH="/data/work/models/LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8"
CONTAINER="${SERVICE_HUB_CONTAINER_NAME:-dsv4-flash}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- Profile definitions ---
# Each profile sets: TP GPUs MAX_MODEL_LEN MAX_NUM_SEQS GPU_MEM_UTIL
case "$PROFILE" in
  default)
    TP=2; GPUS="0,1"; MAX_LEN=131072; MAX_SEQS=3; MEM_UTIL=0.92
    ;;
  plan-long)
    TP=2; GPUS="0,1"; MAX_LEN=262144; MAX_SEQS=2; MEM_UTIL=0.94
    ;;
  plan-524k)
    TP=2; GPUS="0,1"; MAX_LEN=524288; MAX_SEQS=1; MEM_UTIL=0.93
    ;;
  plan-high)
    TP=2; GPUS="0,1"; MAX_LEN=65536; MAX_SEQS=8; MEM_UTIL=0.90
    ;;
  plan-4gpu-524k)
    TP=4; GPUS="0,1,2,3"; MAX_LEN=524288; MAX_SEQS=2; MEM_UTIL=0.94
    ;;
  plan-4gpu-256k)
    TP=4; GPUS="0,1,2,3"; MAX_LEN=262144; MAX_SEQS=4; MEM_UTIL=0.94
    ;;
  *)
    echo "ERROR: Unknown profile '$PROFILE'. Available: default, plan-long, plan-524k, plan-high, plan-4gpu-524k, plan-4gpu-256k" >&2
    exit 1
    ;;
esac

log "============================================"
log "  DSV4-Flash Deploy — Profile: $PROFILE"
log "  TP=$TP, GPUs=[$GPUS], Context=${MAX_LEN}, Concurrency=${MAX_SEQS}"
log "============================================"

# --- Stop existing container ---
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  log "Stopping existing container: $CONTAINER"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

# --- Launch ---
log "Starting container: $CONTAINER"
docker run -d \
  --name "$CONTAINER" \
  --gpus "\"device=${GPUS}\"" \
  --shm-size=16g \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -p 8000:8000 \
  -v "${MODEL_PATH}:/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8:ro" \
  -e TENSOR_PARALLEL_SIZE="$TP" \
  -e MAX_MODEL_LEN="$MAX_LEN" \
  -e MAX_NUM_SEQS="$MAX_SEQS" \
  -e GPU_MEMORY_UTILIZATION="$MEM_UTIL" \
  -e MAX_NUM_BATCHED_TOKENS=8192 \
  -e BLOCK_SIZE=256 \
  -e DISABLE_CUSTOM_ALL_REDUCE=1 \
  -e ENABLE_MTP=1 \
  "$IMAGE"

log "Container started: $CONTAINER"
log "Waiting for vLLM to become ready..."

# Health check loop (wait up to 360s — first run compiles CUDA kernels)
for i in $(seq 1 120); do
  sleep 3
  if curl -sf http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
    log "vLLM is ready! (took ~$((i * 3))s)"
    log ""
    log "Endpoint: http://127.0.0.1:8000"
    log "Model: deepseek-v4-flash"
    log "Profile: $PROFILE (TP=$TP, ${MAX_LEN} ctx, ${MAX_SEQS} concurrent)"
    exit 0
  fi
done

log "WARNING: vLLM did not become ready within 360s. Checking container logs..."
docker logs --tail 30 "$CONTAINER"
exit 1
