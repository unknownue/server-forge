#!/bin/bash
# Build the SGLang gfx1100 (RDNA3) fork from StevenChenSE/sglang into a Docker image.
#
# Follows the fork's README build steps (lcz.me/topic/1532):
#   1. build the native sgl_kernel extension for gfx1100
#   2. editable Python install
#   3. build the standalone RDNA custom all-reduce extension
#
# Base image is the patched-RCCL image so TP=2 collective traffic uses the
# direct P2P path (see provision/build-rccl-p2p.sh); without both that patch and
# NCCL_P2P_LEVEL=PHB, RCCL silently falls back to SHM.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/provision/build-sglang-gfx1100.sh [clone|build|image]

set -euo pipefail

ACTION="${1:-clone}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$REPO_ROOT/tmp/sglang-fork"
FORK_URL="https://github.com/StevenChenSE/sglang.git"
FORK_BRANCH="gfx1100-support"
BASE_IMAGE="${BASE_IMAGE:-rocm-pytorch-rccl-patched:local}"
IMAGE_TAG="${IMAGE_TAG:-sglang-gfx1100-x99:local}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

case "$ACTION" in

clone)
    if [[ -d "$WORK_DIR/.git" ]]; then
        log "Source already present at $WORK_DIR"
    else
        log "Cloning $FORK_URL ($FORK_BRANCH) ..."
        git clone --depth 1 --branch "$FORK_BRANCH" "$FORK_URL" "$WORK_DIR"
    fi
    cd "$WORK_DIR"
    log "HEAD: $(git log -1 --format='%h %s')"
    # Sanity-check the paths the README's build steps depend on.
    for p in python/sglang/kernels/aot/setup_rocm.py \
             scripts/rdna_ar/rdna_ar_ext.py \
             python/pyproject.toml; do
        [[ -e "$p" ]] || { echo "ERROR: missing $p" >&2; exit 1; }
    done

    # ── Apply local build fixes (idempotent) ──
    # The fork predates ROCm 7.14's hip_fp16.h, which now also declares
    # atomicAdd(half2*, half2). compat.cuh defines its own overload under
    # USE_ROCM, so the bare calls in gptq_kernel.hip become ambiguous and the
    # build fails with "call to 'atomicAdd' is ambiguous". Route them through
    # the file's own explicit helpers instead.
    # NOTE: the .cu file is the one setup_rocm.py actually compiles (it hipifies
    # it into the build dir at build time); gptq_kernel.hip is a stale sibling
    # copy that is NOT in the source list. Patching the .hip has no effect.
    if grep -q 'atomicAdd_half2(out, result01);' \
            python/sglang/kernels/aot/csrc/gemm/gptq/gptq_kernel.cu; then
        log "atomicAdd fix already applied."
    else
        log "Applying atomicAdd ambiguity fix ..."
        patch -p1 < "$NODE_DIR/provision/patches/sglang-gptq-atomicadd-ambiguity.patch"
    fi

    # Second fix: the gptq_gemm op schema declares use_v2_format with a default,
    # so torch's Python binding exposes only 7 positional args while the engine
    # calls it with 8 -> "takes 7 positional arguments but 8 were given".
    if grep -q 'use_shuffle, int bit, bool use_v2_format) -> Tensor");' \
            python/sglang/kernels/aot/csrc/common_extension_rocm.cc; then
        log "gptq_gemm arity fix already applied."
    else
        log "Applying gptq_gemm schema arity fix ..."
        patch -p1 < "$NODE_DIR/provision/patches/sglang-gptq-gemm-schema-arity.patch"
    fi

    log "Layout OK. Next: bash $0 build"
    ;;

build)
    [[ -d "$WORK_DIR/python" ]] || { echo "ERROR: run '$0 clone' first." >&2; exit 1; }

    log "Building sgl_kernel (gfx1100) + editable install + RDNA all-reduce ..."
    docker run --rm \
        --device=/dev/kfd --device=/dev/dri \
        --group-add "$(getent group render | cut -d: -f3)" \
        --group-add "$(getent group video | cut -d: -f3)" \
        --security-opt seccomp=unconfined \
        --user "$(id -u):$(id -g)" \
        -v /etc/passwd:/etc/passwd:ro \
        -e HOME=/tmp \
        -v "$WORK_DIR:/sglang" \
        -w /sglang \
        "$BASE_IMAGE" \
        bash -c '
            set -e
            R=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_devel
            export ROCM_PATH="$R" HIP_PATH="$R"
            export PATH="$R/bin:$R/lib/llvm/bin:$PATH"
            export LD_LIBRARY_PATH="$R/lib:$LD_LIBRARY_PATH"
            export PYTORCH_ROCM_ARCH=gfx1100

            echo "--- 1/3 native sgl_kernel for gfx1100 ---"
            SITE=$(python3 -c "import site; print(site.getsitepackages()[0])")
            echo "site-packages: $SITE"
            cd /sglang/python/sglang/kernels/aot
            python3 setup_rocm.py build_ext --inplace
            # README: copy the compiled .so into site-packages/sgl_kernel/
            mkdir -p "$SITE/sgl_kernel"
            cp common_ops.*.so "$SITE/sgl_kernel/" 2>/dev/null || \
              find . -name "common_ops*.so" -exec cp {} "$SITE/sgl_kernel/" \;

            echo "--- 2/3 editable python install ---"
            cd /sglang/python
            pip install --no-build-isolation --no-deps -e .

            echo "--- 3/3 RDNA custom all-reduce ---"
            python3 /sglang/scripts/rdna_ar/rdna_ar_ext.py || \
              echo "WARN: rdna_ar prebuild failed (optional; JIT at runtime)"

            echo "--- verify ---"
            python3 -c "import sglang; print(\"sglang\", sglang.__version__)"
        '
    log "Build finished. Next: bash $0 image"
    ;;

image)
    # Snapshot the built tree into an image so runs do not depend on the host copy.
    log "Creating image $IMAGE_TAG ..."
    cat > "$WORK_DIR/Dockerfile.sglang" <<EOF
FROM ${BASE_IMAGE}
USER root
# The built Python package + compiled kernels live in the base image's venv,
# so install into it and copy the source tree for launch scripts.
COPY --chown=root:root / /opt/sglang-fork/
EOF
    # NOTE: `pip install -e` above wrote into the container's own layer, which is
    # discarded when that container exits. Re-run the install steps here so the
    # image is self-contained.
    cat > "$WORK_DIR/Dockerfile.sglang" <<EOF
FROM ${BASE_IMAGE}
USER root
COPY . /opt/sglang-fork
WORKDIR /opt/sglang-fork
RUN R=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_devel && \\
    export ROCM_PATH="\$R" HIP_PATH="\$R" PATH="\$R/bin:\$R/lib/llvm/bin:\$PATH" \\
           LD_LIBRARY_PATH="\$R/lib:\$LD_LIBRARY_PATH" PYTORCH_ROCM_ARCH=gfx1100 && \\
    SITE=\$(python3 -c "import site; print(site.getsitepackages()[0])") && \\
    cd /opt/sglang-fork/python/sglang/kernels/aot && \\
    python3 setup_rocm.py build_ext --inplace && \\
    mkdir -p "\$SITE/sgl_kernel" && \\
    find . -name "common_ops*.so" -exec cp {} "\$SITE/sgl_kernel/" \; && \\
    cd /opt/sglang-fork/python && \\
    pip install --no-build-isolation --no-deps . && \\
    python3 -c "import sglang; print('sglang', sglang.__version__)"
EOF
    ( cd "$WORK_DIR" && docker build -f Dockerfile.sglang -t "$IMAGE_TAG" . )
    log "Image ready: $IMAGE_TAG"
    ;;

*)
    echo "Usage: $0 [clone|build|image]" >&2
    exit 1
    ;;
esac