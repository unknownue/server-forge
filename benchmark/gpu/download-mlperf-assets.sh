#!/bin/bash
# Download MLPerf Inference assets (models + datasets) for a given benchmark.
# Run once before benchmarking; assets persist under /data/work/mlperf/.
#
# Usage:
#   bash benchmark/gpu/download-mlperf-assets.sh [BENCHMARK]
#
# Available benchmarks:
#   3d-unet   bert   dlrm   resnet50   retinanet   rnnt   ssd-mobilenet   ssd-resnet34

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BENCHMARK="${1:-bert}"
IMAGE="nvcr.io/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64"
IMAGE_MIRROR="nvcr.1ms.run/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64"

INFERENCE_DIR="$REPO_ROOT/submodules/inference_results_v5.1"
DATA_DIR="/data/work/mlperf"
MODELS_DIR="$DATA_DIR/models"
DATASETS_DIR="$DATA_DIR/datasets"
PREPROCESSED_DIR="$DATA_DIR/preprocessed_data"
WORK_DIR="$INFERENCE_DIR/closed/NVIDIA"

DOCKER_FLAGS="--rm --gpus all --ipc=host --ulimit memlock=-1"

echo "============================================"
echo "  Download MLPerf Assets"
echo "  Benchmark: $BENCHMARK"
echo "  Models      -> $MODELS_DIR"
echo "  Datasets    -> $DATASETS_DIR"
echo "  Preprocessed -> $PREPROCESSED_DIR"
echo "============================================"
echo ""

BUILD_DIR="$INFERENCE_DIR/closed/NVIDIA/build"
INFERENCE_REPO_DIR="$BUILD_DIR/inference"
POWER_DEV_DIR="$BUILD_DIR/power-dev"

mkdir -p "$MODELS_DIR" "$DATASETS_DIR" "$PREPROCESSED_DIR"

# ── Pre-clone LoadGen dependencies on HOST ──
# These repos must be cloned outside the container because GitHub is blocked
# inside Docker's network. The Makefile targets skip clone if the dir exists.
echo "[1/4] Pre-cloning LoadGen dependencies..."
mkdir -p "$BUILD_DIR"

if [[ ! -d "$INFERENCE_REPO_DIR" ]]; then
    echo "  Cloning mlcommons/inference..."
    git clone https://github.com/mlcommons/inference.git "$INFERENCE_REPO_DIR"
    git -C "$INFERENCE_REPO_DIR" submodule update --init third_party/pybind
    git -C "$INFERENCE_REPO_DIR" submodule update --init language/bert/DeepLearningExamples
else
    echo "  mlcommons/inference already present."
fi

if [[ ! -d "$POWER_DEV_DIR" ]]; then
    echo "  Cloning mlcommons/power-dev..."
    git clone https://github.com/mlcommons/power-dev.git "$POWER_DEV_DIR"
else
    echo "  power-dev already present."
fi
echo ""

CONTAINER_SETUP="ln -sf /usr/bin/python3 /usr/bin/python3.8 && pip install pycuda --quiet 2>/dev/null || true"

# ── Pull image ──
echo "[2/4] Checking Docker image..."
IMAGE_PRESENT="$(docker images -q "$IMAGE" 2>/dev/null || true)"
if [[ -n "$IMAGE_PRESENT" ]]; then
    echo "  Image already present."
elif ! docker pull "$IMAGE" 2>/dev/null; then
    echo "  Pulling via mirror..."
    docker pull "$IMAGE_MIRROR"
    docker tag "$IMAGE_MIRROR" "$IMAGE"
    docker rmi "$IMAGE_MIRROR"
else
    echo "  Image pulled."
fi
echo ""

# ── Download models + datasets ──
echo "[3/4] Downloading models and datasets for $BENCHMARK..."
docker run $DOCKER_FLAGS \
    -v "$REPO_ROOT:$REPO_ROOT" \
    -v "$MODELS_DIR:$INFERENCE_DIR/build/models" \
    -v "$DATASETS_DIR:$INFERENCE_DIR/build/data" \
    -v "$PREPROCESSED_DIR:$INFERENCE_DIR/build/preprocessed_data" \
    "$IMAGE" \
    bash -c "
        $CONTAINER_SETUP
        cd $WORK_DIR
        echo 'generate_engines (downloads model + data)...'
        make generate_engines RUN_ARGS=\"--benchmarks=$BENCHMARK --scenarios=Offline\" 2>&1 || true
    "
echo ""

# ── Verify ──
echo "[4/4] Verifying assets..."
docker run $DOCKER_FLAGS \
    -v "$MODELS_DIR:$INFERENCE_DIR/build/models" \
    -v "$DATASETS_DIR:$INFERENCE_DIR/build/data" \
    -v "$PREPROCESSED_DIR:$INFERENCE_DIR/build/preprocessed_data" \
    "$IMAGE" \
    bash -c "
        echo '  Models:'; du -sh $INFERENCE_DIR/build/models/*/ 2>/dev/null || echo '  (none)'
        echo '  Datasets:'; du -sh $INFERENCE_DIR/build/data/*/ 2>/dev/null || echo '  (none)'
    "

echo ""
echo "Done. Assets ready. Run the benchmark:"
echo "  bash benchmark/gpu/mlperf-inference.sh $BENCHMARK"
