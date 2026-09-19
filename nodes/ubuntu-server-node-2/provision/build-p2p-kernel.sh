#!/bin/bash
# Build a kernel with the Broadwell-EP v4 (8086:6f00) P2PDMA whitelist entry.
#
# WHY: GPU peer-to-peer on this X99 node is rejected because the host bridge
# 8086:6f00 is absent from drivers/pci/p2pdma.c's pci_p2pdma_whitelist[].
# HIP/RCCL then fall back to host-staged copies, so TP=2 is unusably slow.
# See bench/results/p2p-verdict.txt for measurements.
#
# CONFIG_PCI=y means p2pdma.o is built into the kernel image, so this cannot be
# a module — a full kernel build is required.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/provision/build-p2p-kernel.sh [prepare|build|install]
#
#   prepare  — fetch source, apply patch, write .config   (no root)
#   build    — compile + produce .deb packages            (no root, ~20-40 min)
#   install  — dpkg -i + update-grub                      (ROOT, then reboot)
#
# Steps are separate so the expensive build and the risky install stay distinct.

set -euo pipefail

ACTION="${1:-prepare}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NODE_DIR="$REPO_ROOT/nodes/ubuntu-server-node-2"
PATCH_FILE="$NODE_DIR/provision/patches/p2pdma-broadwell-ep-v4.patch"

KVER="$(uname -r)"                                  # e.g. 7.0.0-31-generic
KBASE="${KVER%%-*}"                                 # 7.0.0-31
KDEB_VER="$(dpkg-query -W -f='${Version}' "linux-image-$KVER" 2>/dev/null || echo "")"
WORK_DIR="$REPO_ROOT/tmp/kbuild"
SRC_DIR="$WORK_DIR/linux-source-${KBASE%%-*}"
LOCALVERSION="-x99p2p"

log() { echo "[$(date +%H:%M:%S)] $*"; }

case "$ACTION" in

prepare)
    log "Kernel: $KVER (package version ${KDEB_VER:-unknown})"

    if [[ ! -f "$PATCH_FILE" ]]; then
        echo "ERROR: patch not found: $PATCH_FILE" >&2; exit 1
    fi

    mkdir -p "$WORK_DIR"

    # ── Fetch the matching source package ──
    DEB="$WORK_DIR/linux-source-${KBASE%%-*}.deb"
    SRC_PKG="linux-source-${KBASE%%-*}=${KDEB_VER}"
    if [[ ! -f "$DEB" ]]; then
        log "Downloading $SRC_PKG ..."
        ( cd "$WORK_DIR" && apt-get download "$SRC_PKG" ) \
            || { echo "ERROR: apt-get download failed; is the source version available?" >&2; exit 1; }
        # apt-get download names the file itself; normalise it.
        mv -f "$WORK_DIR"/linux-source-*.deb "$DEB" 2>/dev/null || true
    fi

    if [[ ! -d "$SRC_DIR" ]]; then
        log "Extracting source ..."
        ( cd "$WORK_DIR" && dpkg-deb -x "$DEB" extracted )
        tar xjf "$WORK_DIR/extracted/usr/src/linux-source-${KBASE%%-*}/linux-source-${KBASE%%-*}.tar.bz2" -C "$WORK_DIR"
    fi

    cd "$SRC_DIR"

    # ── Apply the whitelist patch (idempotent) ──
    if grep -q '0x6f00, REQ_SAME_HOST_BRIDGE' drivers/pci/p2pdma.c; then
        log "Patch already applied — skipping."
    else
        log "Applying $PATCH_FILE"
        patch -p1 < "$PATCH_FILE"
    fi
    grep -q '0x6f00, REQ_SAME_HOST_BRIDGE' drivers/pci/p2pdma.c \
        || { echo "ERROR: whitelist entry missing after patch." >&2; exit 1; }

    # ── Seed config from the running kernel ──
    cp "/boot/config-$KVER" .config
    # Distinct LOCALVERSION so this kernel gets its own name and GRUB entry;
    # the stock kernel stays installed and bootable as a fallback.
    scripts/config --set-str LOCALVERSION "$LOCALVERSION"

    # Ubuntu's config references debian/canonical-certs.pem for module signing,
    # but linux-source-* ships WITHOUT debian/. The certs/ step then fails, so
    # clear the keys and stop auto-signing. Safe because CONFIG_MODULE_SIG_FORCE
    # is unset in Ubuntu's config, so unsigned modules still load.
    scripts/config --disable MODULE_SIG_ALL
    scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

    make olddefconfig

    # ── Provide dwarf.h without libdw-dev ──
    # scripts/gendwarfksyms needs elfutils' dwarf.h. If the dev package is not
    # installed, extract just the headers from the .deb into a local tree and
    # export the paths the build reads below.
    if [[ ! -f /usr/include/dwarf.h ]]; then
        log "dwarf.h not found — staging libdw-dev headers locally (no root needed)."
        mkdir -p "$WORK_DIR/localdeps"
        ( cd "$WORK_DIR/localdeps" \
          && apt-get download libdw-dev \
          && dpkg-deb -x libdw-dev_*.deb . \
          && mkdir -p include/elfutils lib \
          && cp usr/include/dwarf.h include/ \
          && cp usr/include/elfutils/*.h include/elfutils/ \
          && ln -sf /usr/lib/x86_64-linux-gnu/libdw.so.1 lib/libdw.so ) \
            || log "WARNING: could not stage libdw-dev; build may fail on dwarf.h."
        export HOSTCFLAGS="-I$WORK_DIR/localdeps/include ${HOSTCFLAGS:-}"
        export HOSTLDFLAGS="-L$WORK_DIR/localdeps/lib ${HOSTLDFLAGS:-}"
        log "Staged local dwarf.h at $WORK_DIR/localdeps/include"
    fi

    log "Prepared. Local version: $(make -s kernelrelease)"
    log "Next: bash $0 build"
    ;;

build)
    cd "$SRC_DIR"
    [[ -f .config ]] || { echo "ERROR: run '$0 prepare' first." >&2; exit 1; }

    # Re-export locally staged headers if dwarf.h is still absent system-wide.
    if [[ ! -f /usr/include/dwarf.h && -d "$WORK_DIR/localdeps/include" ]]; then
        export HOSTCFLAGS="-I$WORK_DIR/localdeps/include ${HOSTCFLAGS:-}"
        export HOSTLDFLAGS="-L$WORK_DIR/localdeps/lib ${HOSTLDFLAGS:-}"
        log "Using locally staged dwarf.h"
    fi

    # `make bindeb-pkg` hands packaging to dpkg-buildpackage, which insists on
    # debhelper-compat (= 12) and libdw-dev:native. Build the image and modules
    # directly instead; `make install` handles /boot + initramfs, so no packaging
    # dependencies are required.
    log "Building kernel image + modules ($(nproc) jobs). This takes 20-40 minutes..."
    make -j"$(nproc)" bzImage modules

    log "Kernel release: $(make -s kernelrelease)"
    log "Artifacts:"
    log "  image  : $SRC_DIR/arch/x86/boot/bzImage"
    log "  modules: $(find "$SRC_DIR" -name '*.ko' | wc -l) built"
    log "Next (ROOT): sudo bash $0 install"
    ;;

install)
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: install must run as root: sudo bash $0 install" >&2; exit 1
    fi

    cd "$SRC_DIR"
    REL="$(make -s kernelrelease)"

    # ── Boot-safety gate: required modules must exist before we touch /boot ──
    # Root is btrfs on NVMe and btrfs / nvme / amdgpu are all built as modules.
    # Installing the kernel without them yields an unbootable system.
    for m in btrfs.ko nvme.ko nvme-core.ko amdgpu.ko; do
        if ! find "$SRC_DIR" -name "$m" | grep -q .; then
            echo "ERROR: required module $m was not built. Aborting install." >&2
            exit 1
        fi
    done
    log "Boot-critical modules present (btrfs, nvme, nvme-core, amdgpu)."

    log "Installing modules -> /lib/modules/$REL"
    make modules_install

    log "Installing kernel -> /boot/vmlinuz-$REL (+ initramfs)"
    make install

    if [[ ! -f "/boot/vmlinuz-$REL" ]]; then
        echo "ERROR: /boot/vmlinuz-$REL missing after install." >&2
        echo "DO NOT REBOOT into this kernel. Investigate first." >&2
        exit 1
    fi
    log "Verified: /boot/vmlinuz-$REL present."

    # ── Make the fallback reachable ──
    # GRUB_DEFAULT=0 + GRUB_TIMEOUT_STYLE=hidden + GRUB_TIMEOUT=0 auto-boots the
    # newest kernel with no menu and no fallback prompt — exactly how a machine
    # gets stranded by a locally built kernel.
    if grep -qE '^GRUB_TIMEOUT=0$' /etc/default/grub 2>/dev/null; then
        log "Setting a visible GRUB menu so the stock kernel stays selectable..."
        sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/' /etc/default/grub
        sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
    fi

    log "Updating GRUB..."
    update-grub

    log "Installed. The STOCK kernel (7.0.0-31-generic) remains as a fallback."
    log "Reboot, then verify:"
    log "  uname -r"
    log "  bash nodes/ubuntu-server-node-2/bench/check-p2p-hip.sh"
    ;;

*)
    echo "Usage: $0 [prepare|build|install]" >&2
    exit 1
    ;;
esac