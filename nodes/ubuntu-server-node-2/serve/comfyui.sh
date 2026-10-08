#!/bin/bash
# Serve ComfyUI — the MiniMax H3 generation service (animlab Gate G1) — on
# ubuntu-server-node-2's second RX 7900 XTX, inside a ROCm container.
#
# Deployment deviates from spec tmp/COMFYUI_DEPLOY.md §3.2 in one documented
# way: the "dedicated Python venv" is a dedicated *container* image instead
# (user decision, 2026-10-03). Rationale: this node has no host ROCm and no
# python3-venv/pip (README), while every working GPU service here already runs
# in Docker. Everything else in the spec holds: GPU pinning (§2), cache paths
# (§3.4 → /data/work/cache, this node's writable cache root), port 8189 (§7.2),
# 0.0.0.0 LAN bind with no CORS (§8), logs under the repo tmp/ (§7.4).
#
# GPU allocation (§2, hard requirement):
#   * Card selection order: SERVICE_HUB_GPU (set by the Service Hub, which
#     places single-card services on the GPU with the most free VRAM at start
#     time) > COMFYUI_GPU (manual override) > 1 (default — the historical
#     steady state keeps card 0 for the single-card LLM).
#   * PITFALL (found 2026-10-03): exporting BOTH ROCR_VISIBLE_DEVICES=1 and
#     HIP_VISIBLE_DEVICES=1 masks the device TWICE — ROCR first narrows the list
#     to [card1], then HIP's index 1 is applied to that already-filtered list
#     where index 1 no longer exists => 0 devices and torch dies with
#     "No CUDA GPUs are available". Set exactly ONE; HIP_VISIBLE_DEVICES alone
#     is what torch.cuda honors (verified: count=1, matmul OK on card1).
#     (sglang-tp2.sh passes both with symmetric values like "0,1", which only
#     survives the double mask by luck — do not copy that pattern here.)
#   * The steady state is: SGLang single-card profile on GPU 0 + ComfyUI on
#     GPU 1 (profiles/sglang-single.yaml). Sunshine also runs on card1 but only
#     uses the VCN encoder + ~0.15 GB VRAM — it does not contend for compute.
#   * STOP-SHIP (§2.2): the SGLang TP2 profile needs BOTH cards. Starting TP2
#     while this container runs would collide — this script refuses to start
#     when a TP2 container is up, and you must `stop` ComfyUI before TP2 runs
#     (or stop the LLM before a long generation campaign).
#
# Usage:
#   bash nodes/ubuntu-server-node-2/serve/comfyui.sh              # start (default)
#   bash nodes/ubuntu-server-node-2/serve/comfyui.sh stop
#   bash nodes/ubuntu-server-node-2/serve/comfyui.sh logs
#   bash nodes/ubuntu-server-node-2/serve/comfyui.sh status
#   bash nodes/ubuntu-server-node-2/serve/comfyui.sh start [PORT] [EXTRA_ARGS]
#
#   COMFYUI_GPU=0 bash ... start     # manual override (rare; see §2)
#                                     # SERVICE_HUB_GPU, when set by the hub,
#                                     # wins over this.
#
# VARIANT POLICY (2026-10-08): docker is the ONLY way this service runs. The
# 2026-10-05 native dev variant (serve/comfyui-native.sh + the uv-built venv)
# was removed on 2026-10-08 (user decision) — do not reintroduce a host-process
# launcher; ComfyUI/custom-node code edits go through $COMFYUI_HOME plus this
# container (rebuild the image via provision/build-comfyui.sh when deps change).
#
# First start after a machine change:
#   bash nodes/ubuntu-server-node-2/provision/build-comfyui.sh   # if image missing

set -euo pipefail

ACTION="${1:-start}"
PORT="${2:-8189}"
EXTRA_ARGS="${3:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/discover.sh"

COMFYUI_HOME="${COMFYUI_HOME:-/data/work/comfyui}"
# This node's /data/cache is root-owned and unwritable (README "Permissions
# caveat"); scripts here default to /data/work/cache — same two-tier layout,
# different mount point, recorded as a §3.4 deviation in the G1 report.
CACHE_DIR="${COMFYUI_CACHE_DIR:-/data/work/cache/comfyui}"
IMAGE="${COMFYUI_IMAGE:-comfyui-gfx1100:local}"
NAME="comfyui"
# Service Hub placement wins when set (hub picks the freest card per start);
# a manual COMFYUI_GPU override applies to hand-run launches; 1 keeps the
# historical steady state (card 0 = single-card LLM). Exactly ONE visibility
# env is exported below — see the §2 pitfall in the header.
GPU="${SERVICE_HUB_GPU:-${COMFYUI_GPU:-1}}"
LOG_DIR="$REPO_ROOT/tmp/comfyui"
LOG_FILE="$LOG_DIR/comfyui.log"

log() { echo "[$(date +%H:%M:%S)] $*"; }

preflight() {
    docker info &>/dev/null || { echo "ERROR: Docker not accessible." >&2; exit 1; }

    # :8189 exclusivity (generalized 2026-10-08 from the retired
    # native-variant guard): refuse instead of letting `docker run` die on a
    # port-bind error when something other than this launcher's container is
    # already serving the port.
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME" \
        && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$"; then
        echo "ERROR: something other than the '$NAME' container is listening on :$PORT." >&2
        exit 1
    fi

    [[ -f "$COMFYUI_HOME/main.py" ]] || {
        echo "ERROR: ComfyUI not found at $COMFYUI_HOME" >&2; exit 1; }
    docker image inspect "$IMAGE" &>/dev/null || {
        echo "ERROR: image not found: $IMAGE" >&2
        echo "Build it: bash nodes/ubuntu-server-node-2/provision/build-comfyui.sh" >&2
        exit 1; }

    # §2.2 stop-ship guard: the TP2 LLM profile owns both cards.
    if docker ps --format '{{.Names}}' | grep -qx 'sglang-tp2-tp2'; then
        echo "ERROR: SGLang TP2 is running (uses GPU 0 AND GPU 1)." >&2
        echo "Stop it first: docker rm -f sglang-tp2-tp2" >&2
        echo "Rule (§2.2): stop ComfyUI before TP2 LLM runs, or stop the LLM before generation." >&2
        exit 1
    fi

    # Models must be in place — loader dropdowns gate on exact §5 filenames.
    local missing=0 f
    for f in \
        diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors \
        text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors \
        vae/minimax_h3_video_vae_fp16.safetensors \
        vae/minimax_h3_audio_vae_fp32.safetensors \
        loras/minimax_h3_turbo_v4_step600_ema.safetensors \
        diffusion_models/z_image_turbo_bf16.safetensors \
        text_encoders/qwen_3_4b.safetensors \
        vae/ae.safetensors; do
        [[ -s "$COMFYUI_HOME/models/$f" ]] || { echo "  missing: models/$f"; missing=1; }
    done
    if [[ "$missing" == 1 ]]; then
        echo "ERROR: model set incomplete. Run:" >&2
        echo "  bash nodes/ubuntu-server-node-2/download-comfyui-models.sh" >&2
        exit 1
    fi

    mkdir -p "$CACHE_DIR"/{triton,torchinductor,hf} "$LOG_DIR"
}

start() {
    preflight

    # Host-pinned GPU, caches under /data/work/cache, HF via mirror (§3.4/§5).
    # NOTE: no --rm here — a crashing container must keep its logs reachable via
    # `docker logs comfyui` (the first --rm run ate its own traceback).
    # GPU pin: exactly ONE visibility env (see header) — dual ROCR+HIP masking
    # zeroes out GPU 1 and torch dies with "No CUDA GPUs are available".
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    log "Launching ComfyUI on GPU $GPU, port $PORT (LAN bind 0.0.0.0, no CORS per §8)"
    # EMFILE fix (animlab Gate G2, 2026-10-03): docker's default soft
    # nofile=1024 is exhausted during MiniMax H3 text encoding: model
    # mmaps plus ComfyUI's pinned-memory/psutil path die with
    # "[Errno 24] Too many open files: /proc/meminfo". 262144 matches
    # the image's hard cap headroom and costs nothing at idle.
    docker run -d \
        --name "$NAME" \
        --device=/dev/kfd --device=/dev/dri \
        --group-add "$(getent group render | cut -d: -f3)" \
        --group-add "$(getent group video | cut -d: -f3)" \
        --security-opt seccomp=unconfined \
        --ipc=host \
        --ulimit nofile=262144:262144 \
        --shm-size=8g \
        --user "$(id -u):$(id -g)" \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -e "HIP_VISIBLE_DEVICES=$GPU" \
        -e "HOME=/cache" \
        -e "XDG_CACHE_HOME=/cache" \
        -e "TRITON_CACHE_DIR=/cache/triton" \
        -e "TORCHINDUCTOR_CACHE_DIR=/cache/torchinductor" \
        -e "HF_HOME=/cache/hf" \
        -e "HF_ENDPOINT=https://hf-mirror.com" \
        -v "$COMFYUI_HOME:/ComfyUI" \
        -v "$CACHE_DIR:/cache" \
        -p "$PORT:$PORT" \
        "$IMAGE" \
        python3 main.py --listen 0.0.0.0 --port "$PORT" $EXTRA_ARGS >/dev/null

    wait_ready "$PORT"
    log "Endpoint     : http://<node-ip>:$PORT  (node LAN IP: $(ip -brief addr show enp8s0 2>/dev/null | awk '{print $2}' | cut -d/ -f1))"
    log "system_stats : curl -s http://localhost:$PORT/system_stats"
    log "Logs         : bash $0 logs   (also tees to $LOG_FILE)"
    log "Stop         : bash $0 stop"
}

stop() {
    if docker rm -f "$NAME" >/dev/null 2>&1; then
        log "Stopped $NAME."
    else
        log "Not running."
    fi
}

status() {
    if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
        docker ps --filter "name=^$NAME$" --format 'Up: {{.Status}}  Ports: {{.Ports}}'
        curl -s --max-time 3 "http://localhost:${PORT}/system_stats" >/dev/null \
            && log "system_stats: OK" || log "system_stats: not responding yet"
    else
        log "Not running."
    fi
}

logs() {
    mkdir -p "$LOG_DIR"
    log "Following $NAME logs -> $LOG_FILE (Ctrl-C stops following, container keeps running)"
    docker logs -f "$NAME" 2>&1 | tee -a "$LOG_FILE"
}

wait_ready() {
    local port="$1" timeout_s="${2:-300}" i
    log "Waiting for :$port (up to ${timeout_s}s; first start compiles kernels)..."
    # NOTE: use a named loop var — `$_` is Bash's "last argument of the previous
    # command" (e.g. /dev/null here), and `$((_ * 3))` aborts the script with an
    # arithmetic syntax error right after a successful readiness check.
    for i in $(seq 1 $((timeout_s / 3))); do
        if curl -s --max-time 3 "http://localhost:$port/system_stats" -o /dev/null 2>/dev/null; then
            log "Ready after ~$((i * 3))s."
            return 0
        fi
        # Fail fast if the container died instead of spinning the full timeout.
        if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
            echo "ERROR: container exited. Logs: docker logs $NAME" >&2
            return 1
        fi
        sleep 3
    done
    echo "ERROR: :$port never became ready. Check: docker logs $NAME" >&2
    return 1
}

case "$ACTION" in
  start) start ;;
  stop) stop ;;
  logs) logs ;;
  status) status ;;
  *) echo "ERROR: unknown action '$ACTION' (expected start|stop|logs|status)" >&2; exit 1 ;;
esac