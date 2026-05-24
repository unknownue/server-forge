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

ARG STUDIO_DIR=/opt/venv/lib/python3.12/site-packages/studio
ARG FRONTEND_DIR=$STUDIO_DIR/frontend
ARG OXC_DIR=$STUDIO_DIR/backend/core/data_recipe/oxc-validator

# ── Frontend dependencies (npm install BEFORE patching so this layer caches) ──
# npm install only depends on package.json / package-lock.json, not on source
# files. Running it before COPY+patch means rebuilds skip re-downloading deps.
WORKDIR $FRONTEND_DIR
RUN npm config set registry https://repo.huaweicloud.com/repository/npm/ \
    && npm install --no-fund --no-audit

# ── Patch frontend source ──
# Auto-fill and auto-submit the login form when bootstrap credentials are
# injected by the backend (see patch-backend.py). This must run before build.
COPY patch-frontend.py /tmp/patch-frontend.py
RUN /opt/venv/bin/python3 /tmp/patch-frontend.py \
    && rm /tmp/patch-frontend.py

# ── Frontend build ──
RUN npm run build \
    && echo "Frontend build complete."

# ── oxc-validator runtime ──
WORKDIR $OXC_DIR
RUN npm config set registry https://repo.huaweicloud.com/repository/npm/ \
    && npm install --no-fund --no-audit \
    && echo "oxc-validator runtime installed."

# ── Fix ownership for runtime user ──
RUN chown -R unsloth:runtimeusers $STUDIO_DIR

# ── Patch backend: auto-skip BitsAndBytesConfig for pre-quantized models ──
# inference.py hardcodes load_in_4bit=True, which creates a BitsAndBytesConfig
# that conflicts with models that already have a native quantization_config
# (FP8, CompressedTensors / NVFP4, MXFP4, etc.). Detect the model's config.json
# and disable 4-bit loading when a native quantization scheme is present.
#
# main.py's _inject_bootstrap is also patched to always inject the bootstrap
# password (not just when password change is pending), so the frontend can
# auto-login.
#
# storage.py's must_change_password is set to False so we're not forced
# through the change-password flow on first login.
COPY patch-backend.py /tmp/patch-backend.py
RUN /opt/venv/bin/python3 /tmp/patch-backend.py \
    && rm /tmp/patch-backend.py

# Restore the base image's default user
USER unsloth
WORKDIR /workspace
