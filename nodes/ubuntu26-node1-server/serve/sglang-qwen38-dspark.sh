#!/bin/bash
# Serve RadixArk/Qwen3.8-27B-NVFP4 with DSPARK speculative decoding.
# Node-specific image: lmsysorg/sglang:qwen38-27b (DSPARK + hybrid Mamba/SWA fork).
#
# Usage:
#   bash serve/sglang-qwen38-dspark.sh <GPUS> <PORT> <TP> <CTX> <FRAC> <RATIO>
#
#   GPUS  CUDA_VISIBLE_DEVICES, e.g. "0" or "0,1"
#   PORT  host+container port (DSH uses 30000)
#   TP    tensor parallel size (1 or 2)
#   CTX   --context-length
#   FRAC  --mem-fraction-static
#   RATIO --mamba-full-memory-ratio
#
# Recommended configs (see bench/RESULTS.md sweep):
#   1 GPU, balanced:   bash serve/sglang-qwen38-dspark.sh 0   30000 1 131072 0.85 8
#   2 GPU, max ctx:    bash serve/sglang-qwen38-dspark.sh 0,1 30000 2 262144 0.85 8
#   4 GPU, throughput: bash serve/sglang-qwen38-dspark.sh 0,1,2,3 30000 4 262144 0.80 8
#   4 GPU, long ctx:   bash serve/sglang-qwen38-dspark.sh 0,1,2,3 30000 4 524288 0.80 8
#                      (needs SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN — added
#                      automatically by this script when CTX > 262144; 524288 is
#                      beyond the model's native 262144 training cap, extension
#                      quality not verified)
#
# Notes:
#   - frac 0.95 / ratio 11.93 OOM at any TP — do not use (see RESULTS.md).
#   - TP=2 needs NCCL_P2P_DISABLE=1 on this machine (PCIe P2P init fails;
#     see node README Maintenance Log, IOMMU entry) plus --ipc=host --shm-size=32g.
#   - --reasoning-parser qwen3 extracts <think>…</think> into the OpenAI
#     `reasoning_content` field, and --tool-call-parser qwen3_coder parses the
#     <tool_call>/<function=…>/<parameter=…> XML into the `tool_calls` field with
#     finish_reason=tool_calls. Without them SGLang streams both as raw text in
#     `content`, so DeepSeek Harness shows thinking as plain text and never sees
#     the tool call (the reply just stops).

set -euo pipefail

GPUS="${1:?Usage: $0 GPUS PORT TP CTX FRAC RATIO}"
PORT="${2:?Usage: $0 GPUS PORT TP CTX FRAC RATIO}"
TP="${3:?Usage: $0 GPUS PORT TP CTX FRAC RATIO}"
CTX="${4:?Usage: $0 GPUS PORT TP CTX FRAC RATIO}"
FRAC="${5:?Usage: $0 GPUS PORT TP CTX FRAC RATIO}"
RATIO="${6:?Usage: $0 GPUS PORT TP CTX FRAC RATIO}"

IMAGE="lmsysorg/sglang:qwen38-27b"
MODEL_DIR="/data/work/models/RadixArk/Qwen3.8-27B-NVFP4"
DRAFT_DIR="/data/work/models/RadixArk/Qwen3.8-27B-DSpark"
# Persistent compiled-kernel cache. Without it every container recreation recompiles
# triton/flashinfer kernels and the boot window balloons to ~2.5 min — DeepSeek Harness
# requests sent during that window fail with "Connection error" (its retries are
# sub-second). See node README Maintenance Log 2026-08-19.
CACHE_DIR="/data/cache/sglang_qwen38"

CONTAINER_NAME="${SERVICE_HUB_CONTAINER_NAME:-sglang-qwen38-dspark-${PORT}}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
# Errors go to stderr so the Service Hub can capture the failure reason.
log_err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

# ── Pre-flight ──
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2; exit 1
fi
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "ERROR: Image not found: $IMAGE (build/pull it first)." >&2; exit 1
fi
if [[ ! -f "$MODEL_DIR/config.json" ]]; then
    echo "ERROR: Model not found: $MODEL_DIR" >&2; exit 1
fi

# Kernel-cache dir: created by the host user, written by root inside the container.
# ACLs keep root-created cache files readable/writable by the host user afterwards.
mkdir -p "$CACHE_DIR" 2>/dev/null || true
if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -m "u:$(id -un):rwx" "$CACHE_DIR" 2>/dev/null || true
    setfacl -R -m "d:u:$(id -un):rwx" "$CACHE_DIR" 2>/dev/null || true
fi

# Remove existing container with the same name, and any container on the same port
# (the hub's switch stops profile-owned containers; this also reclaims the port from
# ad-hoc launches).
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
PORT_SQUATTER=$(docker ps -a -q --filter "publish=$PORT" 2>/dev/null)
if [[ -n "$PORT_SQUATTER" ]]; then
    log "Removing existing container on port $PORT..."
    docker rm -f "$PORT_SQUATTER" >/dev/null 2>&1 || true
fi

log ""
log "============================================"
log "  Qwen3.8-27B-NVFP4 (DSPARK)"
log "  GPU   : $GPUS (TP=$TP)"
log "  Port  : $PORT"
log "  Ctx   : $CTX  frac=$FRAC  mamba_ratio=$RATIO"
log "============================================"
log ""

DOCKER_EXTRA_ARGS=()
SGLANG_EXTRA_ARGS=()
if [[ "$TP" -gt 1 ]]; then
    # PCIe P2P is broken on this machine (NCCL "unhandled system error"); fall back
    # to shared-memory transport. Needs host IPC and a large /dev/shm.
    DOCKER_EXTRA_ARGS+=(--ipc=host --shm-size=32g)
    # Cap CUDA-graph capture (decode bs up to 256 by default costs ~2.6 GB of GPU
    # memory in private pools); together with --mem-fraction-static 0.80 this keeps
    # ~7 GB/GPU headroom (TP=2) / ~3 GB/GPU headroom (TP=4) so DSH-sized requests
    # never OOM rank 0. See RESULTS.md. NOTE: TP=4 with frac 0.85 leaves < 4 GiB
    # free, which stalls verify-graph capture for 20+ min — always use frac 0.80
    # (or lower) for TP>=4.
    SGLANG_EXTRA_ARGS+=(--cuda-graph-max-bs 32)
fi
if [[ "$CTX" -gt 262144 ]]; then
    # Model-derived context cap is 262144 (Qwen3_5 arch); TP=4 unlocks longer
    # context but requires this override (verified up to 524288, see RESULTS.md).
    DOCKER_EXTRA_ARGS+=(-e SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1)
fi

docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --gpus all \
    -e "CUDA_VISIBLE_DEVICES=$GPUS" \
    -e NCCL_P2P_DISABLE=1 \
    -e NCCL_IB_DISABLE=1 \
    "${DOCKER_EXTRA_ARGS[@]}" \
    -p "$PORT:$PORT" \
    -v /data/work/models:/data/work/models \
    -v "$CACHE_DIR:/cache" \
    -e "HOME=/cache" \
    -e "SGLANG_CACHE_DIR=/cache/sglang" \
    -e "TORCH_EXTENSIONS_DIR=/cache/torch_extensions" \
    -e "TRITON_CACHE_DIR=/cache/triton" \
    -e "FLASHINFER_WORKSPACE_BASE=/cache/flashinfer" \
    "$IMAGE" \
    python3 -m sglang.launch_server \
        --model-path "$MODEL_DIR" \
        --speculative-draft-model-path "$DRAFT_DIR" \
        --speculative-algorithm DSPARK \
        --tp-size "$TP" \
        --context-length "$CTX" \
        --mem-fraction-static "$FRAC" \
        --mamba-full-memory-ratio "$RATIO" \
        "${SGLANG_EXTRA_ARGS[@]}" \
        --reasoning-parser qwen3 \
        --tool-call-parser qwen3_coder \
        --host 0.0.0.0 \
        --port "$PORT"

# Wait for health
log "Waiting for server to be ready..."
for i in $(seq 1 150); do
    if curl -s --max-time 3 "http://localhost:$PORT/v1/models" -o /dev/null 2>/dev/null; then
        log "Ready (${i}x5s). Endpoint: http://localhost:$PORT/v1"
        exit 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log_err "container exited during startup (check: docker logs $CONTAINER_NAME)"
        exit 1
    fi
    sleep 5
done

log_err "server failed to become ready within 750s"
exit 1
