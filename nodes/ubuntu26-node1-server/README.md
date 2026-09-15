# ubuntu26-node1-server

## Hardware
Full hardware report: [hardware-info.txt](hardware-info.txt)

## Operating System
- OS: Ubuntu Server 26.04 LTS
- Kernel: 7.0.0-15-generic (x86_64)
- Partition layout:

| Mount point | Size | FS | Source |
|:---|:---|:---|:---|
| `/boot/efi` | 1G | vfat | nvme0n1p1 |
| `/boot` | 2G | ext4 | nvme0n1p2 |
| `/` | 200G | ext4 | LVM LV on nvme0n1p3 (1.8T PV) |

- The 200G `/` holds only the OS, drivers, and this project.
- VG free space: ~1.6T — reserved for reproducible data volumes (see below).

## Data Volume Strategy

All content on unallocated space is **ephemeral and reproducible** — it can be
rebuilt by re-running the configuration code maintained in this project.

First, allocate the space: `sudo bash nodes/ubuntu26-node1-server/provision/allocate-storage.sh`

| LV | Mount point | Size | Content |
|:---|:---|:---|:---|
| `data-lv` | `/data` | 1.37T | Docker images, GitHub repos, databases, LLM models, datasets |
| *(headroom)* | — | 260G | Reserved for online expansion |

| Content | Provisioned By | Notes |
|:---|:---|:---|
| GitHub repositories | `git clone` scripts | List of repos in project config |
| Docker images | Dockerfile / `docker pull` | Defined in project, pulled at provisioning |
| Database files | Migration scripts + seed data | Schema and seed scripts version-controlled |
| LLM models | `huggingface_hub` / `modelscope` | Model list and download scripts in project |

The IaC principle: **only configuration code is backed up; all data is rebuildable**.

## Driver Configuration

- Compute GPUs: `nvidia-driver-595-server-open` (open kernel modules)
- Display GPU: GT 1030 (`52:00.0`) — **no native driver bound**: nvidia 595 dropped Pascal
  (GP108) support and nouveau is blacklisted by the distro nvidia package, so the GT 1030
  renders via `simple-framebuffer` (BIOS-provided framebuffer, `card0`/`fb0`). The console
  display therefore depends entirely on the BIOS initializing the GT 1030's GOP at POST.
- GRUB params (current): `iommu=off amd_iommu=off`

### IOMMU / NCCL Multi-GPU Fix

**Problem**: IOMMU DMA remapping causes NCCL P2P deadlock on RTX 6000 Blackwell + PCIe + TP>=2.
GPUs hang at 100% utilization (~95W, no VRAM growth) and require reset/reboot to recover.
NCCL stress tests pass, but inference (SGLang, vLLM) deadlocks due to CUDA stream + NCCL
interleaving under IOMMU DMA translation.

**Fix** (both required):

1. Disable IOMMU — add `iommu=off` to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, run `update-grub`, reboot.
2. nvidia_uvm module — `echo "options nvidia_uvm uvm_disable_hmm=1" > /etc/modprobe.d/uvm.conf`, reload or reboot.

Reference: [Level1Techs P2P NCCL Fix](https://forum.level1techs.com/t/dual-rtx-pro-6000-blackwell-max-q-how-to-make-p2p-nccl-work/242403/8)

## Roles

- `compute` — runs AI training workloads via Docker + NVIDIA Container Toolkit
- `display-mixed` — heterogeneous GPU setup (compute + display)

## Related Projects

- [rtx6kpro](https://github.com/local-inference-lab/rtx6kpro) — RTX 6000 Pro Blackwell GPU tooling and reference

## Provisioning Log

### 1. OS Installation
- Ubuntu Server 26.04 LTS live-server ISO
- Partition: `/` 200G ext4, others default; no network during install
- Reboot and log in after completion

### 2. Network Setup

Connect Ethernet:
```bash
ip a
sudo dhcpcd enp14s0f1np1
```

WiFi (if needed):
```bash
wpa_passphrase "<SSID>" "<password>" | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf
sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
sudo dhcpcd wlan0
```

After network is working, disable systemd-networkd-wait-online (it waits for networkd-managed
interfaces which don't exist under the wpa_supplicant+dhcpcd setup, causing a 2-minute boot delay):
```bash
sudo systemctl disable systemd-networkd-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
```

### 3. Mirror Setup
```bash
curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
sudo bash ChangeMirrors.sh --lang en-us
rm ChangeMirrors.sh
```

### 4. System Packages
```bash
sudo bash nodes/ubuntu26-node1-server/provision/install-packages.sh
# Currently installs: git
# Append new dependencies to install-packages.sh as needed.
```

```bash
bash nodes/ubuntu26-node1-server/config/set-git-config.sh "unknownue" "unknownue@outlook.com"
```

### 5. GPU Driver
```bash
sudo ubuntu-drivers list
sudo ubuntu-drivers install nvidia-driver-595-server-open
# Multi-GPU NCCL fix (required for TP>=2):
echo "options nvidia_uvm uvm_disable_hmm=1" | sudo tee /etc/modprobe.d/uvm.conf
```

### 6. Docker
```bash
sudo bash nodes/ubuntu26-node1-server/provision/install-docker.sh [registry-mirror]
# e.g. sudo bash nodes/ubuntu26-node1-server/provision/install-docker.sh registry.cn-hangzhou.aliyuncs.com
# Configures data-root=/data/docker, optional registry-mirrors.
```

### 7. NVIDIA Container Toolkit
```bash
bash nodes/ubuntu26-node1-server/provision/download-nvidia-ctk-debs.sh
sudo bash nodes/ubuntu26-node1-server/provision/install-nvidia-ctk.sh
```

### 8. Desktop Environment
```bash
sudo apt install ubuntu-desktop-minimal -y
sudo reboot
```

### 9. GPU Assignment (post-reboot)

Ensure GT 1030 is the primary display device:
```bash
sudo apt install mesa-utils -y
glxinfo | egrep "OpenGL vendor|OpenGL renderer"
sudo tee /etc/udev/rules.d/61-mutter-primary-gpu.rules << 'EOF'
ENV{DEVNAME}=="/dev/dri/card0", TAG+="mutter-device-preferred-primary"
EOF
```

## Directory Structure

```
ubuntu26-node1-server/
├── README.md, hardware-info.txt, download-model.sh, pull-images.sh
├── config/              # Node-level config (models.conf, git, docker registry)
├── provision/           # OS provisioning scripts (one-shot, root)
├── bench/               # Benchmark scripts and results
│
├── images/              # Docker image build contexts
│   ├── sglang/          #   SGLang patches (Anthropic API support)
│   ├── anthropic-proxy/ #   Anthropic↔OpenAI translation proxy
│   └── sglang/          #   SGLang patches (Anthropic API support)
│
├── profiles/            # GPU card allocation profiles (one YAML = one config)
│   ├── game-server-*.yaml    #   Game Studio (3 text + image gen)
│   ├── web-server-*.yaml     #   Web Studio (4 text)
│   ├── unsloth.yaml          #   Unsloth Studio (all GPUs, training)
│   └── docs/                 #   Preserved documentation from old directories
│
├── serve/               # Unified service launch scripts
│   ├── sglang-text.sh   #   Start SGLang text inference (Dense/MoE)
│   ├── sglang-vl.sh     #   Start SGLang Vision-Language model
│   ├── comfyui.sh       #   Start ComfyUI image generation
│   └── clasp-proxy.sh   #   Start CLASP Anthropic proxy
│
├── unsloth/             # Unsloth Studio (independent Dockerfile + patches)
│
└── service-hub/         # Local service management gateway
    ├── pyproject.toml   #   uv project definition
    ├── deploy.sh        #   Start the management service
    └── src/service_hub/ #   FastAPI server + GPU monitor + profile executor
```

## Service Hub

The Service Hub is the local service management gateway — the single HTTP entry
point for querying GPU card status and switching between pre-defined service
profiles on this machine.

### Quick Start

```bash
# Install uv if not already installed
curl -LsSf https://astral.sh/uv/install.sh | sh

# Start the service (from repo root)
make service-hub

# API docs: http://localhost:9090/docs
```

### API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/gpus` | Query all GPU cards with real-time status |
| `GET` | `/gpus/{id}` | Query a single GPU |
| `GET` | `/profiles` | List all available profiles |
| `GET` | `/profiles/{name}` | View profile details |
| `GET` | `/current` | Current active profile |
| `POST` | `/switch/{name}` | Switch to a profile (stops old, starts new) |
| `POST` | `/stop` | Stop all managed containers |
| `GET` | `/health` | Management service health check |

### Example: Switch Profile

```bash
# Switch to Game Studio
curl -X POST http://localhost:9090/switch/game-server-default

# Query GPU status
curl http://localhost:9090/gpus | python3 -m json.tool
```

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-08-30 | nanochat 训练容器移除后, 命名卷 `nanochat-cache` 里的 checkpoint 对 host 不透明、不便管理, 且不符合 /data 分层约定 | 按 CLAUDE.md 新增的 "Training Checkpoints" 规则迁移: 训练产物 → `/data/work/checkpoints/nanochat/` (d24_4gpu step-5568 base checkpoint + 4 rank 优化器状态、d12_smoke、tokenizer、eval_bundle/评估结果、climbmax 分片), 可丢弃内核缓存 → `/data/cache/nanochat/` (triton/torchinductor)。逐文件 md5/大小/总字节数 (13,861,838,747 B) 校验一致后移除命名卷; nanochat 仓库 Dockerfile / `runs/docker_train.sh` 注释更新为 bind mount + `--user` + TRITON/TORCHINDUCTOR_CACHE_DIR 覆盖, 并补了 `/data/work/checkpoints/nanochat/.training_meta` 溯源文件。 |
| 2026-08-28 | Boot issue: after normal `systemctl poweroff`, next power-on gives no display (board fans/LEDs run, monitor black); recovers only after full power drain (unplug AC + long-press power). Root cause: console display is provided solely by the GT 1030 (`52:00.0`, `simple-framebuffer`, no native driver), which depends entirely on BIOS GOP init; the 4× RTX 6000D Blackwell cards have a known warm-reboot (S5) re-init issue, so on warm boot the BIOS fails to bring up the display GPU. Matches known NVIDIA Blackwell issue (display only after PSU power cycle). | Under investigation. Recommended: (1) BIOS → set Initial Display Output / Primary Display = GT 1030 slot (not Auto); (2) disable Fast Boot; (3) enable ErP (S4+S5) so shutdown cuts standby power; (4) update Gigabyte W790 AI TOP BIOS beyond F9a and check NVIDIA VBIOS/driver update for RTX 6000D. Refs: NVIDIA forum threads 370968, 343984, 338585. |
| 2026-08-22 | Qwen3.8-27B-NVFP4 (DSPARK) 4-GPU (TP=4) deployment benchmark: 579 tok/s (vs 475 TP=2, 337 TP=1), 262K verified context, unlocks 524K with `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1`. Found TP=4 requires `--mem-fraction-static 0.80`: at 0.85 the prefill CUDA graph is auto-disabled (headroom 2.3 GiB < 4 GiB gate → 376 tok/s, 411 ms TTFT) and verify-graph capture **stalls ~20 min** at boot with max-bs 32; at 0.80 (2.9 GiB/GPU headroom, full graph capture, ~150 s boot) 3× DSH-shaped load is stable. CustomAllreduce auto-disabled on 4 PCIe-only GPUs caps scaling at ~1.22× | Added hub profile `qwen38-dspark-4gpu` (TP=4, 262K, 0.80/8, ~579 tok/s) and documented the TP=4 matrix in `bench/RESULTS.md`. `serve/sglang-qwen38-dspark.sh` now auto-adds `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` when ctx > 262144. |
| 2026-08-20 | Service Hub `qwen38-dspark-2gpu` (f0.85) intermittent: DSH messages → 500 → "Connection error"; idle GPU0 headroom only 0.7–2.6 GiB (boot-dependent), DSH-sized request OOM'd rank 0 (`torch.OutOfMemoryError` in scheduler: 16 MiB alloc, 11 MiB free) | Lowered to `--mem-fraction-static 0.80` + `--cuda-graph-max-bs 32` (TP=2) → ~7 GiB/GPU headroom; verified 227K-token ladder + 3× DSH-shaped load. Also mounted persistent kernel cache `/data/cache/sglang_qwen38` (SGLANG/TRITON/flashinfer), cutting switch boot time from ~147s to ~90–110s so the "Connection error during boot window" failure mode shrinks too. |
| 2026-08-20 | DeepSeek Harness + local SGLang Qwen3.8: `<think>` reasoning rendered as plain text, and the reply stopped right after a `<tool_call>` instead of executing the tool | Root cause: SGLang was launched without `--reasoning-parser`/`--tool-call-parser`, so it streamed `<think>…</think>` and `<tool_call>…</tool_call>` as raw text in `content` (`reasoning_content` stayed `null`, finish_reason stayed `stop`). Fixed `serve/sglang-qwen38-dspark.sh` to add `--reasoning-parser qwen3` + `--tool-call-parser qwen3_coder`; requires a container restart to take effect. |
| 2026-08-19 | Service Hub: clicking switch twice (or after a Stop) raced — the second request's stop phase killed the first's in-flight container boot, and the hub recorded "success" for a profile that never came up | Added a switch/stop serialization lock (concurrent requests get 409/"already in progress"), serve-script failures now return status error/partial with the script's stderr, history records "failed", and the frontend toasts reflect the real status. Serve script errors now go to stderr. |
| 2026-08-19 | Qwen3.8-27B-NVFP4 (DSPARK) served with `--context-length 262144 --mem-fraction-static 0.95 --mamba-full-memory-ratio 11.93` (TP=1): every DeepSeek Harness message returned "Connection error" | Root cause: idle VRAM 84414/85651 MiB (1.2 GiB free); DSH-sized requests OOM the scheduler → 500 → server dies → DSH retries hit the dead port. Full sweep in `bench/RESULTS.md`. Now managed by Service Hub via `qwen38-dspark-1gpu` (131K ctx, 0.85/8, ~337 tok/s, 4.9 GiB headroom, GPU 0) and `qwen38-dspark-2gpu` (~227K+ ctx, 0.80/8, ~475 tok/s, GPU 0+1, NCCL_P2P_DISABLE=1). Ad-hoc container removed. |
| 2026-05-24 | SGLang/vLLM TP=2 hang on RTX 6000 Blackwell (GPU 100%, NCCL deadlock) | Root cause: IOMMU DMA remapping. Fix: `iommu=off` + `uvm_disable_hmm=1`. |
| | Initial setup | |
