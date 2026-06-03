#!/bin/bash
# Start Unsloth Studio service using the pre-built custom image.
#
# Usage:
#   bash nodes/unknownue-manjaro/unsloth/start.sh
#
# Prerequisites:
#   - Build the image first: bash nodes/unknownue-manjaro/unsloth/build.sh
#   - Auth: username=unsloth, password=adminadmin (change via Studio UI on first login)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="unsloth-studio:latest"
HOST_USER="${SUDO_USER:-$USER}"
HOST_UID="$(id -u "$HOST_USER")"
HOST_GID="$(id -g "$HOST_USER")"

CACHE_DIR="/data/cache/unsloth"
MODEL_DIR="/data/work/models"
STUDIO_DIR="$CACHE_DIR/studio"
BOOTSTRAP_PW_FILE="$STUDIO_DIR/auth/.bootstrap_password"

# ── Ensure image exists ──
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "ERROR: Image '$IMAGE' not found. Build it first:"
    echo "  bash $SCRIPT_DIR/build.sh"
    exit 1
fi

# ── Host directories ──
sudo mkdir -p "$CACHE_DIR"/{bun,npm,pkg}
sudo chmod 777 "$CACHE_DIR"/{bun,npm,pkg}

sudo mkdir -p "$STUDIO_DIR"
sudo setfacl -R -m "u:$HOST_USER:rwx" "$STUDIO_DIR" 2>/dev/null || true
sudo setfacl -R -m "d:u:$HOST_USER:rwx" "$STUDIO_DIR" 2>/dev/null || true

# ── Pre-seed admin password ──
sudo mkdir -p "$(dirname "$BOOTSTRAP_PW_FILE")"
if [[ ! -f "$BOOTSTRAP_PW_FILE" ]]; then
    echo -n "adminadmin" | sudo tee "$BOOTSTRAP_PW_FILE" > /dev/null
    sudo chmod 644 "$BOOTSTRAP_PW_FILE"
    sudo rm -f "$(dirname "$BOOTSTRAP_PW_FILE")/auth.db"
fi

# ── Stop existing container ──
docker rm -f unsloth 2>/dev/null || true

echo "=== Starting Unsloth Studio ==="
echo "  Image  : $IMAGE"
echo "  Cache  : $CACHE_DIR"
echo "  Models : $MODEL_DIR"
echo "  Auth   : username=unsloth, password=adminadmin"
echo ""

docker run -d \
    --name unsloth \
    --gpus all \
    -e "HF_HUB_OFFLINE=1" \
    -e "HF_HOME=/workspace/models/.cache" \
    --network=host \
    -v "$CACHE_DIR/bun:/home/unsloth/.bun/install/cache" \
    -v "$CACHE_DIR/npm:/home/unsloth/.npm" \
    -v "$CACHE_DIR/pkg:/home/unsloth/.cache" \
    -v "$STUDIO_DIR:/workspace/studio" \
    -v "$MODEL_DIR:/workspace/models" \
    "$IMAGE"

echo ""
echo "=== Unsloth Studio started ==="
echo "  URL: http://localhost:8888"
echo "  Logs: docker logs -f unsloth"
