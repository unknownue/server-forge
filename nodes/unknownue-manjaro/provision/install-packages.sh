#!/bin/bash
# Install packages for unknownue-manjaro.
# Append new dependencies as needed. Run as:
#   bash nodes/unknownue-manjaro/provision/install-packages.sh
#
# yay handles privilege escalation internally — do not run with sudo.

set -euo pipefail

echo "Installing packages..."

yay -S --needed --noconfirm \
    git \
    python-huggingface-hub

echo ""
echo "Done."
