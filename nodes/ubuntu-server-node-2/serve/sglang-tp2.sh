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
#       dp1           — single server on one card (GPU 0 by default; the
#                       Service Hub places it on the freest GPU and exports
#                       SERVICE_HUB_GPU, so the container becomes
#                       sglang-tp2-gpu<id>)
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
    # MODE-specific sizing; called as serve_args "$MODE" from docker_base.
    local mode="$1"

    # --tool-call-parser / --reasoning-parser are REQUIRED for agent clients
    # (DSH and any OpenAI-compatible caller sending a `tools` array):
    #
    #   * SGLang's parser auto-detection only runs when a field is literally
    #     "auto" (ServerArgs defaults both to None), so with no flag the server
    #     installs NO tool parser. It then returns the model's <tool_call> XML
    #     verbatim inside message.content with tool_calls=null, and the client
    #     sees a plain answer instead of a tool invocation.
    #   * The template contains <function=/<parameter=, so detection resolves to
    #     qwen3_coder ("auto" would work too; explicit avoids depending on
    #     startup template introspection). qwen3_5 is not in SGLang's
    #     architecture fallback map, so `auto` can only use the template.
    #   * This is a thinking model and the template expects prior-turn thinking
    #     re-wrapped; without a reasoning parser the ...</think> block leaks
    #     into content and corrupts multi-turn agent history. qwen3 (not
    #     qwen3-thinking) fails to split it -- verified in-container.
    # --model-path is passed once by docker_base (it was duplicated here,
    # harmless but noisy: argparse keeps the last value).
    local common="--quantization gptq \
--dtype bfloat16 \
--mamba-ssm-dtype bfloat16 \
--kv-cache-dtype auto \
--attention-backend triton \
--max-running-requests 2 \
--cuda-graph-bs-decode 1 2 4 \
--triton-attention-num-kv-splits 16 \
--tool-call-parser qwen3_coder \
--reasoning-parser qwen3-thinking \
--sleep-on-idle \
--trust-remote-code"

    case "$mode" in
  dp1)
    # Single card (tp=1: nothing is sharded, every byte lands here).
    #
    # NO speculative decoding on purpose. EAGLE/MTP loads a second weights
    # head: 18.18 GiB target + 5.53 GiB draft on one unsharded 24 GiB card, so
    # the loader dies on the draft lm_head (torch.OutOfMemoryError, 2.37 GiB
    # asked with 2.42 GiB free) -- and had it survived, the KV budget would be
    # negative and sglang would raise "no GPU memory for the KV cache under
    # --mem-fraction-static=0.96 (minimum viable = 0.9977)". Under tp2 those
    # draft weights are sharded to 2.78 GiB/card, which is exactly why the same
    # checkpoint starts on two cards and not on one. Cost: no MTP speedup, so
    # single-card decode is meaningfully slower than tp2 -- it is the price of
    # leaving GPU 1 to ComfyUI. See README "LLM dp1 single-card profile".
    #
    # --mem-fraction-static 0.92 (was 0.96): the KV pool does NOT own the
    # leftover -- runtime memory does, and 0.96 left only 0.57 GB after cuda
    # graphs. First requests then lazy-load ~0.38 GB of Triton kernels (sglang
    # logs "Pre-load it during engine init to avoid CUDA OOM"), leaving 0.19 GB,
    # and the first long prefill died with torch.OutOfMemoryError (80 MiB asked,
    # 0 bytes free) inside _execute_extend -- that kills the SCHEDULER, hence
    # SIGQUIT, hence the whole container. Leftover after graphs ~= 23.80 x
    # (1-frac) + 0.10 - 0.46, so 0.92 buys ~1.54 GB (~1.16 GB once the Triton
    # kernels are resident) against a ~44k-token KV pool. Raise this only after
    # a long-prefill run proves the activation fits: here a miss is not a failed
    # request, it is a dead server.
    #
    # --chunked-prefill-size 2048 / --max-prefill-tokens 8192 (defaults 4096 /
    # 16384): prefill activation scales with the chunk and the OOM happened
    # exactly there. Halving the chunk halves the peak, for the price of more
    # prefill steps -- decode is unaffected.
    #
    # --max-mamba-cache-size 12 (was 8): the mamba state is NOT sharded at tp1
    # (5 state slots/request x 48 linear-attention layers), and at 8 slots
    # sglang silently capped concurrency with
    # "max_running_requests is capped to 1 by the mamba state cache". 10 slots
    # are the minimum for --max-running-requests 2; 12 leaves one spare. Each
    # extra slot costs ~0.08 GB of KV, so this is a context-for-concurrency
    # trade, not a free knob.
    #
    # --context-length 32768: KV at tp1 costs ~2x the tp2 figure (0.03126
    # MiB/token/GPU -> ~0.061 MiB/token) on a pool of only ~44k tokens, so the
    # window must stay BELOW the pool or a near-window prompt passes the length
    # check and then waits forever for pool slots that will never free. 32768
    # leaves ~11k tokens of headroom for generation and the second running
    # request. Over-length prompts get the clean HTTP 400.
    echo "$common \
--context-length 32768 \
--mem-fraction-static 0.92 \
--max-mamba-cache-size 12 \
--chunked-prefill-size 2048 \
--max-prefill-tokens 8192"
    ;;
  tp2)
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
    echo "$common \
--context-length 262144 \
--mem-fraction-static 0.96 \
--max-mamba-cache-size 20 \
--speculative-algorithm EAGLE \
--speculative-draft-model-path /models \
--speculative-num-steps 3 \
--speculative-eagle-topk 1 \
--speculative-num-draft-tokens 4"
    ;;
  *)
    echo "ERROR: serve_args: unknown mode '$mode'" >&2; exit 1 ;;
    esac
}

docker_base() {
    # Runs the server as the container's main process. The previous version
    # started a container with no command and then `docker exec -d` the server
    # into it, which failed because the container exited immediately.
    local gpus="$1" name="$2" host_port="$3" tp="$4"; shift 4
    # No --rm: a scheduler OOM kills the container, and --rm would delete the
    # only copy of that traceback (this cost a debugging cycle on 2026-10-03 --
    # same lesson the ComfyUI launcher already learned). stop_existing removes
    # the leftover container on the next start, and `docker rm -f` on stop.
    #
    # GPU pin: exactly ONE visibility env (PITFALL first found 2026-10-03 in
    # comfyui.sh, hit here 2026-10-08 when the Service Hub placed sglang-single
    # on GPU 1). ROCR_VISIBLE_DEVICES and HIP_VISIBLE_DEVICES compose as two
    # stacked filters: ROCR narrows the HSA agent list first (renumbering the
    # survivors from 0), then HIP indexes into that ALREADY-narrowed list. So
    # setting both to "1" selects index 1 of a one-device list -> zero GPUs ->
    # torch.cuda.is_available() is False and sglang dies with "No accelerator
    # (CUDA, XPU, HPU, NPU, MUSA, MPS) or platform plugin is available". The
    # pairs "0" and "0,1" only ever worked by coincidence (mask == renumbered
    # index), which is why tp2 and the old hardcoded dp1-on-GPU0 never hit it.
    # HIP_VISIBLE_DEVICES alone keeps the host-index meaning that
    # service_hub/gpu_monitor.py attributes containers by. Same convention as
    # serve/comfyui.sh.
    docker run -d \
        --name "$name" \
        --device=/dev/kfd --device=/dev/dri \
        --group-add "$(getent group render | cut -d: -f3)" \
        --group-add "$(getent group video | cut -d: -f3)" \
        --security-opt seccomp=unconfined \
        --ipc=host \
        --shm-size=16g \
        --user "$(id -u):$(id -g)" \
        -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
        -e "HIP_VISIBLE_DEVICES=$gpus" \
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
            $(serve_args "$MODE") $EXTRA_ARGS
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
        # Fail fast on a dead container. Without this check the poll spun for
        # the full 1800s against a container that exited seconds after start
        # (2026-10-08: the dual ROCR+HIP mask bug) -- and because the Service
        # Hub holds its switch lock while this script runs, the hub was stuck
        # at "Another switch or stop is already in progress" for 30 minutes.
        local running
        running="$(docker inspect -f '{{.State.Running}}' "$CN" 2>/dev/null || echo missing)"
        if [[ "$running" != "true" ]]; then
            echo "ERROR: container $CN is not running (state: $running); it died during startup. Last logs:" >&2
            docker logs --tail 40 "$CN" >&2 2>/dev/null || true
            return 1
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
    # A leftover dp1 container (sglang-tp2-gpu<id>) would hold a card and the
    # port; TP=2 supersedes it, so remove both name variants. (ComfyUI is NOT
    # touched here — §2.2 leaves stopping it to the caller / the hub's
    # conflict-aware switch.)
    stop_existing "$CN"
    stop_existing "${CONTAINER_PREFIX}-gpu0"
    stop_existing "${CONTAINER_PREFIX}-gpu1"
    log "Launching TP=2 (both GPUs) on :$PORT, NCCL_P2P_LEVEL=PHB"
    docker_base "0,1" "$CN" "$PORT" "2" >/dev/null
    wait_ready "$PORT"
    log "Endpoint: http://localhost:$PORT/v1"
    ;;
  dp1)
    # Card selection: the Service Hub places single-card services on the GPU
    # with the most free VRAM and exports SERVICE_HUB_GPU; a hand-run launch
    # keeps GPU 0. The container name carries the card so the hub's prefix
    # scan, `docker logs`, and stop_containers all track the live instance.
    # Both dp1 name variants are removed first: if placement flipped cards
    # since the last run, the stale container would otherwise linger (it is
    # started without --rm).
    DP1_GPU="${SERVICE_HUB_GPU:-0}"
    stop_existing "${CONTAINER_PREFIX}-gpu0"
    stop_existing "${CONTAINER_PREFIX}-gpu1"
    CN="${CONTAINER_PREFIX}-gpu${DP1_GPU}"
    log "Launching single GPU $DP1_GPU on :$PORT"
    docker_base "$DP1_GPU" "$CN" "$PORT" "" >/dev/null
    wait_ready "$PORT"
    log "Endpoint: http://localhost:$PORT/v1"
    ;;
  *)
    echo "ERROR: unknown MODE '$MODE' (expected tp2|dp1)" >&2; exit 1 ;;
esac

log "Logs : docker logs -f ${CONTAINER_PREFIX}-*"
log "Stop : docker rm -f ${CONTAINER_PREFIX}-*"