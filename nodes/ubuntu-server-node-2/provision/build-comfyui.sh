#!/bin/bash
# Build the ComfyUI service image: python dependency layer on rocm/pytorch.
#
# Unlike the other provision/ scripts this one needs no root — the account is
# in the `docker` group — but per the spec's agent/user boundary it is still
# listed as a user-executed provisioning step. No host ROCm install is needed:
# the rocm/pytorch image carries ROCm userspace + torch ROCm wheels inside.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/provision/build-comfyui.sh [check|build]
#
#   check — print the pinned versions this node's ComfyUI service runs
#   build — (re)build comfyui-gfx1100:local (default)

set -euo pipefail

ACTION="${1:-build}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/discover.sh"

COMFYUI_HOME="${COMFYUI_HOME:-/data/work/comfyui}"
BASE_IMAGE="${BASE_IMAGE:-docker.m.daocloud.io/rocm/pytorch:latest}"
IMAGE_TAG="${IMAGE_TAG:-comfyui-gfx1100:local}"
DOCKERFILE="$REPO_ROOT/nodes/ubuntu-server-node-2/images/comfyui/Dockerfile"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# The build context is assembled under the repo's tmp/ (spec: intermediates go
# to tmp/, never /tmp). It holds ONLY the dependency manifests the Dockerfile
# COPYs — using the ComfyUI checkout itself as context would ship ~100 GB of
# models to the docker daemon on every build.
preflight() {
    docker info &>/dev/null || { echo "ERROR: Docker not accessible." >&2; exit 1; }
    for f in "$COMFYUI_HOME/requirements.txt" \
             "$COMFYUI_HOME/custom_nodes/ComfyUI-KJNodes/requirements.txt" \
             "$COMFYUI_HOME/custom_nodes/Comfyui-Memory_Cleanup/requirements.txt"; do
        [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2
            echo "Clone ComfyUI + custom nodes first (see node README, ComfyUI service section)." >&2
            exit 1; }
    done
    [[ -f "$DOCKERFILE" ]] || { echo "ERROR: missing $DOCKERFILE" >&2; exit 1; }
}

stage_context() {
    CTX="$REPO_ROOT/tmp/comfyui/build-context"
    rm -rf "$CTX"
    mkdir -p "$CTX/custom_nodes/ComfyUI-KJNodes" "$CTX/custom_nodes/Comfyui-Memory_Cleanup"
    cp "$COMFYUI_HOME/requirements.txt" "$CTX/"
    cp "$COMFYUI_HOME/custom_nodes/ComfyUI-KJNodes/requirements.txt" "$CTX/custom_nodes/ComfyUI-KJNodes/"
    cp "$COMFYUI_HOME/custom_nodes/Comfyui-Memory_Cleanup/requirements.txt" "$CTX/custom_nodes/Comfyui-Memory_Cleanup/"
}

case "$ACTION" in
check)
    echo "ComfyUI checkout : $COMFYUI_HOME"
    git -C "$COMFYUI_HOME" log -1 --format='  commit    : %H (%d, %cs)' 2>/dev/null || true
    for d in "$COMFYUI_HOME"/custom_nodes/*/; do
        [[ -d "$d/.git" ]] && echo "  node pack : $(basename "$d") @ $(git -C "$d" log -1 --format='%h %cs')"
    done
    echo "Base image       : $BASE_IMAGE"
    if docker image inspect "$BASE_IMAGE" &>/dev/null; then
        docker run --rm "$BASE_IMAGE" python3 -c \
            'import sys,torch,torchvision; print(f"  base      : py {sys.version.split()[0]}, torch {torch.__version__}, torchvision {torchvision.__version__}")'
    else
        echo "  (base image not pulled yet)"
    fi
    echo "Service image    : $IMAGE_TAG"
    if docker image inspect "$IMAGE_TAG" &>/dev/null; then
        docker image inspect "$IMAGE_TAG" --format '  built     : {{.Created}}'
        # av with VideoFrame.rotation is a hard requirement (spec §3.6).
        docker run --rm "$IMAGE_TAG" python3 -c \
            'import av; assert hasattr(av.VideoFrame, "rotation"); print("  av       :", av.__version__, "(VideoFrame.rotation OK)")'
    else
        echo "  (not built)"
    fi
    ;;

build)
    preflight
    stage_context
    log "Building $IMAGE_TAG from $BASE_IMAGE (staged context: $CTX)"
    docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" "$CTX"
    log "Built $IMAGE_TAG"
    log "Verify with: bash $0 check"
    ;;

*)
    echo "ERROR: unknown action '$ACTION' (expected check|build)" >&2
    exit 1
    ;;
esac