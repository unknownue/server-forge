#!/bin/bash
# Initialize git submodules with minimal footprint.
# Run once after git clone: bash scripts/setup-submodules.sh
#
# For the large inference_results_v5.1 repo, this script uses sparse+shallow
# clone to pull only needed directories.
#
# Reproducibility: re-running this script is safe — it skips already-initialized
# submodules and only updates them.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== Setting up submodules ==="

# ── Regular submodules: standard init ──
echo "[1/2] Initializing regular submodules..."
git submodule update --init -- submodules/LinuxMirrors

# ── Large submodules: sparse+shallow clone ──
echo "[2/2] Setting up inference_results_v5.1 (sparse checkout)..."
INFERENCE_DIR="submodules/inference_results_v5.1"
INFERENCE_URL="https://github.com/mlcommons/inference_results_v5.1.git"
SPARSE_PATHS="closed/NVIDIA/code closed/NVIDIA/configs closed/NVIDIA/data_maps closed/NVIDIA/scripts"

if [[ -f "$INFERENCE_DIR/.git" ]]; then
    echo "  Already initialized, updating..."
    git -C "$INFERENCE_DIR" fetch --depth=1 origin main
    git -C "$INFERENCE_DIR" checkout FETCH_HEAD
    git -C "$INFERENCE_DIR" sparse-checkout set $SPARSE_PATHS
else
    echo "  Cloning (sparse + shallow)..."
    rm -rf "$INFERENCE_DIR"

    git clone \
        --depth=1 \
        --filter=blob:none \
        --sparse \
        "$INFERENCE_URL" \
        "$INFERENCE_DIR"

    git -C "$INFERENCE_DIR" sparse-checkout set $SPARSE_PATHS

    # Register as a proper git submodule so 'git submodule status' tracks it.
    echo "  Registering submodule metadata..."
    GITLINK_SHA="$(git -C "$INFERENCE_DIR" rev-parse HEAD)"

    if ! git ls-files --error-unmatch "$INFERENCE_DIR" &>/dev/null; then
        git update-index --add --cacheinfo 160000,"$GITLINK_SHA","$INFERENCE_DIR"
    else
        git update-index --cacheinfo 160000,"$GITLINK_SHA","$INFERENCE_DIR"
    fi

    git submodule absorbgitdirs -- "$INFERENCE_DIR" 2>/dev/null || true
fi

echo ""
echo "=== Submodules ready ==="
git submodule status
