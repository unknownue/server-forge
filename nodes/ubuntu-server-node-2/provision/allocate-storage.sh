#!/bin/bash
# Create the /data btrfs subvolume and /data/cache, then persist in /etc/fstab.
#
# Ubuntu's guided install on this machine produced a single btrfs root with no
# LVM and no unallocated space, so node1's "create an LV from free VG space"
# approach cannot be used. A btrfs subvolume gives the same OS/data separation.
#
# Run as: sudo bash nodes/ubuntu-server-node-2/provision/allocate-storage.sh

set -euo pipefail

MOUNT="/data"
CACHE="${MOUNT}/cache"
SUBVOL="@data"
CACHE_SUBVOL="@data/cache"
TOPLEVEL="/"

echo "=== Current filesystem state ==="
df -hT "$TOPLEVEL"

if ! command -v btrfs >/dev/null 2>&1; then
    echo "ERROR: btrfs-progs not installed. Run install-packages.sh first." >&2
    exit 1
fi

echo ""
echo "=== Creating subvolume ${SUBVOL} ==="

if btrfs subvolume list "$TOPLEVEL" 2>/dev/null | grep -qE "path ${SUBVOL}$"; then
    echo "${SUBVOL} already exists — skipping creation."
else
    btrfs subvolume create "/${SUBVOL}"
    echo "Created /${SUBVOL}."
fi

echo ""
echo "=== Resolving backing device ==="

# A subvolume is mounted by naming the containing btrfs *device* and selecting
# the subvolume with -o subvol=... — passing the subvolume path as the device
# fails with "is not a block device". Resolve the device and UUID backing /.
DEVICE="$(findmnt -no SOURCE "$TOPLEVEL")"
FS_UUID="$(findmnt -no UUID "$TOPLEVEL")"
if [[ -z "$DEVICE" || -z "$FS_UUID" ]]; then
    echo "ERROR: cannot resolve the device backing ${TOPLEVEL}." >&2
    exit 1
fi
# /dev/mapper/... and /dev/... both work for mount and for fstab by UUID.
echo "Backing device: ${DEVICE} (UUID ${FS_UUID})"

echo ""
echo "=== Mounting ${MOUNT} ==="

mkdir -p "$MOUNT"

if mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "$MOUNT already mounted."
else
    mount -o "subvol=${SUBVOL},compress=zstd,noatime" "$DEVICE" "$MOUNT"
    echo "Mounted $MOUNT."
fi

echo ""
echo "=== Adding to /etc/fstab ==="

FSTAB_LINE="UUID=${FS_UUID} ${MOUNT} btrfs subvol=${SUBVOL},compress=zstd,noatime 0 0"

if grep -qE "[[:space:]]${MOUNT}[[:space:]]" /etc/fstab 2>/dev/null; then
    echo "$MOUNT already in fstab."
else
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "Added: $FSTAB_LINE"
fi

echo ""
echo "=== Verifying ${MOUNT} is writable ==="

if ! mountpoint -q "$MOUNT"; then
    echo "ERROR: ${MOUNT} did not mount correctly — refusing to continue." >&2
    exit 1
fi
echo "${MOUNT} is mounted."

echo ""
echo "=== Creating cache subvolume ${CACHE} ==="

# Check against the subvolume's own path (inside ${MOUNT}), not the top level:
# a subvolume nested under /data is listed relative to /data, not as @data/cache.
if btrfs subvolume list "$MOUNT" 2>/dev/null | grep -qE "path ${CACHE_SUBVOL}$"; then
    echo "${CACHE_SUBVOL} already exists — skipping creation."
else
    btrfs subvolume create "$CACHE"
    echo "Created $CACHE."
fi

echo ""
echo "=== Creating workspace directories ==="

mkdir -p "${MOUNT}/work/models" "${MOUNT}/work/checkpoints" "${MOUNT}/docker" "${MOUNT}/containerd"

if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER:$SUDO_USER" "${MOUNT}/work"
    # Docker/containerd roots stay root-owned; containers write as mapped users.
    echo "${MOUNT}/work owned by $SUDO_USER."
    echo "${MOUNT}/docker and ${MOUNT}/containerd left root-owned (expected)."
else
    chmod 777 "${MOUNT}/work"
    echo "${MOUNT}/work created (fallback: world-writable)."
fi

echo ""
echo "=== Filesystem usage ==="
btrfs filesystem usage "$TOPLEVEL" 2>/dev/null | head -8 || df -hT "$TOPLEVEL"

echo ""
echo "Done."
echo "  Docker data-root : ${MOUNT}/docker      (root only)"
echo "  User workspace   : ${MOUNT}/work        (models, checkpoints, datasets)"
echo "  Disposable cache : ${MOUNT}/cache       (Triton, TorchInductor, HF, ROCm)"
echo ""
echo "Next: sudo bash nodes/ubuntu-server-node-2/provision/install-docker.sh [registry-mirror]"
echo ""
echo "NOTE: the /data subvolume shares the btrfs pool with /, so there is no fixed"
echo "      size or reserved headroom. Monitor with: btrfs filesystem usage /"