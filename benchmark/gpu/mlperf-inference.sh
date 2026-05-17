#!/bin/bash
# MLPerf Inference benchmark — run after downloading assets.
# Prerequisite: bash benchmark/gpu/download-mlperf-assets.sh [BENCHMARK]
#
# Usage:
#   bash benchmark/gpu/mlperf-inference.sh [BENCHMARK] [SCENARIO] [GPUS] [--rebuild]
#
# Defaults: bert, Offline, GPU 0
# Examples:
#   bash benchmark/gpu/mlperf-inference.sh
#   bash benchmark/gpu/mlperf-inference.sh bert Offline 0,1,2,3
#   bash benchmark/gpu/mlperf-inference.sh bert Offline 0 --rebuild

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BENCHMARK="${1:-bert}"
SCENARIO="${2:-Offline}"
GPUS="${3:-0}"
REBUILD=false
[[ "${4:-}" == "--rebuild" ]] && REBUILD=true

IMAGE="nvcr.io/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64"

INFERENCE_DIR="$REPO_ROOT/submodules/inference_results_v5.1"
DATA_DIR="/data/work/mlperf"
MODELS_DIR="$DATA_DIR/models"
DATASETS_DIR="$DATA_DIR/datasets"
PREPROCESSED_DIR="$DATA_DIR/preprocessed_data"
WORK_DIR="$INFERENCE_DIR/closed/NVIDIA"
BUILD_DIR="$WORK_DIR/build"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$DATA_DIR/runs/${BENCHMARK}_${SCENARIO}_${TIMESTAMP}"
RESULT_DIR="$REPO_ROOT/benchmark/results"
mkdir -p "$RESULT_DIR" "$RUN_DIR"

DOCKER_FLAGS="--rm --gpus device=$GPUS --ipc=host --ulimit memlock=-1"
MOUNTS="-v $REPO_ROOT:$REPO_ROOT -v $MODELS_DIR:$BUILD_DIR/models:cached -v $DATASETS_DIR:$BUILD_DIR/data:cached -v $PREPROCESSED_DIR:$BUILD_DIR/preprocessed_data:cached"

SETUP_CMDS="ln -sf /usr/bin/python3 /usr/bin/python3.8 && pip install pycuda --quiet 2>/dev/null || true"

# ── Pre-flight checks ──
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible. Join the docker group first:" >&2
    echo "  sudo usermod -aG docker \$USER && newgrp docker" >&2
    exit 1
fi

echo "============================================"
echo "  MLPerf Inference Benchmark"
echo "  Benchmark : $BENCHMARK"
echo "  Scenario  : $SCENARIO"
echo "  GPUs      : $GPUS"
echo "============================================"
echo ""

# ── Step 1: Build harness (once) ──
HARNESS_BIN="$BUILD_DIR/bin/harness_default"
if [[ "$REBUILD" != true ]] && docker run $DOCKER_FLAGS $MOUNTS "$IMAGE" bash -c "test -f $HARNESS_BIN" 2>/dev/null; then
    echo "[1/3] Harness already built — skipping."
else
    echo "[1/3] Building harness..."
    docker run $DOCKER_FLAGS $MOUNTS "$IMAGE" \
        bash -c "$SETUP_CMDS; cd $WORK_DIR && make build_plugins build_loadgen build_harness 2>&1 | tail -20"
fi
echo ""

# ── Step 2: Generate TensorRT engines (once) ──
# engines are cached under build/engines/<system_id>/<benchmark>/<scenario>/
ENGINE_DIR="$BUILD_DIR/engines"
if [[ "$REBUILD" != true ]]; then
    ENGINE_COUNT=$(docker run $DOCKER_FLAGS $MOUNTS "$IMAGE" \
        bash -c "find $ENGINE_DIR -path '*/$BENCHMARK/$SCENARIO/*.plan' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
else
    ENGINE_COUNT=0
fi
if [[ "$ENGINE_COUNT" -gt 0 ]]; then
    echo "[2/3] Engines already generated ($ENGINE_COUNT plan files) — skipping."
    echo "       Use --rebuild to regenerate."
else
    echo "[2/3] Generating TensorRT engines..."
    docker run $DOCKER_FLAGS $MOUNTS "$IMAGE" \
        bash -c "$SETUP_CMDS; cd $WORK_DIR && make generate_engines RUN_ARGS=\"--benchmarks=$BENCHMARK --scenarios=$SCENARIO\" 2>&1 | tail -5"
fi
echo ""

# ── Step 3: Run benchmark ──
echo "[3/3] Running benchmark..."
docker run $DOCKER_FLAGS $MOUNTS "$IMAGE" \
    bash -c "$SETUP_CMDS; cd $WORK_DIR && make run RUN_ARGS=\"--benchmarks=$BENCHMARK --scenarios=$SCENARIO --test_mode=PerformanceOnly\" 2>&1" \
    | tee "$RUN_DIR/benchmark.log"

cp "$RUN_DIR/benchmark.log" "$RESULT_DIR/${BENCHMARK}_${SCENARIO}_${TIMESTAMP}.log" 2>/dev/null || true

echo ""
echo "============================================"
echo "  Done."
echo "  Log: $RUN_DIR/benchmark.log"
echo "============================================"
