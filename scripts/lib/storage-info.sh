#!/bin/bash
# Display disk layout and unallocated space.
# Run with: sudo bash scripts/lib/storage-info.sh

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
