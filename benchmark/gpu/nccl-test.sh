#!/bin/bash
# NCCL all-reduce performance test.
# Requires: Docker with nvidia-container-toolkit, or local NCCL installation.

set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/utils.sh"

NCCL_IMAGE="${NCCL_IMAGE:-nvcr.io/nvidia/pytorch:24.0-py3}"
GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"

log_info "Running NCCL test on ${GPU_COUNT} GPUs..."

docker run --rm --gpus all \
    -e NCCL_DEBUG=INFO \
    "$NCCL_IMAGE" \
    python -c "
import torch
import torch.distributed as dist
import os

os.environ['MASTER_ADDR'] = 'localhost'
os.environ['MASTER_PORT'] = '29500'
os.environ['WORLD_SIZE'] = str(${GPU_COUNT})

# Quick all-reduce benchmark per rank
# (multi-process launcher needed for real multi-GPU; this is a skeleton)
print('NCCL test skeleton — use torchrun for full multi-GPU benchmark.')
print('GPU count:', torch.cuda.device_count())
"
