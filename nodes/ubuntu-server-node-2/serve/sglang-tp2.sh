#!/bin/bash
# Serve Qwen3.8-27B with the SGLang gfx1100 (RDNA3) fork on 2x RX 7900 XTX.
#
# Reproduces the recipe from lcz.me/topic/1532. Requires the three P2P layers
# this node needed (see README): BIOS Above-4G+ReBAR, the patched kernel, and
# the patched RCCL. TP=2 collective traffic only uses direct P2P when
# NCCL_P2P_LEVEL=PHB is exported AND the patched RCCL image is used -- with the
# stock library or without the env var it silently falls back to SHM.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/serve/sglang-tp2.sh [MODE] [PORT] [EXTRA_ARGS]
#
# MODE: tp2 (default) — one server, --tp-size 2, both cards
#       dp1           — single server on GPU 0 (GPU 1 left free)
#
# There is deliberately no two-instance data-parallel mode: one GPU cannot hold
# this model (19 GB checkpoint on a 24 GB card), so "DP=2" never started. See
# bench/results/tp2-vs-dp2.txt.

set -euo pipefail

MODE="${1:-tp2}"
PORT="${2:-8080}"
EXTRA_ARGS="${3:-}"

MODEL_DIR="${MODEL_DIR:-/data/work/models/Vishva007/Qwen3.8-27B-W4A16-AutoRound-GPTQ}"
IMAGE="${SGLANG_IMAGE:-sglang-gfx1100-x99:local}"
CACHE_DIR="${SGLANG_CACHE_DIR:-/data/work/cache/sglang}"
CONTAINER_PREFIX="sglang-tp2"

mkdir -p "$CACHE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Pre-flight ──
docker info &>/dev/null || { echo "ERROR: Docker not accessible." >&2; exit 1; }
[[ -f "$MODEL_DIR/config.json" ]] || {
    echo "ERROR: model not found: $MODEL_DIR" >&2; exit 1; }
docker image inspect "$IMAGE" &>/dev/null || {
    echo "ERROR: image not found: $IMAGE" >&2
    echo "Build it: bash nodes/ubuntu-server-node-2/provision/build-sglang-gfx1100.sh image" >&2
    exit 1; }

# The MTP patch is mandatory; an unpatched checkpoint fails deep in the loader.
python3 - "$MODEL_DIR/config.json" <<'PYEOF' || {
import json, sys
cfg = json.load(open(sys.argv[1]))
dyn = (cfg.get("quantization_config") or {}).get("dynamic") or {}
sys.exit(1 if any(k.startswith("+") and "mtp" in k for k in dyn) else 0)
PYEOF
    echo "ERROR: checkpoint still has the buggy positive MTP quantization rules." >&2
    echo "Fix: bash nodes/ubuntu-server-node-2/serve/patch-mtp-quant-config.sh" >&2
    exit 1
}

# Warn if the patched kernel is not running: without it HIP P2P is unavailable
# and TP=2 degrades to host-staged collectives.
KREL="$(uname -r)"
if [[ "$KREL" != *x99p2p* ]]; then
    log "WARNING: running kernel is $KREL, not the patched *-x99p2p build."
    log "         HIP P2P will be unavailable and TP=2 will be slow."
fi

# ── Environment mirroring the fork README's launch recipe ──
COMMON_ENVS=(
    -e "SGLANG_RDNA_CUSTOM_AR=1"
    -e "SGLANG_RDNA_NO_FUSED=1"
    -e "SGLANG_RDNA_GEMMA_TRITON=1"
    -e "SGLANG_RDNA_VLLM_VERIFY=1"
    -e "SGLANG_DTYPE=bfloat16"
    -e "SGLANG_PHASE_TIMING=0"
    # Required for TP: without PHB the patched RCCL still chooses SHM.
    -e "NCCL_P2P_LEVEL=PHB"
    -e "HOME=/cache"
    -e "XDG_CACHE_HOME=/cache"
    -e "TRITON_CACHE_DIR=/cache/triton"
    -e "TORCHINDUCTOR_CACHE_DIR=/cache/torchinductor"
    -e "HF_HOME=/cache/hf"
    -e "HF_ENDPOINT=https://hf-mirror.com"
)

serve_args() {
    # Sized for concurrency 2 with the largest context this memory allows.
    #
    # --mem-fraction-static 0.96 (was 0.90): the goal is to spend nearly all of
    # each 24 GB card. Beyond weights (9.12 GB TP=2 shard), the MTP draft head
    # (2.78 GB) and the mamba state cache (~1.5 GB at max-mamba-cache-size 20),
    # everything left is KV. Measured KV cost is 0.03126 MiB/token/GPU, which
    # grows the shared pool from ~265k to ~313k tokens.
    #
    # --max-running-requests 2 (was 4): at 2 concurrent requests the pool is
    # shared between them, so this is what makes two long requests fit. Note it
    # still cannot hold 2 x 196608 = 393216; concurrency 2 means the COMBINED
    # length fits, not that both may use the full window.
    #
    # This model only pays full-attention KV on 16 of its 64 layers (the other
    # 48 are linear attention, held in the fixed-size mamba cache), which is why
    # a 262k-position model fits in 7.5 GB of KV at all.
    echo "--model-path /models \
--quantization gptq \
--dtype bfloat16 \
--mamba-ssm-dtype bfloat16 \
--kv-cache-dtype auto \
--attention-backend triton \
--context-length 262144 \
--mem-fraction-static 0.96 \
--max-running-requests 2 \
--max-mamba-cache-size 20 \
--speculative-algorithm EAGLE \
--speculative-draft-model-path /models \
--speculative-num-steps 3 \
--speculative-eagle-topk 1 \
--speculative-num-draft-tokens 4 \
--cuda-graph-bs-decode 1 2 4 \
--triton-attention-num-kv-splits 16 \
--sleep-on-idle \
--trust-remote-code"
}

docker_base() {
    # Runs the server as the container's main process. The previous version
    # started a container with no command and then `docker exec -d` the server
    # into it, which failed because the container exited immediately.
    local gpus="$1" name="$2" host_port="$3" tp="$4"; shift 4
    docker run --rm -d \
        --name "$name" \
        --device=/dev/kfd --device=/dev/dri \
        --group-add "$(getent group render | cut -d: -f3)" \
        --group-add "$(getent group video | cut -d: -f3)" \
        --security-opt seccomp=unconfined \
        --ipc=host \
        --shm-size=16g \
        --user "$(id -u):$(id -g)" \
        -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
        -e "ROCR_VISIBLE_DEVICES=$gpus" -e "HIP_VISIBLE_DEVICES=$gpus" \
        "${COMMON_ENVS[@]}" \
        -v "$MODEL_DIR:/models:ro" \
        -v "$CACHE_DIR:/cache:rw" \
        -p "$host_port:8000" \
        "$IMAGE" \
        python3 -m sglang.launch_server \
            --model-path /models \
            --served-model-name "$MODEL_NAME" \
            --host 0.0.0.0 --port 8000 \
            ${tp:+--tp-size "$tp"} \
            $(serve_args) $EXTRA_ARGS
}

stop_existing() {
    # NOTE: must not return non-zero when nothing matches. Under `set -e` a
    # failing `grep -q` here aborted the entire script silently — no container,
    # no output. Collect ids first, then act only if any were found.
    local ids
    ids="$(docker ps -a -q --filter "name=^$1$" || true)"
    if [[ -n "$ids" ]]; then
        log "Removing old container $1 ..."
        docker rm -f "$ids" >/dev/null 2>&1 || true
    fi
    return 0
}

wait_ready() {
    local port="$1" timeout_s="${2:-1800}"
    log "Waiting for :$port (up to ${timeout_s}s; first start compiles kernels)..."
    for i in $(seq 1 $((timeout_s / 5))); do
        if curl -s --max-time 3 "http://localhost:$port/health_generate" -o /dev/null 2>/dev/null; then
            log "Ready after $((i * 5))s."; return 0
        fi
        sleep 5
    done
    echo "ERROR: :$port never became ready. Check: docker logs ${CONTAINER_PREFIX}-*" >&2
    return 1
}

MODEL_NAME="$(basename "$MODEL_DIR")"

case "$MODE" in
  tp2)
    CN="${CONTAINER_PREFIX}-tp2"
    stop_existing "$CN"
    log "Launching TP=2 (both GPUs) on :$PORT, NCCL_P2P_LEVEL=PHB"
    docker_base "0,1" "$CN" "$PORT" "2" >/dev/null
    wait_ready "$PORT"
    log "Endpoint: http://localhost:$PORT/v1"
    ;;
  dp1)
    CN="${CONTAINER_PREFIX}-gpu0"
    stop_existing "$CN"
    log "Launching single GPU on :$PORT"
    docker_base "0" "$CN" "$PORT" "" >/dev/null
    wait_ready "$PORT"
    log "Endpoint: http://localhost:$PORT/v1"
    ;;
  *)
    echo "ERROR: unknown MODE '$MODE' (expected tp2|dp1)" >&2; exit 1 ;;
esac

log "Logs : docker logs -f ${CONTAINER_PREFIX}-*"
log "Stop : docker rm -f ${CONTAINER_PREFIX}-*"