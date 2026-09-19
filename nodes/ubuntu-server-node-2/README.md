# ubuntu-server-node-2

## Hardware
Full hardware report: [hardware-info.txt](hardware-info.txt)

| Component | Detail |
|:---|:---|
| CPU | 2× Intel Xeon E5-2686 v4 (18C/36T each, 36C/72T total), Haswell-EP |
| RAM | 121 GiB DDR4 (4 NUMA nodes reported by EDAC) |
| GPU | 2× AMD Radeon RX 7900 XTX (Navi 31, `1002:744c`), 24 GB VRAM each |
| Motherboard | HUANANZHI X99-8D3 V1.2, BIOS 5.11 (2026-03-25) |
| Storage | 1× NVMe 1.8T (`nvme0n1`) |

## Operating System
- OS: Ubuntu Server 26.04.1 LTS (Resolute Raccoon)
- Kernel: 7.0.0-31-generic (x86_64)
- Partition layout:

| Mount point | Size | FS | Source |
|:---|:---|:---|:---|
| `/boot/efi` | 1G | vfat | nvme0n1p1 |
| `/` | 1.8T | btrfs | nvme0n1p2 |

- **No LVM**, no separate `/boot`, and no unallocated space — the installer put
  root on a single btrfs partition spanning the whole disk.
- Boot: GRUB (`/boot/grub/grub.cfg`), EFI entry under `/boot/efi/EFI/ubuntu`.
- Swap: `/swap.img` (8G, swapfile — not a partition).

### Consequence for the data-volume strategy

node1 splits OS (`/`, 200G LVM LV) from data (`/data`, 1.37T LV) with ~260G headroom.
**That layout is not reproducible here without repartitioning**, so this node uses a
different mechanism to get the same separation:

| Path | Backing | Role |
|:---|:---|:---|
| `/` | btrfs subvolume (default) | OS, drivers, project code only |
| `/data` | **btrfs subvolume**, `compress=zstd` | Docker images, repos, LLM models, datasets, checkpoints |
| `/data/cache` | btrfs subvolume, `compress=zstd` | Disposable caches (Triton, TorchInductor, HF, ROCm) |

A btrfs subvolume is a first-class, independently snapshottable and quotable
filesystem root — functionally the equivalent of a dedicated LV here. See
`provision/allocate-storage.sh`.

Unlike an LV, a subvolume cannot be sized at creation; capacity is governed by the
shared pool. Use `btrfs qgroup` or simply monitor `btrfs filesystem usage /` —
headroom is whatever is free on `/` (currently ~1.8T of 1.9T).

## Driver Configuration

- GPU: `amdgpu` kernel module (in-tree, Mesa 26.0.8 userspace). Both cards bound
  and active — `lsmod` shows `amdgpu` in use by 32 handles.
- Vulkan: `mesa-vulkan-drivers` 26.0.8 (RADV) present; `libdrm-amdgpu1` 2.4.131.
- **ROCm is not installed** — see provisioning step 6. The RX 7900 XTX (gfx1100)
  is a supported ROCm target, but the stack must be installed before any
  GPU compute workload can run.
- No display/compute split: both cards are identical, so no primary-GPU udev rule
  is needed (contrast node1, which has a separate GT 1030 display GPU).

### Note on CPU feature limits

The E5-2686 v4 is Haswell-EP: **AVX2 only, no AVX-512, no AMX**. Modern CPU-side
inference kernels (llama.cpp/GGUF, some PyTorch builds) will fall back to AVX2
paths, and CPU-only inference will be substantially slower than on a server-grade
Sapphire Rapids part. Treat this machine as **GPU-first**.

## Roles

- `compute` — GPU inference/training via Docker + ROCm (once provisioned)
- `storage-heavy` — 1.8T btrfs pool, intended to hold model weights and datasets

## Provisioning Log

Steps below mirror node1's structure, with commands adjusted for this machine.
Everything is run from the repo root.

### 1. OS Installation
- Ubuntu Server 26.04.1 LTS live-server ISO.
- Partitioning: guided "use entire disk" → single btrfs root, no LVM.
- No network configured during install.

### 2. Network Setup

Interface `enp8s0` is up via DHCP:

```bash
ip -brief addr
```

Current address: `192.168.50.143/24`, gateway `192.168.50.1`, DHCP-assigned.
Note this is a **different subnet** from node1 (`10.0.0.101`) — the two nodes are
not on a shared layer-2 segment by default.

### 3. Mirror Setup
```bash
curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
sudo bash ChangeMirrors.sh --lang en-us
rm ChangeMirrors.sh
```

### 4. System Packages
```bash
sudo bash nodes/ubuntu-server-node-2/provision/install-packages.sh
```

Installs git and Python tooling. Append new dependencies to that script as needed.

```bash
bash nodes/ubuntu-server-node-2/config/set-git-config.sh "unknownue" "unknownue@outlook.com"
```

### 5. Docker
```bash
sudo bash nodes/ubuntu-server-node-2/provision/install-docker.sh [registry-mirror]
# e.g. sudo bash nodes/ubuntu-server-node-2/provision/install-docker.sh registry.cn-hangzhou.aliyuncs.com
```

Configures `data-root=/data/docker` and optional registry mirrors.

### 6. ROCm (AMD GPU stack)

This replaces node1's NVIDIA Container Toolkit steps. **Not yet applied on this
machine** — run it to enable GPU compute:

```bash
sudo bash nodes/ubuntu-server-node-2/provision/install-rocm.sh
```

The script installs the `amdgpu-install` package from AMD's repository and selects
the `rocm` use case. Verify afterwards:

```bash
rocminfo | grep gfx          # expect gfx1100 for RX 7900 XTX
rocm-smi                    # expect both cards listed
groups                       # current user must be in render, video
```

Then reboot (or re-login) so the new group membership and kernel modules apply.

> **Headers caveat**: Ubuntu 26.04 ships kernel 7.0, which is newer than the kernel
> that ships with any released ROCm DKMS package. If `amdgpu-dkms` fails to build,
> use the in-tree `amdgpu` module (already loaded and working) and install only the
> **userspace** ROCm runtime. Do not let a failed DKMS build block the userspace
> install — `amdgpu-install --no-dkms` is the safe fallback.

### 7. Post-install verification
```bash
docker run --rm --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  rocm/rocm-terminal rocminfo | grep -E 'Name|gfx'
```

## GPU-to-GPU P2P: WORKING after a locally built kernel

Both GPUs sit behind *separate* PCIe root ports in *separate* IOMMU groups — but
under the **same** host bridge (socket 0), which is what makes P2P possible:

| GPU | Root port | IOMMU group | Host bridge |
|:---|:---|:---|:---|
| `0000:05:00.0` | `00:02.0` | 90 | `00:00.0` |
| `0000:08:00.0` | `00:03.0` | 94 | `00:00.0` |

Measured with `bash nodes/ubuntu-server-node-2/bench/check-p2p-hip.sh`:

```
1) Stock kernel, ReBAR OFF (BAR0 = 256 MiB):
     hipDeviceCanAccessPeer : NO both ways
     GPU0 -> GPU1 : 5.94 GB/s      GPU1 -> GPU0 : 5.63 GB/s

2) Stock kernel, ReBAR ON (BAR0 = 32 GiB):
     hipDeviceCanAccessPeer : NO both ways        (unchanged)
     GPU0 -> GPU1 : 2.73 GB/s      GPU1 -> GPU0 : 3.01 GB/s

3) Patched kernel 7.0.14-x99p2p (P2PDMA whitelist entry added):
     hipDeviceCanAccessPeer : YES both ways       <-- FIXED
     GPU0 -> GPU1 : 10.17 GB/s     GPU1 -> GPU0 : 10.17 GB/s
```

Step 2 is worth remembering: a large BAR alone made things *worse*. It made the
peer's VRAM mappable but the fabric still did not route peer traffic, so
host-staged copies merely paid extra translation cost. ReBAR is necessary but
not sufficient.

Interpreting 10.17 GB/s: this is PCIe **3.0** x16 (Haswell-EP), ceiling
~15.75 GB/s, so ~65% of theoretical is normal and matches the ~10.29 GB/s
reported in the forum on comparable X99 hardware. Do not compare against
PCIe 4.0/5.0 figures. The probe's pass threshold is generation-aware for this
reason.

Independent confirmation from KFD topology — genuine GPU↔GPU links appear that
did not exist before:
```
node_from 2 node_to 3 ... max_bandwidth 16000 ... flags 3
node_from 3 node_to 2 ... max_bandwidth 16000 ... flags 3
```
`flags 3` = `P2P_CAPABLE | P2P_DIRECT`; `16000` MB/s matches Gen3 x16.

### Root cause and fix

Host bridge **`8086:6f00`** (Xeon E7 v4/E5 v4 DMI2) was absent from
`drivers/pci/p2pdma.c`'s `pci_p2pdma_whitelist[]`, which lists Haswell-EP **v3**
(`0x2f00`/`0x2f01`) but not v4. Every peer transfer through this bridge was
rejected.

Fix: a locally built kernel adding `0x6f00`/`0x6f01` (see
`provision/build-p2p-kernel.sh` and
`provision/patches/p2pdma-broadwell-ep-v4.patch`). `CONFIG_PCI=y` makes p2pdma
built-in, so a full kernel build was unavoidable.

Verified *not* the cause: `setpci -s 00:02.0 ECAP_ACS+0x6.w` reports **no ACS
capability** on the root ports; virtualization is irrelevant (bare metal here);
and the earlier "X99 cannot do P2P" conclusion was **wrong** — it is a software
whitelist gap, as [lcz.me/topic/1791](https://lcz.me/topic/1791) #18997 found.

> **Maintenance**: kernel patches do not survive kernel upgrades. This node now
> runs a locally built kernel; hold it (`apt-mark hold`) or convert to DKMS
> before any `apt upgrade`, and re-run the probe afterwards.

### RCCL: FIXED — direct P2P now used (second layer, resolved)

HIP-level P2P works, but stock RCCL refused to use it. Measured two-rank
all-reduce, 256 MiB, identical hardware throughout:

| RCCL | `NCCL_P2P_LEVEL` | busbw | path |
|:---|:---|:---|:---|
| stock 2.30.4 | unset | 5.66 GB/s | SHM |
| stock 2.30.4 | `PHB` | 5.68 GB/s | SHM — env var silently ignored |
| stock 2.30.4 | `SYS` | 5.65 GB/s | SHM |
| stock 2.30.4 | `NCCL_P2P_DISABLE=1` | 5.62 GB/s | SHM (forced) |
| **patched 2.31.2** | unset | 5.62 GB/s | SHM — arch clamp still applies |
| **patched 2.31.2** | **`PHB`** | **9.61 GB/s** | **Direct P2P — +70%** |

9.61 GB/s is ~95% of the 10.17 GB/s raw HIP peer-copy ceiling, i.e. the host
round-trip is gone.

**Both the patch and `NCCL_P2P_LEVEL=PHB` are required.** The stock rows prove the
env var alone does nothing; the patched-unset row proves the patch alone does
nothing either. This reproduces lcz.me/topic/1791 #18997 exactly.

Cause, confirmed in source: in `src/graph/paths.cc`, `ncclTopoCheckP2p()` reads
the user's level and then a hardcoded Intel branch overwrites it:
```c
int p2pLevel = PATH_SYS;
NCCLCHECK(ncclGetUserP2pLevel(&p2pLevel));   // user asks for PATH_PHB (8)
if (arch == X86 && vendor == INTEL) p2pLevel = PATH_PXB;   // forced to 5
if (path->type <= p2pLevel) *p2p = 1;        // 8 <= 5 -> false, P2P refused
```
A cross-root-port GPU pair classifies as `PATH_PHB`(8), so the test always fails
on Intel. Fix: `provision/patches/rccl-intel-p2p-level-override.patch` captures
the user level before the clamps and re-applies it afterwards.

**Source location**: RCCL moved to the `ROCm/rocm-systems` super-repo, at
`projects/rccl`. Building from there works (unlike the old `ROCm/rccl` develop
branch, which could not produce a loadable library — see
`bench/results/rccl-fallback-evidence.txt` for that dead end and the four
environment quirks that had to be worked around). The patch applies with
`patch -p3` inside a `projects/rccl` checkout.

### Consequences for TP=2

- **HIP P2P: working** (10.17 GB/s peer copy).
- **RCCL: working with the patch** (9.61 GB/s all-reduce, `PHB` set). SGLang/vLLM
  TP=2 must therefore run with `NCCL_P2P_LEVEL=PHB` exported, and against the
  patched RCCL image (`rocm-pytorch-rccl-patched:local`), or it silently reverts
  to the host-staged path.
- **There is no DP fallback.** A per-GPU data-parallel split cannot fit this
  model (see the note below), so TP=2 with working P2P is the only way to use
  both cards for it.

### All three layers — COMPLETE

| Layer | Status |
|:---|:---|
| 1. BIOS: Above 4G Decoding + ReBAR | **DONE** — BAR0 is 32 GiB on both cards |
| 2. Kernel: `8086:6f00`/`6f01` added to the P2PDMA whitelist | **DONE** — kernel `7.0.14-x99p2p` built, installed and booted; peer access granted, 10.17 GB/s |
| 3. RCCL: user `NCCL_P2P_LEVEL` no longer clobbered on Intel | **DONE** — patched RCCL 2.31.2 from `ROCm/rocm-systems`; 9.61 GB/s all-reduce with `PHB` |

Always verify rather than assume: run `bench/check-p2p-hip.sh` after any kernel
or ROCm change, and confirm a collective is genuinely on the peer path (compare
against a `NCCL_P2P_DISABLE=1` run) before trusting TP=2 throughput.

### Check it yourself before any multi-GPU work

```bash
bash nodes/ubuntu-server-node-2/bench/check-p2p-hip.sh
# exit 0 = TP=2 viable, 1 = TP=2 unusable, 2 = fewer than 2 GPUs
```

Uses HIP only (no PyTorch), so it runs in the ~4 GB `rocm/rocm-terminal` image.

## SGLang gfx1100 reproduction (lcz.me/topic/1532) — WORKING

**Status: reproduced.** The thread's dual-7900-XTX SGLang stack runs here in
TP=2 and lands in its claimed performance range.

| Metric | Post claims | Measured here |
|:---|:---|:---|
| Decode (TG) | 80–100 tok/s | **73–103 tok/s** steady state; **77.7 tok/s** end-to-end |
| TTFT | < 1 s | **0.26–0.87 s** |
| Context | 192k (bf16 KV) | **196,608** configured, 195,013 KV tokens |
| Spec decoding | MTP-3 | accept len 2.12–3.62 / 4, accept rate 56–88% |

Deployment: kernel `7.0.14-x99p2p` + patched RCCL 2.31.2 + image
`sglang-gfx1100-x99:local` (ROCm 7.14 / torch 2.13 + the gfx1100 fork).
Full write-up: `bench/results/sglang-tp2-reproduction.txt`.

```bash
bash nodes/ubuntu-server-node-2/serve/sglang-tp2.sh tp2 8080
```

**Measurement caveat**: a streaming client that times per-SSE-chunk under-reports
this badly (~36 tok/s on a run the engine reports at 75–103). Use non-streaming
`usage.completion_tokens / elapsed`, or the engine's own gen-throughput log.

Five build problems had to be solved for the fork to run on ROCm 7.14 — the
atomicAdd ambiguity, the wrong GPU arch (`AMDGPU_TARGET`, not `PYTORCH_ROCM_ARCH`),
the `gptq_gemm` schema arity, stale `sgl_kernel` Python wrappers, and the missing
pre-built `rdna_ar_ext`. All are scripted and documented in the results file.

> The earlier note in this README claiming the thread's numbers "cannot be
> reproduced here" was based on the P2P probe failing at that time. It was
> **wrong** — P2P was fixable in software (kernel whitelist + RCCL clamp), and
> once fixed, TP=2 reproduces as above.

## Mirror & offline-install notes

This network cannot reach Docker Hub, `pypa.io`, or `github.com` raw reliably.
Working sources, verified 2026-09-18:

| Resource | Working source |
|:---|:---|
| Docker images | `docker.m.daocloud.io` (fast), `docker.1ms.run` (manifest OK, slow blobs), `registry.cn-hangzhou.aliyuncs.com` |
| HuggingFace models | `hf-mirror.com` (default in `scripts/lib/download-model.sh`) |
| PyPI | `https://pypi.tuna.tsinghua.edu.cn/simple` |

Pull images by naming the mirror host explicitly — this needs **no** daemon
config and no root:

```bash
docker pull docker.m.daocloud.io/rocm/rocm-terminal:latest
```

To make it transparent instead, set it daemon-wide:
`sudo bash config/set-docker-registry.sh docker.m.daocloud.io`.

### Python tooling without root

This node lacks `python3-venv` (so `ensurepip` is unavailable) and `python3-pip`,
and `bootstrap.pypa.io` is unreachable. The project `.venv` is therefore a shim
at `.venv/bin/python3` that runs the system Python with `PYTHONPATH=.pylibs`:

```bash
.venv/bin/python3 -c "import huggingface_hub; print(huggingface_hub.__version__)"
```

`scripts/lib/download-model.sh` works unmodified through it. To replace the shim
with a real venv, install the Debian packages:

```bash
sudo apt install -y python3-venv python3-pip
```

## Permissions caveat

`/data/cache` is root-owned and **not writable** by the regular user, while
`/data/work` is. Scripts here therefore default their scratch space to
`/data/work/cache/...`. To use the intended `/data/cache`, run
`sudo bash scripts/fix-data-permissions.sh` (or `sudo chown "$USER" /data/cache`).

## Service Hub (web UI)

A local web UI for starting/stopping serve profiles and watching GPU state, so a
post-reboot start is one click instead of a remembered command:

```bash
bash nodes/ubuntu-server-node-2/service-hub/deploy.sh   # http://localhost:9090/
bash nodes/ubuntu-server-node-2/service-hub/stop.sh     # stops the hub only
```

Profiles live in `profiles/` (`sglang-tp2`, `sglang-single`) and are re-read on
every request, so adding a YAML file needs no restart. Switching stops
all managed containers first, then starts the target profile and waits until its
health endpoint answers.

Two things are AMD-specific versus node1's hub:

- **GPU status is read from sysfs**, not `rocm-smi` — that CLI is not installed on
  the host at all (ROCm lives in containers), and sysfs gives busy %, VRAM and
  hwmon temperature with no extra packages and no privileged calls.
- **P2P status is shown in the UI.** Multi-GPU profiles depend on peer access,
  which depends on the patched kernel and patched RCCL. Losing either leaves TP=2
  functional but silently host-staged and much slower, so the banner reports it
  rather than leaving it to be noticed as poor throughput.

See `service-hub/README.md` for the API and how to add profiles.

## Running Docker without sudo

This node deliberately keeps the **root dockerd** (system service) rather than
switching to rootless Docker. The account `unknownue` is in the `docker` group,
so every container operation runs unprivileged from the shell's point of view.

**Why not rootless**: rootless dockerd keeps its image store under
`~/.local/share/docker`, so it would not see the ~125 GB already in
`/data/docker` — including `sglang-gfx1100-x99:local`, which is built locally and
cannot be re-pulled from a registry. Rootless would mean a `docker save`/`load`
image migration for no functional gain on a single-user box.

**Security note (be aware)**: `docker` group membership is effectively
root-equivalent — a container can mount `/` and write anywhere. That is the
accepted tradeoff of this choice.

### The only privileged step: registry mirrors

`/etc/docker/daemon.json` is root-owned and applying changes restarts dockerd, so
mirror configuration is the one remaining `sudo` command:

```bash
sudo bash nodes/ubuntu-server-node-2/config/set-docker-registry.sh
# uses the verified set: docker.m.daocloud.io, docker.1ms.run, docker.xuanyuan.me
```

**This is optional.** Naming the mirror on the pull works with no root at all,
and is what the build scripts do:

```bash
docker pull docker.m.daocloud.io/rocm/pytorch:latest   # no sudo, no daemon config
```

### Everything else is unprivileged

| Task | Command |
|:---|:---|
| Build/run containers | `bash nodes/ubuntu-server-node-2/serve/sglang-tp2.sh tp2 8080` |
| P2P probe | `bash nodes/ubuntu-server-node-2/bench/check-p2p-hip.sh` |
| Download models | `bash nodes/ubuntu-server-node-2/download-model.sh` |
| Build RCCL/SGLang images | `bash nodes/ubuntu-server-node-2/provision/build-*.sh` |

Only OS-level provisioning (`install-*.sh`, `allocate-storage.sh`) and installing
the patched kernel still require root, by nature.

## Directory Structure

```
ubuntu-server-node-2/
├── README.md, hardware-info.txt, download-model.sh
├── config/              # Node-level config (models.conf, git, docker registry)
├── profiles/            # YAML serve profiles, switched by the Service Hub
├── provision/           # OS provisioning (one-shot, root)
│   ├── install-*.sh, allocate-storage.sh
│   ├── build-p2p-kernel.sh        # Kernel with the P2PDMA whitelist fix
│   ├── build-rccl-p2p.sh          # Patched RCCL + derived image
│   ├── build-sglang-gfx1100.sh    # SGLang gfx1100 fork image
│   └── patches/                   # The four source patches
├── serve/               # Container launchers
│   ├── sglang-tp2.sh              # SGLang TP=2/DP launcher
│   └── patch-mtp-quant-config.sh  # Required model patch before SGLang load
├── service-hub/         # Web UI: GPU status + one-click profile switching
│   ├── deploy.sh, stop.sh         # foreground run / stop
│   ├── install-service.sh         # systemd --user unit (recommended)
│   ├── systemd/service-hub.service
│   ├── src/service_hub/           # FastAPI backend (sysfs GPU monitor)
│   └── frontend/                  # Vue 3 + Vite, builds into static/
└── bench/               # Performance tests / platform probes
    ├── check-p2p-hip.sh           # GPU P2P probe (HIP only)  ← run first
    ├── check-p2p.sh               # Same, PyTorch-based variant
    └── results/                   # p2p-verdict, rccl-fallback-evidence,
                                   # sglang-tp2-reproduction
```

### Quick start after a reboot

```bash
bash nodes/ubuntu-server-node-2/service-hub/install-service.sh   # then open :9090
```

Runs as a `systemd --user` service (auto-restart on failure). To keep it up with
no login session, run once: `sudo loginctl enable-linger $USER` — without it the
user manager stops at logout. The UI shows both GPUs live and starts a serving
profile in one click. Note that
ROCm containers take `--device=/dev/kfd --device=/dev/dri` with the host
render/video **GIDs** via `--group-add` — the group *names* do not exist inside
ROCm images.

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-09-19 | Measured TP=2 vs DP=2; found DP=2 cannot start | TP=2 measured at 31.8 / 41.0 / **78.7** tok/s aggregate for c=1/2/4 (256 tok, TTFT 0.26-0.53 s). **DP=2 is a hard capacity failure, not tuning**: each instance needs the whole 19 GB checkpoint on one 24 GB card, and at `--mem-fraction-static 0.90` the hybrid state cache goes negative (`rest_memory=-4.84 GB`, `max_mamba_cache_size=-18`), so both containers exit during startup. TP=2 only fits because sharding halves per-card weights to 9.12 GB. The dp2 profile and launcher mode were then **removed** — it is not a tuning problem and cannot be revived by lowering the memory fraction, so keeping it risked someone selecting it and concluding the node was broken. The analysis is retained in `bench/results/tp2-vs-dp2.txt`. |
| 2026-09-19 | Benchmark initially under-reported throughput by ~40% | The model streams a `reasoning_content` thinking channel; counting only `content` deltas dropped those tokens. c=1 aggregate was 27.9 tok/s instead of the correct 31.8. Fixed in `bench/bench-concurrency.py`, and noted as a pitfall since the same mistake flatters or deflates any comparison. |
| 2026-09-19 | Service Hub died with the shell/session | Added a `systemd --user` unit (`service-hub.service`) plus `install-service.sh` to install/enable it reproducibly. `Restart=on-failure` verified by killing the process (came back on a new PID). Note: a user unit **cannot** depend on `docker.service` — that is a *system* unit invisible to the user manager, and `After=`/`Requires=` fails with "Unit docker.service not found"; `deploy.sh` waits for `docker info` instead. Lingering is off by default, so `sudo loginctl enable-linger $USER` is required for the hub to survive logout; the installer reports this rather than assuming it. |
| 2026-09-19 | Added a web UI to start services without remembering commands | Built `service-hub/` (FastAPI + Vue 3), modeled on node1's. Two AMD-specific changes: GPU status is read from **sysfs** because no ROCm CLI exists on the host, and **P2P health is surfaced in the UI** because losing the patched kernel or RCCL degrades TP=2 silently rather than erroring. Added `profiles/` with `sglang-tp2` and `sglang-single`; verified the full cycle (stop → switch → healthy → inference) through the API. |
| 2026-09-19 | `serve/sglang-tp2.sh` silently exited without starting anything | Two bugs, both masked by `set -e`: (1) `stop_existing` piped to `grep -q`, and a no-match returned non-zero, aborting the script before launch; (2) the container was started with no command and the server was injected via `docker exec -d`, but the container had already exited. Fixed by collecting container ids without a failing pipe, and by making the server the container's main process. |
| 2026-09-19 | Non-root Docker workflow settled; registry mirrors left unconfigured | Kept the **root dockerd** (rootless would not see the ~125 GB in `/data/docker`, incl. the locally-built SGLang image, and would force a save/load migration). The `docker` group already allows unprivileged container use; documented that group membership is root-equivalent. `config/set-docker-registry.sh` rewritten to configure multiple mirrors with a reachability check — the one remaining `sudo` step, and optional since builds can name the mirror per-pull. |
| 2026-09-19 | Cleanup after reproduction | Removed 33 GB of build scratch under `tmp/` (kernel tree, RCCL and SGLang sources — all re-fetchable via the provision scripts), the leftover `probe:tmp` image (83.8 GB), the superseded `serve/sglang-gfx1100.sh`, and four obsolete scratch notes. Repository docs are the single source of truth. |
| 2026-09-19 | **SGLang TP=2 REPRODUCED** — thread's numbers achieved | Server serves Qwen3.8-27B on 2×7900XTX with TP=2 + MTP-3 + the fork's RDNA custom all-reduce: 77.7 tok/s end-to-end, 73–103 tok/s steady-state decode, TTFT 0.26–0.87 s, 195k KV tokens. Five build problems solved (atomicAdd ambiguity, `AMDGPU_TARGET` not `PYTORCH_ROCM_ARCH`, `gptq_gemm` schema arity, stale `sgl_kernel` Python wrappers shadowing the fork's, missing pre-built `rdna_ar_ext`). See `bench/results/sglang-tp2-reproduction.txt`. |
| 2026-09-19 | First throughput readings looked wrong (~36 tok/s) | Client-side artifact: timing per-SSE-chunk under-reports. The engine's own log showed 75–103 tok/s on the same run. Corrected method: non-streaming `usage.completion_tokens` / elapsed. |
| 2026-09-18 | **Corrected** earlier "X99 P2P is structurally impossible" conclusion after forum research | Upstream `pci_p2pdma_whitelist[]` covers Haswell-EP v3 (`8086:2f00`) but not v4 (`8086:6f00`) — our bridge. It is a software gap, not a hardware limit: lcz.me/topic/1791 #18997 closed it on X99 with a patched kernel + patched RCCL (~10.3 GB/s P2P, working SGLang TP2 at 251.5K). Both our GPUs are under the same host bridge, so the `REQ_SAME_HOST_BRIDGE` constraint is satisfied. Also confirmed the root ports expose **no ACS**, ruling ACS out as the cause. |
| 2026-09-18 | User enabled BIOS Above 4G Decoding + ReBAR | BAR0 went 256 MiB → **32 GiB** on both cards, addresses moved to the high 64-bit range. P2P still not established: `hipDeviceCanAccessPeer` remains NO and cross-GPU bandwidth *fell* to 2.73–3.01 GB/s (host-staged copies over a larger aperture). Confirms ReBAR is necessary but not sufficient — the kernel whitelist entry is the next gate. |
| 2026-09-18 | **P2P FIXED** — built and booted kernel `7.0.14-x99p2p` with the Broadwell-EP v4 P2PDMA whitelist entry | `hipDeviceCanAccessPeer` now **YES** both ways; cross-GPU copy **10.17 GB/s** (was 0 / ~3 GB/s), matching the ~10.29 GB/s reported on comparable X99 hardware. KFD topology now exposes GPU↔GPU links with `flags 3` (P2P_CAPABLE\|P2P_DIRECT). Kernel worked around three build blockers: `bindeb-pkg` needing debhelper, `certs` referencing absent `debian/canonical-certs.pem`, and a missing `dwarf.h`. Reproducible via `provision/build-p2p-kernel.sh`. |
| 2026-09-19 | **RCCL FIXED** — patched RCCL built from `ROCm/rocm-systems`; direct P2P now used | The RCCL repo redirects to the `ROCm/rocm-systems` super-repo at `projects/rccl`, whose tree builds where the old `ROCm/rccl` develop branch could not. Result: all-reduce went **5.62 → 9.61 GB/s** (+70%), ≈95% of the 10.17 GB/s raw HIP ceiling. Confirmed **both** the patch and `NCCL_P2P_LEVEL=PHB` are required: stock+PHB → SHM, patched+unset → SHM, patched+PHB → Direct P2P. |
| 2026-09-18 | RCCL fell back to SHM despite working HIP P2P (first attempt to patch it failed) | Proved the fallback by measurement: default 5.73, `NCCL_P2P_LEVEL=PHB` 5.68, `=SYS` 5.65, `NCCL_P2P_DISABLE=1` 5.62 GB/s — all identical, so RCCL was already on SHM and the env var did nothing. Cause: the Intel clamp in `ncclTopoCheckP2p()` forcing `PATH_PXB`(5) and pre-empting the user's `PATH_PHB`(8). Building from the then-current public tree was a dead end (missing `ncclSymkGetKernelPtr` definition; enabling its generator emitted un-hipified CUDA). Superseded by the entry above. |
| 2026-09-18 | Attempted lcz.me/topic/1532 SGLang reproduction; P2P probe found TP=2 blocked | Probed before installing the whole stack (the source thread lost ~2 days doing it in the opposite order). Recorded in `bench/results/p2p-verdict.txt`; the thread's headline c=4/TP=2 numbers remain unreproducible until P2P is fixed. |
| 2026-09-18 | `/data/cache` root-owned → scripts could not create scratch dirs | Scripts default scratch to `/data/work/cache/…`; documented `sudo bash scripts/fix-data-permissions.sh` as the real fix. |
| 2026-09-18 | No `python3-venv`/`python3-pip`; `bootstrap.pypa.io` unreachable | Bootstrapped pip via a Tsinghua-mirror wheel into `.pylibs/`, and made `.venv/bin/python3` a shim so `scripts/lib/download-model.sh` runs unmodified. `sudo apt install python3-venv python3-pip` replaces the shim. |
| 2026-09-18 | Docker Hub unreachable; free `docker.xuanyuan.me` node rate-limited mid-pull | Use explicit mirror-host image refs (no daemon config or root needed). `docker.m.daocloud.io` measured fastest; documented per-mirror status in the Mirror notes section. |
| 2026-09-18 | `allocate-storage.sh` failed at the mount step: `mount: /data: /@data is not a block device` | Root cause: the script passed the subvolume *path* as the mount source. A btrfs subvolume is mounted by naming the containing **device** and selecting the subvolume with `-o subvol=…`. Fixed by resolving `findmnt -no SOURCE /` into `$DEVICE` and mounting `mount -o subvol=@data,… "$DEVICE" /data`; the fstab line now keys off that UUID. Also fixed a second latent bug: the `/data/cache` existence check ran `btrfs subvolume list /`, where a subvolume nested under `/data` is never listed as `@data/cache`, so the check could never match — it now lists `${MOUNT}` and matches `cache`. Added a hard `mountpoint -q /data` guard before creating anything inside it. |
| 2026-09-18 | Node initialization — registered `ubuntu-server-node-2` | Created node directory, captured hardware report, and documented the AMD/ROCm + btrfs-specific deviations from node1. ROCm install is scripted but **not yet run**; workload roles still to be defined. |