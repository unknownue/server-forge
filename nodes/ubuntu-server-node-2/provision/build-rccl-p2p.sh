#!/bin/bash
# Build the RCCL patch that makes NCCL_P2P_LEVEL=PHB survive on Intel platforms,
# and produce a derived Docker image that actually uses it.
#
# WHY: stock RCCL classifies a cross-root-port GPU pair on X99 as PATH_PHB(8),
# but a hardcoded Intel branch in ncclTopoCheckP2p() clamps p2pLevel to
# PATH_PXB(5), so "8 <= 5" is false and P2P is refused -- RCCL falls back to SHM
# over host memory even though the kernel supports peer access. Measured here:
#   stock RCCL            : 5.66 GB/s   (SHM)
#   patched RCCL + PHB    : 9.61 GB/s   (direct P2P)
# Both the patch AND NCCL_P2P_LEVEL=PHB are required.
#
# SOURCE: RCCL lives in the ROCm/rocm-systems super-repo at projects/rccl.
# The older standalone ROCm/rccl develop branch cannot produce a loadable
# library for this ROCm 7.14 stack (see bench/results/rccl-fallback-evidence.txt).
#
# Usage:
#   bash nodes/ubuntu-server-node-2/provision/build-rccl-p2p.sh [prepare|build|image]
#
#   prepare — clone source, apply patch            (no root, needs network)
#   build   — compile RCCL for gfx1100             (no root, ~30 min)
#   image   — derive a runnable image with it      (uses docker build)

set -euo pipefail

ACTION="${1:-prepare}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NODE_DIR="$REPO_ROOT/nodes/ubuntu-server-node-2"
PATCH_FILE="$NODE_DIR/provision/patches/rccl-intel-p2p-level-override.patch"

WORK_DIR="$REPO_ROOT/tmp/rccl-build"
SRC_DIR="$WORK_DIR/rocm-systems/projects/rccl"
VENDOR_DIR="$WORK_DIR/vendor"
OUT_DIR="$WORK_DIR/out"
IMAGE_TAG="${IMAGE_TAG:-rocm-pytorch-rccl-patched:local}"
BASE_IMAGE="${BASE_IMAGE:-docker.m.daocloud.io/rocm/pytorch:latest}"
FMT_VERSION="10.2.1"

log() { echo "[$(date +%H:%M:%S)] $*"; }

case "$ACTION" in

prepare)
    mkdir -p "$WORK_DIR"

    # ── RCCL source (rocm-systems is a large super-repo; sparse-checkout it) ──
    if [[ ! -d "$WORK_DIR/rocm-systems/projects/rccl/.git" && ! -f "$SRC_DIR/CMakeLists.txt" ]]; then
        log "Cloning ROCm/rocm-systems (sparse: projects/rccl) ..."
        ( cd "$WORK_DIR" && git clone --depth 1 --filter=blob:none --sparse \
            https://github.com/ROCm/rocm-systems.git rocm-systems )
        ( cd "$WORK_DIR/rocm-systems" && git sparse-checkout set projects/rccl )
    else
        log "Source already present."
    fi

    # ── Apply the patch (idempotent) ──
    cd "$SRC_DIR"
    if grep -q 'if (userP2pLevel >= 0) p2pLevel = userP2pLevel;' src/graph/paths.cc; then
        log "Patch already applied."
    else
        log "Applying $PATCH_FILE"
        # -p3 strips the a/projects/rccl/ prefix produced by the sparse checkout.
        patch -p3 < "$PATCH_FILE"
    fi
    grep -q 'if (userP2pLevel >= 0) p2pLevel = userP2pLevel;' src/graph/paths.cc \
        || { echo "ERROR: patch did not apply." >&2; exit 1; }

    # ── Vendor fmt ──
    # RCCL's CMake does FetchContent from GitHub, which is unreachable from
    # inside the container. Fetch it on the host and point CMake at the copy.
    if [[ ! -f "$VENDOR_DIR/fmt/CMakeLists.txt" ]]; then
        log "Vendoring fmt ${FMT_VERSION} ..."
        mkdir -p "$VENDOR_DIR"
        ( cd "$VENDOR_DIR" \
          && curl -sL -o fmt.tar.gz \
             "https://codeload.github.com/fmtlib/fmt/tar.gz/refs/tags/${FMT_VERSION}" \
          && tar xzf fmt.tar.gz && mv "fmt-${FMT_VERSION}" fmt && rm -f fmt.tar.gz )
    else
        log "fmt already vendored."
    fi

    log "Prepared. Next: bash $0 build"
    ;;

build)
    [[ -f "$SRC_DIR/CMakeLists.txt" ]] || { echo "ERROR: run '$0 prepare' first." >&2; exit 1; }
    mkdir -p "$OUT_DIR"

    log "Building RCCL for gfx1100 (this takes ~30 minutes) ..."
    # Notes on this environment (all discovered the hard way):
    #  - There is no /opt/rocm; the SDK lives under the venv's _rocm_sdk_devel.
    #  - RCCL only accepts hipcc/amdclang++ as CMAKE_CXX_COMPILER.
    #  - CMake 4.4's FindThreads mis-probes the hipcc wrapper, so threads are
    #    supplied explicitly.
    #  - GPU_TARGETS must be set (not just AMDGPU_TARGETS) or RCCL builds for
    #    all 11 architectures.
    docker run --rm \
        --device=/dev/kfd --device=/dev/dri \
        --group-add "$(getent group render | cut -d: -f3)" \
        --group-add "$(getent group video | cut -d: -f3)" \
        --security-opt seccomp=unconfined \
        --user "$(id -u):$(id -g)" \
        -v /etc/passwd:/etc/passwd:ro \
        -e HOME=/tmp \
        -v "$SRC_DIR:/src/rccl" \
        -v "$OUT_DIR:/out" \
        -v "$VENDOR_DIR:/vendor" \
        "$BASE_IMAGE" \
        bash -c '
            set -e
            R=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_devel
            export ROCM_PATH="$R" HIP_PATH="$R"
            export PATH="$R/bin:$R/lib/llvm/bin:$PATH"
            export LD_LIBRARY_PATH="$R/lib:$LD_LIBRARY_PATH"
            cd /src/rccl
            rm -rf build && mkdir -p build && cd build
            cmake .. \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_C_COMPILER="$R/bin/hipcc" \
              -DCMAKE_CXX_COMPILER="$R/bin/hipcc" \
              -DCMAKE_HIP_COMPILER="$R/bin/hipcc" \
              -DROCM_PATH="$R" \
              -DAMDGPU_TARGETS=gfx1100 -DGPU_TARGETS=gfx1100 \
              -DBUILD_TESTS=OFF \
              -DCMAKE_PREFIX_PATH="$R" \
              -DCMAKE_INSTALL_PREFIX=/out \
              -DCMAKE_THREAD_LIBS_INIT="-lpthread" \
              -DFETCHCONTENT_SOURCE_DIR_FMT=/vendor/fmt
            make -j"$(nproc)"
            make install
        '

    ls -la "$OUT_DIR/lib/librccl.so.1.0"
    log "Built. Next: bash $0 image"
    ;;

image)
    [[ -f "$OUT_DIR/lib/librccl.so.1.0" ]] || { echo "ERROR: run '$0 build' first." >&2; exit 1; }

    # The freshly built library needs an explicit RUNPATH: this image keeps ROCm
    # under _rocm_sdk_* dirs rather than /opt/rocm, so without it the ROCm
    # dependencies (libamd_smi, libroctx64, libamdhip64, librocprofiler-register)
    # do not resolve. The stock library carries an equivalent RPATH.
    #
    # LD_PRELOAD of a replacement librccl deadlocks this torch build, so the
    # library is placed where torch already looks for it instead.
    cat > "$WORK_DIR/Dockerfile.rccl" <<EOF
FROM ${BASE_IMAGE}
ARG LIBDIR=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_libraries/lib
ARG RUNPATH='\$ORIGIN:\$ORIGIN/../../_rocm_sdk_core/lib:\$ORIGIN/../../_rocm_sdk_core/lib/rocm_sysdeps/lib:\$ORIGIN/../../_rocm_sdk_core/lib/host-math/lib:\$ORIGIN/../../_rocm_sdk_devel/lib'
USER root
COPY out/lib/librccl.so.1.0 \${LIBDIR}/librccl.so.1.0
RUN (command -v patchelf >/dev/null || (apt-get update -qq && apt-get install -y -qq patchelf)) && \\
    patchelf --set-rpath "\${RUNPATH}" \${LIBDIR}/librccl.so.1.0 && \\
    ln -sf librccl.so.1.0 \${LIBDIR}/librccl.so.1 && \\
    ldd \${LIBDIR}/librccl.so.1.0 | grep -c "not found" || echo "all deps resolved"
EOF

    log "Building image $IMAGE_TAG ..."
    ( cd "$WORK_DIR" && docker build -f Dockerfile.rccl -t "$IMAGE_TAG" . )

    log "Done. Run TP=2 with:"
    log "  -e NCCL_P2P_LEVEL=PHB   (required, or RCCL silently uses SHM)"
    log "  image: $IMAGE_TAG"
    ;;

*)
    echo "Usage: $0 [prepare|build|image]" >&2
    exit 1
    ;;
esac