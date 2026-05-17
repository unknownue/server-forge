#!/bin/bash
# P2P bandwidth test between GPUs using nvidia-smi topology.
# Requires: nvidia-smi.

set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/utils.sh"

log_info "GPU P2P bandwidth matrix:"
nvidia-smi topo -m

log_info ""
log_info "GPU topology detail:"
nvidia-smi topo -p2p status
