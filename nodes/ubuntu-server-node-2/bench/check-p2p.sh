#!/bin/bash
# Validate GPU-to-GPU P2P capability BEFORE installing any inference stack.
#
# Why this exists: on Intel X99 dual-socket boards the two PCIe root complexes
# have no peer-to-peer routing between GPUs. Dual-GPU tensor parallelism (TP=2)
# then falls back to host-memory staging at ~3-7 GB/s instead of 30-900 GB/s,
# which makes TP=2 unusable. This was proven the hard way on a HUANANZHI
# X99-T8D + 2x7900XTX (lcz.me/topic/1532 post #16910) after ~2 days of
# installing ROCm + a patched SGLang fork first.
#
# This script answers the question in ~2 minutes, using a ROCm Docker image so
# no host ROCm install is required.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/bench/check-p2p.sh [IMAGE]
#
# Default image is pulled through the configured registry mirror.

set -euo pipefail

IMAGE="${1:-rocm/pytorch:latest}"
CACHE_DIR="/data/cache/p2p-check"
mkdir -p "$CACHE_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Host-side pre-flight (no container needed) ──
echo "════════════════════════════════════════════════════════════"
echo "  Host PCIe topology pre-check"
echo "════════════════════════════════════════════════════════════"

mapfile -t GPU_PCI < <(lspci -nn -d '::03xx' | grep -i '1002:744c' | awk '{print $1}')
if [[ ${#GPU_PCI[@]} -lt 2 ]]; then
    echo "WARNING: expected 2x Navi 31 GPUs, found ${#GPU_PCI[@]}." >&2
fi

for d in "${GPU_PCI[@]}"; do
    echo "--- GPU $d ---"
    # Root port is the parent bridge; the GPU's own LnkSta shows the in-card
    # switch segment, not the real slot speed. Report both.
    parent=$(lspci -PP -s "$d" 2>/dev/null | head -1 | sed 's|/.*||')
    echo "  slot link : $(lspci -vvs "$d" 2>/dev/null | grep -m1 'LnkSta:' | sed 's/^\s*//')"
    echo "  root port : ${parent:-unknown}"
    grp=$(basename "$(readlink -f /sys/bus/pci/devices/0000:$d/iommu_group 2>/dev/null)" 2>/dev/null)
    echo "  iommu grp : ${grp:-none}"
done

if [[ ${#GPU_PCI[@]} -ge 2 ]]; then
    g1=$(basename "$(readlink -f /sys/bus/pci/devices/0000:${GPU_PCI[0]}/iommu_group 2>/dev/null)" 2>/dev/null)
    g2=$(basename "$(readlink -f /sys/bus/pci/devices/0000:${GPU_PCI[1]}/iommu_group 2>/dev/null)" 2>/dev/null)
    if [[ -n "$g1" && "$g1" == "$g2" ]]; then
        echo ""
        echo "  Same IOMMU group ($g1) — P2P is plausible."
    else
        echo ""
        echo "  Separate IOMMU groups ($g1 vs $g2) — P2P is UNLIKELY."
        echo "  Both GPUs sit behind independent root ports; there is no PCIe"
        echo "  switch between them to route peer traffic."
    fi
fi

# ── Container-side runtime probe ──
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ROCm runtime probe (image: $IMAGE)"
echo "════════════════════════════════════════════════════════════"
log "Pulling image if needed (this may take a while on first run)..."
docker pull "$IMAGE"

cat > "$CACHE_DIR/p2p_probe.py" <<'PYEOF'
import os, sys, time
import torch

print(f"torch          : {torch.__version__}")
print(f"hip version    : {getattr(torch.version, 'hip', None)}")
print(f"device count   : {torch.cuda.device_count()}")
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"  [{i}] {p.name}  gcnArch={getattr(p, 'gcnArchName', '?')}  "
          f"{p.total_memory / 2**30:.1f} GiB")

n = torch.cuda.device_count()
if n < 2:
    print("\nVERDICT: fewer than 2 visible GPUs — cannot test P2P.")
    sys.exit(2)

print("\n=== hipDeviceCanAccessPeer matrix ===")
peer_matrix = {}
try:
    import ctypes
    hip = ctypes.CDLL("libamdhip64.so")
    for i in range(n):
        for j in range(n):
            if i == j:
                peer_matrix[(i, j)] = 1
                continue
            can = ctypes.c_int(0)
            hip.hipSetDevice(i)
            rc = hip.hipDeviceCanAccessPeer(ctypes.byref(can), i, j)
            peer_matrix[(i, j)] = can.value if rc == 0 else -1
    for i in range(n):
        print("  " + "  ".join(f"{peer_matrix[(i, j)]:>3}" for j in range(n)))
except Exception as e:
    print(f"  (peer query failed: {e})")

print("\n=== Cross-device bandwidth (64 MiB, 20 iters) ===")
def measure(src, dst):
    N = 64 * 1024 * 1024 // 4
    a = torch.ones(N, dtype=torch.float32, device=f"cuda:{src}")
    b = torch.empty(N, dtype=torch.float32, device=f"cuda:{dst}")
    # warmup
    for _ in range(3):
        b.copy_(a)
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    iters = 20
    for _ in range(iters):
        b.copy_(a)
    torch.cuda.synchronize()
    dt = time.perf_counter() - t0
    gb = (N * 4 * iters) / 1e9
    return gb / dt

bw = {}
for src in range(n):
    for dst in range(n):
        if src == dst:
            continue
        try:
            v = measure(src, dst)
            bw[(src, dst)] = v
            print(f"  GPU{src} -> GPU{dst}: {v:7.2f} GB/s")
        except Exception as e:
            print(f"  GPU{src} -> GPU{dst}: FAILED ({e})")

print("\n=== Verdict ===")
best = max(bw.values()) if bw else 0.0
any_peer = any(v == 1 for k, v in peer_matrix.items() if k[0] != k[1])
print(f"  peer access available : {any_peer}")
print(f"  best cross-GPU BW     : {best:.2f} GB/s")
if any_peer and best > 25:
    print("  => TP=2 is VIABLE (native peer path).")
    sys.exit(0)
elif best > 25:
    print("  => High bandwidth without peer flag; TP=2 may still work. Verify with NCCL.")
    sys.exit(0)
else:
    print("  => TP=2 is NOT VIABLE. Cross-GPU traffic is staged through host memory.")
    print("     Use DP=2 (one instance per GPU) instead.")
    sys.exit(1)
PYEOF

docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add "$(getent group render | cut -d: -f3)" \
    --group-add "$(getent group video | cut -d: -f3)" \
    --security-opt seccomp=unconfined \
    --ipc=host \
    -e "HOME=/cache" \
    -v "$CACHE_DIR:/cache" \
    "$IMAGE" \
    python /cache/p2p_probe.py
rc=$?

echo ""
echo "Probe exit code: $rc  (0 = TP=2 viable, 1 = use DP=2, 2 = <2 GPUs)"
exit $rc