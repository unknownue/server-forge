#!/bin/bash
# Install apt packages for this node.
# Append new dependencies as needed. Run as:
#   sudo bash nodes/ubuntu26-node1-server/install-packages.sh

set -euo pipefail

echo "Updating package index..."
apt update

echo ""
echo "Installing packages..."

apt install -y \
    git

echo ""
echo "Done. Installed packages:"
dpkg -l git 2>/dev/null | tail -1
