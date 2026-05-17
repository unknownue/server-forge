#!/bin/bash
# Allocate unallocated LVM space for reproducible data.
# Run as: sudo bash nodes/ubuntu26-node1-server/allocate-storage.sh

set -euo pipefail

VG="ubuntu-vg"
LV="data-lv"
SIZE="1400G"
MOUNT="/data"

echo "=== Current LVM state ==="
vgs "$VG"
lvs "$VG"

echo ""
echo "=== Creating logical volume ==="

if lvs "$VG/$LV" &>/dev/null; then
    echo "$LV already exists — skipping creation."
else
    lvcreate -n "$LV" -L "$SIZE" "$VG"
    mkfs.ext4 "/dev/$VG/$LV"
    echo "Created $LV (${SIZE})."
fi

echo ""
echo "=== Post-allocation LVM state ==="
vgs "$VG"
lvs "$VG"

echo ""
echo "=== Mounting ==="

if mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "$MOUNT already mounted."
else
    mkdir -p "$MOUNT"
    mount "/dev/$VG/$LV" "$MOUNT"
    echo "Mounted $MOUNT."
fi

echo ""
echo "=== Adding to /etc/fstab ==="
FSTAB_ENTRY="/dev/$VG/$LV $MOUNT ext4 defaults 0 2"

if grep -q "$LV" /etc/fstab 2>/dev/null; then
    echo "$LV already in fstab."
else
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "Added $LV to fstab."
fi

echo ""
echo "=== Creating user workspace ==="
WORK_DIR="$MOUNT/work"

mkdir -p "$WORK_DIR"
if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER:$SUDO_USER" "$WORK_DIR"
    echo "$WORK_DIR owned by $SUDO_USER."
else
    chmod 777 "$WORK_DIR"
    echo "$WORK_DIR created (fallback: world-writable)."
fi

echo ""
echo "=== Remaining free space ==="
vgs "$VG" --units g

echo ""
echo "Done."
echo "  Docker data-root : $MOUNT/docker   (root only)"
echo "  User workspace   : $WORK_DIR       (regular user: benchmarks, models, datasets)"
