#!/bin/bash
# Start Unsloth Studio using the pre-built custom image.
#
# Usage:
#   bash benchmark/llm/serve/serve-unsloth.sh
#
# The custom image (built from nodes/ubuntu26-node1-server/unsloth/Dockerfile)
# has the studio frontend pre-built, so the container starts instantly.
# Bun/npm caches are persisted on the host for runtime use.
#
# Auth: the admin password is seeded to "admin" (pre-created bootstrap file
# on host) so you can log in directly without looking up a random passphrase.
# Change the password via Studio UI on first login.

set -euo pipefail

IMAGE="unsloth-studio:latest"
CACHE_DIR="/data/cache/unsloth"
MODEL_DIR="/data/work/models"
STUDIO_DIR="$CACHE_DIR/studio"
BOOTSTRAP_PW_FILE="$STUDIO_DIR/auth/.bootstrap_password"

mkdir -p "$CACHE_DIR"/{bun,npm,pkg}
chmod 777 "$CACHE_DIR"/{bun,npm,pkg}

# Mount the entire /workspace/studio to persist model configs (studio.db),
# auth, cache, exports and outputs across container restarts.
mkdir -p "$STUDIO_DIR"
setfacl -R -m "u:1001:rwx" "$STUDIO_DIR" 2>/dev/null || true
setfacl -R -m "d:u:1001:rwx" "$STUDIO_DIR" 2>/dev/null || true

# Pre-seed admin password so Studio starts with a known credential.
mkdir -p "$(dirname "$BOOTSTRAP_PW_FILE")"
if [[ ! -f "$BOOTSTRAP_PW_FILE" ]]; then
    echo -n "adminadmin" > "$BOOTSTRAP_PW_FILE"
    chmod 644 "$BOOTSTRAP_PW_FILE"
    rm -f "$(dirname "$BOOTSTRAP_PW_FILE")/auth.db"
fi

# Stop and remove any existing container
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
    -e "JUPYTER_PASSWORD=mypassword" \
    -e "HF_HUB_OFFLINE=1" \
    -e "HF_HOME=/workspace/models/.cache" \
    --network=host \
    -p 8888:8888 \
    -p 8000:8000 \
    -p 2222:22 \
    -v "$(pwd):/workspace/work" \
    -v "$CACHE_DIR/bun:/home/unsloth/.bun/install/cache" \
    -v "$CACHE_DIR/npm:/home/unsloth/.npm" \
    -v "$CACHE_DIR/pkg:/home/unsloth/.cache" \
    -v "$STUDIO_DIR:/workspace/studio" \
    -v "$MODEL_DIR:/workspace/models" \
    "$IMAGE"
