#!/bin/bash
# Install the ROCm userspace stack for the 2× Radeon RX 7900 XTX (gfx1100) cards.
# Run as: sudo bash nodes/ubuntu-server-node-2/provision/install-rocm.sh [amd-repo-host]
#
# This node has no NVIDIA hardware, so it replaces node1's NVIDIA Container
# Toolkit steps. Docker images here consume GPUs via:
#   --device=/dev/kfd --device=/dev/dri --group-add video --group-add render
#
# The stock in-tree `amdgpu` kernel module is already loaded and driving both
# cards, so this script installs USERSPACE ROCm only (no DKMS rebuild by default).
# Kernel 7.0 is newer than any released amdgpu-dkms, so building the DKMS module
# would most likely fail and is not needed.

set -euo pipefail

AMD_REPO_HOST="${1:-repo.radeon.com}"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "=== Pre-flight: GPU detection ==="
if ! lspci -nn | grep -qE '1002:744c|VGA.*AMD'; then
    echo "WARNING: no expected AMD GPU found via lspci — continuing anyway." >&2
fi
lspci -nn -d '::03xx' || true

echo ""
echo "=== Checking kernel driver ==="
if lsmod | grep -q '^amdgpu'; then
    echo "amdgpu module loaded (in-tree)."
else
    echo "ERROR: amdgpu module is not loaded — the OS is not driving these GPUs." >&2
    exit 1
fi

echo ""
echo "=== Adding AMD repository (host: ${AMD_REPO_HOST}) ==="
if [[ "$AMD_REPO_HOST" != "repo.radeon.com" ]]; then
    echo "Using mirror host: ${AMD_REPO_HOST}"
fi

# amdgpu-install is not in the Ubuntu archive; fetch the helper .deb from AMD.
# Ubuntu 26.04 (resolute) is not yet a published ROCm target — `noble` (24.04)
# packages are the compatibility fallback, matching the "no-DKMS userspace"
# scope above.
DEB_URL="https://${AMD_REPO_HOST}/amdgpu-install/6.4/ubuntu/noble/amdgpu-install_6.4.60400-1_all.deb"

echo "Downloading: $DEB_URL"
if ! curl -fSL --connect-timeout 20 -o "$WORK_DIR/amdgpu-install.deb" "$DEB_URL"; then
    echo "" >&2
    echo "ERROR: could not download amdgpu-install from ${AMD_REPO_HOST}." >&2
    echo "repo.radeon.com is not reachable from this network." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  1. Re-run with a reachable mirror, e.g.:" >&2
    echo "       sudo bash $0 <mirror-host>" >&2
    echo "  2. Download the .deb manually on another machine and install:" >&2
    echo "       sudo apt install -y ./amdgpu-install_*.deb" >&2
    echo "  3. Skip ROCm entirely and run CPU-only workloads." >&2
    exit 1
fi

apt install -y "$WORK_DIR/amdgpu-install.deb"

echo ""
echo "=== Refreshing package index ==="
apt update

echo ""
echo "=== Installing ROCm userspace (--no-dkms) ==="
# --no-dkms: keep the working in-tree amdgpu module; do not rebuild DKMS against 7.0.
amdgpu-install -y --usecase=rocm --no-dkms

echo ""
echo "=== Adding ${SUDO_USER:-$USER} to GPU access groups ==="
TARGET_USER="${SUDO_USER:-}"
if [[ -n "$TARGET_USER" ]]; then
    for grp in render video; do
        if getent group "$grp" >/dev/null; then
            usermod -aG "$grp" "$TARGET_USER"
            echo "Added $TARGET_USER to $grp."
        fi
    done
else
    echo "No SUDO_USER detected — add the user to render/video manually."
fi

echo ""
echo "=== Verification ==="
if command -v rocminfo >/dev/null 2>&1; then
    rocminfo 2>/dev/null | grep -E 'Name:|gfx' | head -20 || true
else
    echo "rocminfo not on PATH yet — re-login and re-check."
fi

echo ""
echo "Done."
echo "  Re-login (or reboot) so the render/video group membership applies."
echo "  Verify with:"
echo "    rocminfo | grep gfx      # expect gfx1100"
echo "    rocm-smi                 # expect both RX 7900 XTX cards"
echo ""
echo "  Docker smoke test:"
echo "    docker run --rm --device=/dev/kfd --device=/dev/dri \\"
echo "      --group-add video --group-add render \\"
echo "      rocm/rocm-terminal rocminfo | grep -E 'Name|gfx'"