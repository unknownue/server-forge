FROM unsloth/unsloth:latest

# Pre-build the Unsloth Studio frontend so the entrypoint skips the
# first-run build step (bun install is buggy and hangs; we use npm).
# This is done at image build time on the target architecture — the
# upstream image defers it because of QEMU cross-build incompatibilities.

# Base image defaults to USER unsloth (UID 1001); switch to root for build steps.
USER root

# ── Upgrade transformers for qwen3_5 model support ──
# The base image ships transformers 4.57.1 which does not recognize the
# `qwen3_5` model type. 5.5.0 is the latest version compatible with both
# unsloth-zoo (<=5.5.0) and the NVFP4 model (>=5.5.0).
RUN pip install --no-cache-dir transformers==5.5.0 \
    && pip install --no-cache-dir compressed-tensors==0.15.0.1

# ── Pre-install flash-attn for Pre-Blackwell GPUs (RTX 4090 etc.) ──
# The base image entrypoint downloads this on first start per GPU generation.
# Installing at build time means the entrypoint skips it, avoiding a slow
# GitHub download on every fresh container start.
RUN uv pip install --python /opt/venv/bin/python3 --no-deps \
    https://github.com/rolandtannous/docker-wheels/releases/download/cu12cp312/flash_attn-2.8.3+cu12torch2.10cxx11abiTRUE-cp312-cp312-linux_x86_64.whl

ARG STUDIO_DIR=/opt/venv/lib/python3.12/site-packages/studio
ARG FRONTEND_DIR=$STUDIO_DIR/frontend
ARG OXC_DIR=$STUDIO_DIR/backend/core/data_recipe/oxc-validator

# ── Frontend build ──
# npm has a bug with optional dependencies (npm/cli#4828) where native
# bindings like rolldown may be missing after the first install. Removing
# node_modules + package-lock.json and re-running npm install fixes it.
WORKDIR $FRONTEND_DIR
RUN npm config set registry https://repo.huaweicloud.com/repository/npm/ \
    && npm install --no-fund --no-audit \
    && rm -rf node_modules package-lock.json \
    && npm install --no-fund --no-audit \
    && npm run build \
    && echo "Frontend build complete."

# ── oxc-validator runtime ──
WORKDIR $OXC_DIR
RUN npm config set registry https://repo.huaweicloud.com/repository/npm/ \
    && npm install --no-fund --no-audit \
    && echo "oxc-validator runtime installed."

# ── Fix ownership for runtime user ──
RUN chown -R unsloth:runtimeusers $STUDIO_DIR

# Restore the base image's default user
USER unsloth
WORKDIR /workspace
