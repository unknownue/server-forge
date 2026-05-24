#!/bin/bash
# Display disk layout, unallocated space, and detect hidden files under mounts.
# Run with: bash scripts/lib/storage-info.sh

set -eu

echo "=== Block Devices ==="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

echo ""
echo "=== LVM Physical Volumes ==="
pvs

echo ""
echo "=== LVM Volume Groups ==="
vgs

echo ""
echo "=== LVM Logical Volumes ==="
lvs

echo ""
echo "=== Filesystem Usage ==="
df -h

echo ""
echo "=== Duplicate Root Partition Usage vs Visible Files ==="
ROOT_USED_DF=$(df -BM / | awk 'NR==2{print $3}' | tr -d 'M')
ROOT_USED_DU=$(du -smx / 2>/dev/null | tail -1 | awk '{print $1}')
echo "  df reports  : ${ROOT_USED_DF}M used on /"
echo "  du -shx /   : ${ROOT_USED_DU}M visible non-cross-mount"

if [[ -n "${ROOT_USED_DF:-}" && -n "${ROOT_USED_DU:-}" ]]; then
    HIDDEN=$((ROOT_USED_DF - ROOT_USED_DU))
    if [[ $HIDDEN -gt 500 ]]; then
        echo "  Hidden       : ${HIDDEN}M (likely files shadowed under mount points)"
        echo ""
        echo "=== Check for Hidden Files Under Mount Points ==="
        for mp in $(lsblk -o MOUNTPOINT -n | sort -u | grep -v "^/$"); do
            [[ -z "$mp" || ! -d "$mp" ]] && continue
            DIR_SIZE=$(du -sm "$mp" 2>/dev/null | tail -1 | awk '{print $1}')
            if [[ "${DIR_SIZE:-0}" -gt 10 ]]; then
                echo "  $mp : ${DIR_SIZE}M (visible on its own fs)"
            fi
        done
        echo ""
        echo "  To inspect hidden files under a mount point:"
        echo "    sudo mount --bind / /mnt && du -sh /mnt/data && sudo umount /mnt"
    else
        echo "  No significant hidden files detected (<500M difference)."
    fi
fi

echo ""
echo "=== Top-Level Directory Usage (root fs only) ==="
du -shx /* 2>/dev/null | sort -rh | head -10
