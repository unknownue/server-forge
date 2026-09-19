#!/bin/bash
# Lightweight GPU-to-GPU P2P probe that needs NO PyTorch — only the HIP runtime,
# so it runs in the small rocm/rocm-terminal image (~4 GB) instead of the ~30 GB
# rocm/pytorch image. This answers the TP=2 feasibility question in ~1 minute.
#
# Why this matters: on Intel X99 dual-socket boards the two PCIe root complexes
# have no peer-to-peer routing between GPUs, so TP=2 falls back to host-memory
# staging (~3-7 GB/s instead of 30-900 GB/s) and is unusable. Proven the hard
# way on this exact platform class in lcz.me/topic/1532 post #16910.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/bench/check-p2p-hip.sh [IMAGE]

set -euo pipefail

IMAGE="${1:-docker.m.daocloud.io/rocm/rocm-terminal:latest}"
CACHE_DIR="${P2P_CACHE_DIR:-/data/work/cache/p2p-check}"
mkdir -p "$CACHE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Host-side topology pre-check ──
echo "════════════════════════════════════════════════════════════"
echo "  Host PCIe topology"
echo "════════════════════════════════════════════════════════════"
mapfile -t GPU_PCI < <(lspci -nn -d '::03xx' | grep -i '1002:744c' | awk '{print $1}')
echo "  GPUs found: ${#GPU_PCI[@]}  (${GPU_PCI[*]:-none})"
for d in "${GPU_PCI[@]}"; do
    grp=$(basename "$(readlink -f "/sys/bus/pci/devices/0000:$d/iommu_group" 2>/dev/null)" 2>/dev/null)
    parent=$(lspci -PP -s "$d" 2>/dev/null | head -1 | grep -oE '^[0-9a-f:]+' | head -1)
    echo "  $d  iommu_group=${grp:-?}  behind=${parent:-?}"
done
if [[ ${#GPU_PCI[@]} -ge 2 ]]; then
    g1=$(basename "$(readlink -f "/sys/bus/pci/devices/0000:${GPU_PCI[0]}/iommu_group" 2>/dev/null)" 2>/dev/null)
    g2=$(basename "$(readlink -f "/sys/bus/pci/devices/0000:${GPU_PCI[1]}/iommu_group" 2>/dev/null)" 2>/dev/null)
    if [[ -n "$g1" && "$g1" == "$g2" ]]; then
        echo "  => Same IOMMU group ($g1)."
    else
        # Separate IOMMU groups mean the cards hang off different root ports with
        # no switch between them — historically a bad sign — but this alone does
        # NOT decide the matter. On this X99 node P2P was eventually made to work
        # across separate root ports once the host bridge was added to the kernel
        # P2PDMA whitelist. Treat this as a hint, and trust the probe below.
        echo "  => Separate IOMMU groups ($g1 vs $g2): different root ports."
        echo "     Hint only — not a verdict. A host-bridge P2PDMA whitelist gap"
        echo "     can present exactly like this and is fixable in software."
    fi
fi

# ── Build the HIP probe ──
cat > "$CACHE_DIR/p2p_hip.cpp" <<'CEOF'
// Minimal HIP peer-access + bandwidth probe.
#include <hip/hip_runtime.h>
#include <hip/hip_runtime_api.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(x) do { hipError_t e = (x); if (e != hipSuccess) { \
    printf("HIP error %s at %s:%d\n", hipGetErrorString(e), __FILE__, __LINE__); \
    return 1; } } while (0)

int main(void) {
    int n = 0;
    CHECK(hipGetDeviceCount(&n));
    printf("HIP devices: %d\n", n);
    if (n < 2) { printf("VERDICT: <2 GPUs\n"); return 2; }

    char name[256];
    for (int i = 0; i < n; i++) {
        hipDeviceProp_t p;
        CHECK(hipGetDeviceProperties(&p, i));
        printf("  [%d] %s  gcnArch=%s  mem=%.1f GiB\n",
               i, p.name, p.gcnArchName, p.totalGlobalMem / 1073741824.0);
    }

    printf("\n=== hipDeviceCanAccessPeer matrix ===\n");
    int any_peer = 0;
    for (int i = 0; i < n; i++) {
        printf("  ");
        for (int j = 0; j < n; j++) {
            int can = 0;
            if (i == j) { printf("  -"); continue; }
            if (hipDeviceCanAccessPeer(&can, i, j) == hipSuccess && can) any_peer = 1;
            printf("%3d", can);
        }
        printf("\n");
    }
    printf("  any peer access: %s\n", any_peer ? "YES" : "NO");

    // Cross-device copy bandwidth via hipMemcpyPeer.
    printf("\n=== Cross-GPU bandwidth (256 MiB x 10 iters, hipMemcpyPeer) ===\n");
    size_t bytes = 256UL * 1024 * 1024;
    double best = 0.0;
    for (int src = 0; src < n; src++) {
        for (int dst = 0; dst < n; dst++) {
            if (src == dst) continue;
            CHECK(hipSetDevice(src));
            void *a = NULL, *b = NULL;
            if (hipMalloc(&a, bytes) != hipSuccess) continue;
            CHECK(hipSetDevice(dst));
            if (hipMalloc(&b, bytes) != hipSuccess) { hipSetDevice(src); hipFree(a); continue; }
            CHECK(hipMemset(b, 0, bytes));
            // warmup
            for (int k = 0; k < 2; k++) hipMemcpyPeer(b, dst, a, src, bytes);
            CHECK(hipDeviceSynchronize());
            hipEvent_t t0, t1;
            CHECK(hipEventCreate(&t0)); CHECK(hipEventCreate(&t1));
            CHECK(hipEventRecord(t0));
            int iters = 10;
            for (int k = 0; k < iters; k++) CHECK(hipMemcpyPeer(b, dst, a, src, bytes));
            CHECK(hipEventRecord(t1));
            CHECK(hipEventSynchronize(t1));
            float ms = 0; CHECK(hipEventElapsedTime(&ms, t0, t1));
            double gbs = (double)bytes * iters / (ms / 1000.0) / 1e9;
            if (gbs > best) best = gbs;
            printf("  GPU%d -> GPU%d : %7.2f GB/s\n", src, dst, gbs);
            hipEventDestroy(t0); hipEventDestroy(t1);
            hipFree(a); hipFree(b);
        }
    }

    printf("\n=== Verdict ===\n");
    printf("  best cross-GPU BW: %.2f GB/s\n", best);

    /*
     * Judgement is based on the PEER FLAG first, not raw bandwidth: a host-staged
     * copy can look "fast" on a wide link while never touching the peer path.
     *
     * The bandwidth floor is scaled to the link generation, because the absolute
     * number is meaningless without it:
     *   PCIe 3.0 x16 -> ~15.75 GB/s theoretical, ~10 GB/s P2P achieved
     *   PCIe 4.0 x16 -> ~31.5  GB/s theoretical, ~20+ GB/s P2P achieved
     * So for Gen3 hardware a healthy peer path shows ~8-12 GB/s, and a fixed
     * 25 GB/s threshold would wrongly reject it.
     */
    double floor_gbs = 7.0;   /* below this on ANY generation, it is host-staged */
    if (any_peer && best >= floor_gbs) {
        printf("  => TP=2 VIABLE: peer access granted AND %.2f GB/s is consistent\n", best);
        printf("     with a native peer path on this link generation.\n");
        printf("     (PCIe 3.0 x16 peaks near 15.75 GB/s; ~10 GB/s is expected.)\n");
        return 0;
    }
    if (any_peer) {
        printf("  => Peer access IS granted, but %.2f GB/s is low for a direct path.\n", best);
        printf("     Check the link width/speed (lspci -vv LnkSta) before trusting it.\n");
        return 1;
    }
    printf("  => TP=2 NOT VIABLE: no peer access; traffic is staged through host memory.\n");
    printf("     There is no working fallback on this node: one GPU cannot hold this\n");
    printf("     model (19 GB checkpoint on a 24 GB card), so a per-GPU split does not\n");
    printf("     fit either. Fix P2P, or serve a smaller model.\n");
    return 1;
}
CEOF

log "Compiling and running HIP probe in container..."
set +e
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add "$(getent group render | cut -d: -f3)" \
    --group-add "$(getent group video | cut -d: -f3)" \
    --security-opt seccomp=unconfined \
    -v "$CACHE_DIR:/work" \
    "$IMAGE" \
    bash -c 'cd /work && (hipcc -O2 -o p2p_hip p2p_hip.cpp 2>&1 || g++ -O2 -o p2p_hip p2p_hip.cpp -I/opt/rocm/include -L/opt/rocm/lib -lamdhip64 2>&1) && ./p2p_hip'
rc=$?
set -e

echo ""
echo "Probe exit code: $rc   (0 = TP=2 viable, 1 = TP=2 unusable, 2 = <2 GPUs)"
exit $rc