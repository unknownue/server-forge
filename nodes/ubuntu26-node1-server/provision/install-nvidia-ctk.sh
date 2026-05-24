#!/bin/bash
# Install NVIDIA Container Toolkit for Docker GPU access.
# Usage:
#   1. First:  bash download-nvidia-ctk-debs.sh   (download .deb packages)
#   2. Then:   sudo bash install-nvidia-ctk.sh     (install + configure)
#
# The script expects 4 .deb files in nvidia-ctk-debs/:
#   libnvidia-container1_<ver>_amd64.deb
#   libnvidia-container-tools_<ver>_amd64.deb
#   nvidia-container-toolkit-base_<ver>_amd64.deb
#   nvidia-container-toolkit_<ver>_amd64.deb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_DIR="$SCRIPT_DIR/nvidia-ctk-debs"

echo "=== Installing NVIDIA Container Toolkit ==="

if command -v nvidia-ctk &>/dev/null; then
    echo "nvidia-container-toolkit already installed."
else
    PACKAGES=(
        "libnvidia-container1"
        "libnvidia-container-tools"
        "nvidia-container-toolkit-base"
        "nvidia-container-toolkit"
    )

    DEBS=()
    for pkg in "${PACKAGES[@]}"; do
        matches=("$DEB_DIR/${pkg}_"*"_amd64.deb")
        if [[ ! -f "${matches[0]}" ]]; then
            echo "ERROR: ${pkg}_<ver>_amd64.deb not found in $DEB_DIR" >&2
            echo "" >&2
            echo "Run the download script first:" >&2
            echo "  bash $SCRIPT_DIR/download-nvidia-ctk-debs.sh" >&2
            exit 1
        fi
        DEBS+=("${matches[0]}")
    done

    echo "Installing .deb packages..."
    for deb in "${DEBS[@]}"; do
        echo "  $(basename "$deb")"
    done

    dpkg -i "${DEBS[0]}"   # libnvidia-container1
    dpkg -i "${DEBS[1]}"   # libnvidia-container-tools
    dpkg -i "${DEBS[2]}"   # nvidia-container-toolkit-base
    dpkg -i "${DEBS[3]}"   # nvidia-container-toolkit
fi

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

echo "Done. NVIDIA Container Toolkit configured."
