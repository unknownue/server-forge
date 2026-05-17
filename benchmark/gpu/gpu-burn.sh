#!/bin/bash
# GPU stress/stability test using gpu-burn.
# Requires: nvidia-smi, nvidia-persistenced (recommended).

set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/utils.sh"

DURATION="${1:-300}"  # default 5 minutes

log_info "Starting GPU burn test for ${DURATION} seconds..."

if ! command -v gpu-burn &>/dev/null; then
    die "gpu-burn not found. Install: git clone https://github.com/wilicc/gpu-burn && cd gpu-burn && make"
fi

log_info "GPU list:"
nvidia-smi --query-gpu=index,name,temperature.gpu --format=csv,noheader

gpu-burn "$DURATION"
log_info "GPU burn test completed."
