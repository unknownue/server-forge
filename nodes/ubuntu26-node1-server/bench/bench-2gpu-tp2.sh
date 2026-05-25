#!/bin/bash
# One-click 2-GPU TP=2 benchmark for Qwen/Qwen3.6-27B.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/bench/bench-2gpu-tp2.sh [BACKEND]
#
# BACKEND: sglang (default) or vllm
#
# Steps: download model -> start server TP=2 -> smoke test -> AIPerf benchmark
# Server stops automatically on exit.
#
# Prerequisites: IOMMU must be disabled (iommu=off in kernel cmdline)
# and uvm_disable_hmm=1 (see nodes/ubuntu26-node1-server/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODEL_ID="Qwen/Qwen3.6-27B"
MODEL_ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/$MODEL_ORG/$MODEL_NAME"
GPUS="0,1"
TP_SIZE=2
PORT=8000
BACKEND="${1:-sglang}"

AIPERF_IMAGE="aiperf:latest"

echo "============================================"
echo "  2-GPU TP=2 Benchmark"
echo "  Model   : $MODEL_ID"
echo "  GPUs    : $GPUS  (TP=$TP_SIZE)"
echo "  Backend : $BACKEND"
echo "============================================"
echo ""

# ── Pre-checks ──
if ! docker info &>/dev/null; then
    echo "ERROR: Docker not accessible." >&2
    exit 1
fi

if ! docker image inspect "$AIPERF_IMAGE" &>/dev/null; then
    echo "ERROR: AIPerf image not found." >&2
    echo "Run: bash benchmark/llm/bench/build-aiperf.sh" >&2
    exit 1
fi

cleanup() {
    echo ""
    echo "[cleanup] Stopping server..."
    local cid
    cid=$(docker ps -q --filter "publish=$PORT" 2>/dev/null)
    if [[ -n "$cid" ]]; then
        docker stop "$cid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Step 1: Download model ──
echo "[1/5] Ensuring model is downloaded..."
bash "$REPO_ROOT/nodes/ubuntu26-node1-server/download-model.sh" "$MODEL_ID"
echo ""

# ── Step 2: Start server ──
echo "[2/5] Starting $BACKEND TP=2 server..."

HF_ENV=()
[[ -n "${HF_ENDPOINT:-}" ]] && HF_ENV=(-e "HF_ENDPOINT=$HF_ENDPOINT")

if [[ "$BACKEND" == "sglang" ]]; then
    SGLANG_IMAGE="voipmonitor/sglang:test-cu132"
    if ! docker image inspect "$SGLANG_IMAGE" &>/dev/null; then
        echo "ERROR: SGLang image not found: $SGLANG_IMAGE" >&2
        exit 1
    fi

    # Prepare patched config for Qwen3.6-27B (hidden_size in text_config).
    PATCH_DIR="/data/cache/sglang_patches"
    PATCHED_CONFIG="$PATCH_DIR/qwen3_5.py"
    PATCH_FILE="$SCRIPT_DIR/fix-qwen3_5-config.patch"

    if [[ ! -f "$PATCHED_CONFIG" ]]; then
        echo "  Preparing config patch for Qwen3.6-27B..."
        mkdir -p "$PATCH_DIR"
        # Extract original config from image
        docker run --rm --entrypoint "" "$SGLANG_IMAGE" \
            cat /opt/sglang/python/sglang/srt/configs/qwen3_5.py > "$PATCHED_CONFIG.orig"
        # Apply patch
        patch -o "$PATCHED_CONFIG" "$PATCHED_CONFIG.orig" "$PATCH_FILE"
        echo "  Patched config written to $PATCHED_CONFIG"
    fi

    # Prepare patched HF config (AutoConfig resolves to transformers, not sglang).
    PATCHED_CONFIG_HF="$PATCH_DIR/qwen3_5_hf.py"
    PATCH_FILE_HF="$SCRIPT_DIR/fix-qwen3_5-config-hf.patch"
    if [[ ! -f "$PATCHED_CONFIG_HF" ]]; then
        echo "  Preparing HF config patch for Qwen3.6-27B..."
        mkdir -p "$PATCH_DIR"
        docker run --rm --entrypoint "" "$SGLANG_IMAGE" \
            cat /opt/venv/lib/python3.12/site-packages/transformers/models/qwen3_5/configuration_qwen3_5.py \
            > "$PATCHED_CONFIG_HF.orig"
        patch -o "$PATCHED_CONFIG_HF" "$PATCHED_CONFIG_HF.orig" "$PATCH_FILE_HF"
        echo "  Patched HF config written to $PATCHED_CONFIG_HF"
    fi

    CACHE_DIR="/data/cache/sglang_jit"
    mkdir -p "$CACHE_DIR"

    docker run --rm -d \
        --name "bench-tp2" \
        --gpus all \
        -e "CUDA_VISIBLE_DEVICES=$GPUS" \
        -e "SGLANG_ENABLE_JIT_DEEPGEMM=0" \
        -e "NCCL_P2P_LEVEL=PHB" \
        -e "NCCL_IB_DISABLE=1" \
        -e "NCCL_MIN_NCHANNELS=8" \
        -e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=1" \
        -e "HOME=/cache" \
        --user "$(id -u):$(id -g)" \
        --ipc=host \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        -v "$PATCHED_CONFIG:/opt/sglang/python/sglang/srt/configs/qwen3_5.py:ro" \
        -v "$PATCHED_CONFIG_HF:/opt/venv/lib/python3.12/site-packages/transformers/models/qwen3_5/configuration_qwen3_5.py:ro" \
        "${HF_ENV[@]}" \
        -p "$PORT:8000" \
        -v "$MODEL_DIR:/models:ro" \
        -v "$CACHE_DIR:/cache:rw" \
        "$SGLANG_IMAGE" \
        sglang serve \
        --model-path "/models" \
        --served-model-name "$MODEL_NAME" \
        --tp-size "$TP_SIZE" \
        --context-length 32768 \
        --host 0.0.0.0 \
        --port 8000
elif [[ "$BACKEND" == "vllm" ]]; then
    VLLM_IMAGE="vllm/vllm-openai:latest"
    if ! docker image inspect "$VLLM_IMAGE" &>/dev/null; then
        echo "ERROR: vLLM image not found: $VLLM_IMAGE" >&2
        exit 1
    fi

    docker run --rm -d \
        --name "bench-tp2" \
        --gpus all \
        -e "CUDA_VISIBLE_DEVICES=$GPUS" \
-e "NCCL_P2P_LEVEL=PHB" \
        -e "NCCL_IB_DISABLE=1" \
        -e "NCCL_MIN_NCHANNELS=8" \
        -e "NCCL_ALLOC_P2P_NET_LL_BUFFERS=1" \
                -e "HOME=/tmp" \
        --user "$(id -u):$(id -g)" \
        --ipc=host \
        -v /etc/passwd:/etc/passwd:ro \
        -v /etc/group:/etc/group:ro \
        "${HF_ENV[@]}" \
        -p "$PORT:8000" \
        -v "$MODEL_DIR:/models:ro" \
        "$VLLM_IMAGE" \
        --model "/models" \
        --served-model-name "$MODEL_NAME" \
        --trust-remote-code \
        --tensor-parallel-size "$TP_SIZE" \
        --max-model-len 32768 \
        --host 0.0.0.0 \
        --port 8000
else
    echo "ERROR: Unknown backend '$BACKEND'. Choose sglang or vllm." >&2
    exit 1
fi

echo "  Waiting for server (this may take 3-8 minutes on first run)..."
for i in $(seq 1 240); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health")" == "200" ]]; then
        echo "  Server is ready."
        break
    fi
    sleep 2
done

if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health")" != "200" ]]; then
    echo "ERROR: Server failed to become ready within 480s." >&2
    exit 1
fi
echo ""

# ── Step 3: Smoke test ──
echo "[3/5] Smoke test..."
check() {
    local name="$1" method="$2" endpoint="$3" data="${4:-}" expected="${5:-200}"
    local code
    if [[ -n "$data" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "http://localhost:$PORT$endpoint" \
               -H "Content-Type: application/json" -d "$data" --max-time 60)
    else
        code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "http://localhost:$PORT$endpoint" --max-time 10)
    fi
    if [[ "$code" == "$expected" ]]; then
        echo "  PASS  $name"
    else
        echo "  FAIL  $name (expected $expected, got $code)"
        return 1
    fi
}

check "GET /health"    GET  "/health"
check "GET /v1/models" GET  "/v1/models"
check "POST /v1/chat/completions" POST "/v1/chat/completions" \
    "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"max_tokens\":16}"
echo ""

# ── Step 4: AIPerf benchmark ──
echo "[4/5] Running AIPerf benchmark (100 requests, concurrency=16)..."
NUM_PROMPTS=100 NUM_REQUESTS=100 AIPERF_CONCURRENCY=16 WARMUP_REQUESTS=10 OSL=4096 \
    bash "$REPO_ROOT/benchmark/llm/bench/bench-aiperf.sh" \
    "http://localhost:$PORT" "$MODEL_NAME" "$MODEL_ID"

echo ""
echo "============================================"
echo "  Benchmark complete."
echo "============================================"
