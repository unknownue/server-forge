#!/bin/bash
# Install packages for this node.
# Append new dependencies as needed. Run as:
#   sudo bash nodes/ubuntu26-node1-server/install-packages.sh

set -euo pipefail

echo "Updating package index..."
apt update

echo ""
echo "Installing apt packages..."

apt install -y \
    git \
    python3-huggingface-hub

echo ""
echo "Done."
