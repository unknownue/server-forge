#!/bin/bash
# Install base packages for this node.
# Append new dependencies as needed. Run as:
#   sudo bash nodes/ubuntu-server-node-2/provision/install-packages.sh

set -euo pipefail

echo "Updating package index..."
apt update

echo ""
echo "Installing apt packages..."

apt install -y \
    git \
    python3-huggingface-hub \
    pipx \
    btrfs-progs \
    pciutils \
    lm-sensors

pipx ensurepath  # make sure ~/.local/bin in PATH, then reboot terminal

echo ""
echo "Done."