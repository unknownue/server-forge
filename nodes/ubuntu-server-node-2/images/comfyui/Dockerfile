# ComfyUI service image (AMD gfx1100) for ubuntu-server-node-2.
#
# ComfyUI code and models are NOT baked in: /data/work/comfyui is bind-mounted
# at runtime by serve/comfyui.sh, so a ComfyUI/custom-node update never forces
# a pip reinstall — only this image's dependency layer changes.
#
# Build (context is staged under the repo tmp/ by the build script — it holds
# only the dependency manifests, never the ~100 GB of models):
#   bash nodes/ubuntu-server-node-2/provision/build-comfyui.sh
#
# Base: rocm/pytorch (Python 3.12, torch 2.13.0+rocm7.14.0, torchvision
# 0.28.0+rocm7.14.0 — ROCm wheels ship their own ROCm libraries, which is why
# this image works without any host ROCm install; §3.3's /opt/rocm gate is
# checked inside the container instead, recorded in the G1 report).

FROM docker.m.daocloud.io/rocm/pytorch:latest

# PyPI index. Measured 2026-10-03: files.pythonhosted.org direct = 2.1 MB/s,
# while both tuna and aliyun mirrors had collapsed to ~75 kB/s (and tuna was
# missing comfyui-workflow-templates-media-assets-02 entirely, breaking an
# earlier build). README's 2026-09-18 mirror notes predate this — re-measure
# before trusting any index, and override with --build-arg PIP_INDEX=... if
# direct PyPI ever becomes unreachable again.
ARG PIP_INDEX=https://pypi.org/simple

COPY requirements.txt /tmp/comfy-requirements.txt
COPY custom_nodes/ComfyUI-KJNodes/requirements.txt /tmp/kjnodes-requirements.txt
COPY custom_nodes/Comfyui-Memory_Cleanup/requirements.txt /tmp/memory-cleanup-requirements.txt
# Larryvrh/ComfyUI-MiniMax-H3-Turbo ships no dependencies (pyproject: []).

RUN pip install --no-cache-dir -i ${PIP_INDEX} \
        -r /tmp/comfy-requirements.txt \
        -r /tmp/kjnodes-requirements.txt \
        -r /tmp/memory-cleanup-requirements.txt

# Spec §3.6: ComfyUI's video loaders need av with VideoFrame.rotation
# (av >= 13; upstream verified 17.x in this dependency set). Verify, don't guess.
RUN python3 -c "import av; assert hasattr(av.VideoFrame, 'rotation'), 'av too old for video loaders'; print('av OK:', av.__version__)"

# Import-level smoke test: torch must see the ROCm stack at build time is NOT
# checked here (no GPU during build); the gate runs in serve/comfyui.sh docs.
RUN python3 -c "import torch, torchvision, transformers, safetensors, einops, PIL; print('torch', torch.__version__)"

WORKDIR /ComfyUI