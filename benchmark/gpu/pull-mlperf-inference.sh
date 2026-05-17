#!/bin/bash
# Pull NVIDIA MLPerf Inference container image via nvcr.1ms.run mirror.
# Usage: bash pull-mlperf-inference.sh

set -euo pipefail

IMAGE_TAG="nvcr.io/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64"
IMAGE_PULL="nvcr.1ms.run/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64"

echo "Pulling $IMAGE_PULL ..."
docker pull "$IMAGE_PULL"

echo "Tagging as $IMAGE_TAG ..."
docker tag "$IMAGE_PULL" "$IMAGE_TAG"

echo "Removing mirror tag..."
docker rmi "$IMAGE_PULL"

echo ""
echo "Done."
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" "$IMAGE_TAG"
