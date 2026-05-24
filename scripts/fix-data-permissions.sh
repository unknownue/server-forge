#!/bin/bash
# Fix /data permissions: chown + ACL to keep files accessible regardless
# of whether the Docker container runs as root or a non-root user.
#
# Usage:
#   sudo bash scripts/fix-data-permissions.sh
#
# Safe to run repeatedly. Docker/containerd internals are left untouched.

set -euo pipefail

if [[ "${EUID:-}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

DATA_DIR="/data"
HOST_USER="${SUDO_USER:-unknownue}"
HOST_UID=$(id -u "$HOST_USER")

# Container UIDs that need write access to /data (e.g. unsloth=1001)
CONTAINER_UIDS=(1001)

echo "=== Fixing /data permissions ==="
echo "  Host user      : $HOST_USER (UID $HOST_UID)"
echo "  Container UIDs : ${CONTAINER_UIDS[*]}"
echo ""

# ---- Directories containers write to ----
USER_DIRS=(
    "$DATA_DIR/cache"
    "$DATA_DIR/work"
)

for dir in "${USER_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        echo "[OK] $dir (created)"
    fi

    # Ownership to host user
    chown -R "$HOST_UID:$HOST_UID" "$dir"

    # ACL: grant host user rwx on existing + future files
    setfacl -R  -m "u:$HOST_USER:rwx" "$dir" 2>/dev/null || true
    setfacl -R  -m "d:u:$HOST_USER:rwx" "$dir" 2>/dev/null || true

    # ACL: grant container UIDs rwx too (for images that can't use --user)
    for cuid in "${CONTAINER_UIDS[@]}"; do
        setfacl -R  -m "u:$cuid:rwx" "$dir" 2>/dev/null || true
        setfacl -R  -m "d:u:$cuid:rwx" "$dir" 2>/dev/null || true
    done

    echo "[OK] $dir  (owner + ACL set)"
done

echo ""
echo "=== Summary ==="
echo "Managed     : ${USER_DIRS[*]}"
echo "Untouched   : $DATA_DIR/docker $DATA_DIR/containerd $DATA_DIR/lost+found"
echo ""
echo "Containers that use --user write as $HOST_USER directly."
echo "Containers that run as root or other UIDs — ACL grants access to $HOST_USER."
