# vLLM image for serving DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8.
# - Patched jasl/vllm fork at the validated pin (b158e5001).
# - 3 MTP-loader patches + pasta-paul's packed_modules_mapping patch applied inline.
# - Model weights are NOT baked in. Mount /models with the HF snapshot at runtime
#   (set MODEL_PATH or rely on the default /models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8).
#
# Build (~25-45 min depending on host):
#   docker build -t dsv4-flash-acti-mtp:0.1.0 .
#
# Run:
#   docker run --gpus all --rm -p 8000:8000 \
#     -v /path/to/hf-snapshot:/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8:ro \
#     -v dsv4-cache:/root/.cache \
#     --shm-size=16g \
#     --ulimit memlock=-1 --ulimit stack=67108864 \
#     dsv4-flash-acti-mtp:0.1.0

FROM nvidia/cuda:12.9.0-cudnn-devel-ubuntu24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_INPUT=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TORCH_CUDA_ARCH_LIST=12.0a \
    CUDA_ARCH_LIST=120a

# System deps for vLLM build + runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3.12-venv python3-pip \
        git curl ca-certificates build-essential ninja-build \
        libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3.12 -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip wheel setuptools
ENV PATH=/opt/venv/bin:$PATH

# Pin torch+cu128 first (matches the validated set used in the model card).
# torchvision is required because vllm.__init__ touches it; without a matching
# version we get "operator torchvision::nms does not exist" at import time.
RUN pip install --no-cache-dir \
        "torch==2.11.0+cu128" \
        "torchvision==0.26.0+cu128" \
        "torchaudio==2.11.0+cu128" \
        --index-url https://download.pytorch.org/whl/cu128

RUN pip install --no-cache-dir \
        "transformers==5.8.0" \
        "compressed-tensors==0.15.0.1" \
        "safetensors>=0.7" \
        "huggingface_hub>=1.14" \
        hf_transfer

# Reconstruct the validated tree.
#   - jasl/vllm @ abad5dc7 is the ds4-sm120 base
#   - kyle-ct-quant.patch is a flat diff equivalent to cherry-picking
#     neuralmagic/vllm@f910a73 ("support ct quantization"). We ship the patch
#     statically because the cherry-pick conflicts on this base, but the
#     resulting tree is byte-for-byte the same as our validated local
#     `b158e5001` head.
WORKDIR /src
RUN git init -q vllm \
    && cd vllm \
    && git config user.email "build@dsv4" \
    && git config user.name "dsv4 builder" \
    && git fetch --depth 1 https://github.com/jasl/vllm.git abad5dc712b15b7062c699a97fb64d7508ed31fd \
    && git checkout FETCH_HEAD

COPY kyle-ct-quant.patch /src/kyle-ct-quant.patch
RUN cd /src/vllm \
    && git apply /src/kyle-ct-quant.patch \
    && rm /src/kyle-ct-quant.patch

# pasta-paul's packed_modules_mapping patch on the base DeepSeekV4 class
# (needed because the kylesayrs/deepseek-ct cherry-pick references this
# attribute but doesn't define it on the class).
RUN curl -fsSL https://raw.githubusercontent.com/pasta-paul/dsv4-flash-w4a16-fp8/main/scripts/patch_v4_packed_mapping.py \
        -o /tmp/patch_v4_packed_mapping.py \
    && python /tmp/patch_v4_packed_mapping.py /src/vllm/vllm/model_executor/models/deepseek_v4.py \
    && rm /tmp/patch_v4_packed_mapping.py

# Apply Acti's three MTP-loader patches by overlaying a single sed-script.
COPY apply_mtp_patches.py /tmp/apply_mtp_patches.py
RUN python /tmp/apply_mtp_patches.py /src/vllm/vllm/model_executor/models/deepseek_v4_mtp.py \
    && rm /tmp/apply_mtp_patches.py

# Build vLLM. This is the slow step.
WORKDIR /src/vllm
ENV CC=/usr/bin/gcc CXX=/usr/bin/g++ CUDAHOSTCXX=/usr/bin/g++ \
    NVCC_PREPEND_FLAGS="-ccbin /usr/bin/g++"
RUN pip install --no-cache-dir -e .

# Sanity check.
RUN python -c "import vllm; print('vllm', vllm.__version__)" \
 && python -c "from vllm.model_executor.models.deepseek_v4 import DeepseekV4ForCausalLM; print('DSV4 import OK')" \
 && python -c "from vllm.model_executor.models.deepseek_v4_mtp import DeepSeekV4MTP; print('DSV4 MTP import OK')"


# ---- Runtime image ----
# Use the -devel base (not -runtime) so nvcc is available — Triton JIT compiles
# CUDA sources on first kernel use and crashes without it. Image is ~5 GB
# larger but that's the price of vLLM + Triton's JIT model.
FROM nvidia/cuda:12.9.0-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_INPUT=1 \
    PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    VLLM_USE_FLASHINFER_SAMPLER=0 \
    VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=0 \
    NCCL_DEBUG=WARN \
    NCCL_P2P_DISABLE=1 \
    NCCL_SHM_DISABLE=0 \
    NCCL_IB_DISABLE=1 \
    NCCL_PROTO=LL \
    NCCL_ALGO=Ring \
    NCCL_MIN_NCHANNELS=8 \
    NCCL_NTHREADS=512

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3.12-venv \
        curl ca-certificates libnuma1 \
        gcc g++ build-essential \
    && rm -rf /var/lib/apt/lists/*
# gcc/g++ + python3-dev are required at runtime: Triton's JIT compiles
# cuda_utils.c against Python.h on first kernel use. Without these the worker
# crashes at "Python.h: No such file or directory" / "Failed to find C compiler".

ENV CC=/usr/bin/gcc CXX=/usr/bin/g++

# Copy the built venv from builder.
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /src/vllm /src/vllm
ENV PATH=/opt/venv/bin:$PATH

# Default knobs (overridable via -e). The validated production config.
ENV MODEL_PATH=/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8 \
    TENSOR_PARALLEL_SIZE=2 \
    MAX_MODEL_LEN=524288 \
    MAX_NUM_SEQS=2 \
    MAX_NUM_BATCHED_TOKENS=8192 \
    GPU_MEMORY_UTILIZATION=0.93 \
    BLOCK_SIZE=256 \
    HOST=0.0.0.0 \
    PORT=8000 \
    DISABLE_CUSTOM_ALL_REDUCE=1 \
    ENABLE_MTP=1

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
