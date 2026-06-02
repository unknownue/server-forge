#!/bin/bash
# Initialize git submodules with minimal footprint.
# Run once after git clone: bash scripts/setup-submodules.sh
#
# Reproducibility: re-running this script is safe -- it skips already-initialized
# submodules and only updates them.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== Setting up submodules ==="
echo "[1/2] Initializing submodules..."
git submodule update --init -- submodules/LinuxMirrors

echo "[2/2] Initializing submodules..."
git submodule update --init -- submodules/AIServerSetup

echo ""
echo "=== Submodules ready ==="
git submodule status
