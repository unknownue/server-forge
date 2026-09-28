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

- `compute` — runs GPU inference/training workloads via Docker + NVIDIA Container Toolkit
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
| 2026-09-28 | Service Hub 的 profile 列表看不到服务端口，必须展开 Details 才知道该连哪个口 | `ProfileInfo` 增加 `ports` 字段（`server.py` 从每个 allocation 的 `port` 去重排序生成），前端 `ProfileList.vue` 在列表行渲染 `:8010` 形式端口标签（`style.css` 新增 `.tag.port` 等宽绿标），并执行 `cd service-hub/frontend && npm run build` 重新生成 `static/`（新 bundle `index-ronVA72F.js` / `index-D5QkMAGh.css`）。重启 hub 后 `/api/profiles` 已对 13 个 profile 全部返回 ports（如 `mimo26-flash-8c-1m-lan` → `[8010]`、`dsv41-flash-3c-620k-lan` → `[8010]`、`web-server-default` → `[8000,8001,8002,8003,8090]`）。前端构建方式与 `uv` 的 PATH 依赖已补进 `service-hub/README.md`。 |
| 2026-09-28 | MiMo 端口与 DS 不一致（MiMo 8020 / DS 8010），LAN 客户端切换模型时还要改 baseURL | 统一到 **8010**：`serve/mimo26-flash.sh` 默认 `MIMO26_PORT=8010`，profile 的 `port` 与描述同步更新。经 hub 强制重切验证（`?force=true`，118.5 s，stopped+started `mimo26-flash`）：`ss` 仅 `0.0.0.0:8010`、旧端口 8020 已关闭（curl 000）、经 LAN IP 的 `/health` 200 与 `/v1/chat/completions` 返回 `PORT OK`、无 key 401、池仍为 10,877,194 token。两者互斥运行，故共用端口无冲突；客户端固定 `http://<host>:8010/v1`，只换 model 名。 |
| 2026-09-28 | 把 MiMo 接入 Service Hub 并从 hub 启动、暴露到局域网 | 新增 profile `mimo26-flash-8c-1m-lan`（TP4、8 槽、1M 上下文、`0.0.0.0:8020`），启动器默认 `util 0.95`（池 10,877,194 token）。实测 `POST /api/switch/mimo26-flash-8c-1m-lan` → 200、121.7 s、`started_containers=["mimo26-flash"]`、`/api/current` 显示 active；`ss` 确认 `0.0.0.0:8020`，经 LAN IP 调用 `/health` 与 `/v1/chat/completions` 均成功（返回 `LAN OK`），不带 API key 返回 401。**踩坑**：`service-hub/deploy.sh` 依赖 `uv`，而 `uv` 装在 `~/.local/bin`，非登录 shell 的 PATH 里没有 → 需 `PATH="$HOME/.local/bin:$PATH" bash service-hub/deploy.sh`，否则报 `ERROR: 'uv' not found`。 |
| 2026-09-28 | MiMo 容量/速度两个杠杆单独验收：`--max-num-batched-tokens` 4096→16384，以及引擎建议的 `--kv-cache-memory=40607249408`（37.82 GiB，号称跑满显存） | 结论：① 16384 使 1M 预填 1,713→**1,906 tok/s（+11%）**、46K 预填 +6%，但激活显存吃掉 KV，池 **10.88M→8.35M（−23%）**；② 37.82 GiB **起不来**——`--kv-cache-memory` 会跳过显存画像，cudagraph/激活没位置，启动即 `CUDA out of memory ... 6.12 MiB is free`；③ 降到 36.0 GiB 可启动（池 11,264,034、1M 预填峰值余 1.4 GiB），④ 更安全的等效档是 `util 0.97`（池 **11,396,895**、1M 预填峰值余 ~1.05 GiB）。默认仍保持 `util 0.95`（池 10,877,194、余量 2.9 GiB），0.97 与 16384 作为 `MIMO26_UTIL=0.97` / `MIMO26_MAX_BATCHED=16384` 可选档；三档均通过 1M 冷预填验收。详见 `bench/RESULTS-MIMO26-FLASH.md`。 |
| 2026-09-28 | MiMo-V2.6-Flash 的显存没跑满：`--gpu-memory-utilization 0.90` 时每卡闲 6.9–7.4 GiB（约占 8.6%），KV 池 9,577,937 token；同一批测试里单流解码在 207–359 tok/s 之间波动，起初疑似与显存设置有关 | 提到 0.95 实测：池 **10,877,194 token（+13.6%）**、KV 34.76 GiB/卡、每卡用 82,496 MiB，1M 冷预填仍通过（981,754 token 提示、TTFT 573 s、峰值 82,784 MiB、无 OOM）。A/B 复测（0.90 → 233.3 tok/s，0.95 → 207–242 tok/s）证明解码波动来自 DFlash 投机接受率（1.47–1.57 accepted/step），不是显存设置。默认档改为 0.95，0.90 作为保守档保留；引擎建议的绝对上限 `--kv-cache-memory=40607249408`（37.82 GiB，约 11.8M token）只剩 <1 GiB 余量，不设为默认。 |
| 2026-09-28 | 部署并实测 MiMo-V2.6-Flash-RL（309B 总参 / 15B 激活，MXFP4 专家 + FP8 稠密，1M 上下文，全模态）。本机是 SM120（RTX 6000D），官方 SGLang 路线的 `fa4` + `DeepGEMM` 均不支持该架构（sglang#25877），官方 vLLM 稳定版也无法加载 MXFP4 存储格式 | 采用面向 RTX PRO 6000 Blackwell 的社区 SM120 配方（Diffbot：FP8 KV + Marlin W4A8 + Triton DiffKV 补丁 + 自研全局层预填 CUDA kernel）。镜像经 `docker.m.daocloud.io` 拉取 day-0 `vllm/vllm-openai:mimo-v26-x86_64-cu130` 并构建 `mimo-v26-omni:latest`（Hub 直连与本机 `docker.1ms.run` 均不可用）；权重经 hf-mirror 下载到 `/data/work/models/XiaomiMiMo/MiMo-V2.6-Flash-RL`（177.8 GB，revision 钉住），配方 vendored 至 `/data/work/vendor/diffbot-mimo26-recipe`。新增 `serve/mimo26-flash.sh` + `profiles/mimo26-flash-8c-1m-lan.yaml`。实测 KV 池 **9,577,937 token**（1M 请求可并发 9.13×，是 DeepSeek-V4.1-Flash 1,953,792 的 4.9×）；1M 请求 TTFT 566.7 s、解码 149.1 tok/s；46K 预填 7,319 tok/s（C=1）/ 15,060 tok/s（C=4）；29K needle 命中、工具调用通过、4×200K 并发 4/4 无 OOM。宿主不再需要 189 GiB 锁定内存，改作 64 GiB CPU KV 层。详见 `bench/RESULTS-MIMO26-FLASH.md`。 |
| 2026-09-28 | `serve/mimo26-flash.sh` 首版使用 `--network host` 却把 vLLM `--host` 写死成 0.0.0.0，传 `127.0.0.1` 时端点仍暴露在 LAN（本机无防火墙，API key 是唯一认证） | 监听地址改为跟随 `BIND` 参数（`127.0.0.1` → 仅本机，其他值 → 0.0.0.0）。重启后 `ss -tlnp` 确认仅 `127.0.0.1:8020`，从 LAN IP 请求失败（curl exit 7）。 |
| 2026-08-30 | nanochat 训练容器移除后, 命名卷 `nanochat-cache` 里的 checkpoint 对 host 不透明、不便管理, 且不符合 /data 分层约定 | 按 CLAUDE.md 新增的 "Training Checkpoints" 规则迁移: 训练产物 → `/data/work/checkpoints/nanochat/` (d24_4gpu step-5568 base checkpoint + 4 rank 优化器状态、d12_smoke、tokenizer、eval_bundle/评估结果、climbmax 分片), 可丢弃内核缓存 → `/data/cache/nanochat/` (triton/torchinductor)。逐文件 md5/大小/总字节数 (13,861,838,747 B) 校验一致后移除命名卷; nanochat 仓库 Dockerfile / `runs/docker_train.sh` 注释更新为 bind mount + `--user` + TRITON/TORCHINDUCTOR_CACHE_DIR 覆盖, 并补了 `/data/work/checkpoints/nanochat/.training_meta` 溯源文件。 |
| 2026-08-28 | Boot issue: after normal `systemctl poweroff`, next power-on gives no display (board fans/LEDs run, monitor black); recovers only after full power drain (unplug AC + long-press power). Root cause: console display is provided solely by the GT 1030 (`52:00.0`, `simple-framebuffer`, no native driver), which depends entirely on BIOS GOP init; the 4× RTX 6000D Blackwell cards have a known warm-reboot (S5) re-init issue, so on warm boot the BIOS fails to bring up the display GPU. Matches known NVIDIA Blackwell issue (display only after PSU power cycle). | Under investigation. Recommended: (1) BIOS → set Initial Display Output / Primary Display = GT 1030 slot (not Auto); (2) disable Fast Boot; (3) enable ErP (S4+S5) so shutdown cuts standby power; (4) update Gigabyte W790 AI TOP BIOS beyond F9a and check NVIDIA VBIOS/driver update for RTX 6000D. Refs: NVIDIA forum threads 370968, 343984, 338585. |
| 2026-08-22 | Qwen3.8-27B-NVFP4 (DSPARK) 4-GPU (TP=4) deployment benchmark: 579 tok/s (vs 475 TP=2, 337 TP=1), 262K verified context, unlocks 524K with `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1`. Found TP=4 requires `--mem-fraction-static 0.80`: at 0.85 the prefill CUDA graph is auto-disabled (headroom 2.3 GiB < 4 GiB gate → 376 tok/s, 411 ms TTFT) and verify-graph capture **stalls ~20 min** at boot with max-bs 32; at 0.80 (2.9 GiB/GPU headroom, full graph capture, ~150 s boot) 3× DSH-shaped load is stable. CustomAllreduce auto-disabled on 4 PCIe-only GPUs caps scaling at ~1.22× | Added hub profile `qwen38-dspark-4gpu` (TP=4, 262K, 0.80/8, ~579 tok/s) and documented the TP=4 matrix in `bench/RESULTS.md`. `serve/sglang-qwen38-dspark.sh` now auto-adds `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` when ctx > 262144. |
| 2026-08-20 | Service Hub `qwen38-dspark-2gpu` (f0.85) intermittent: DSH messages → 500 → "Connection error"; idle GPU0 headroom only 0.7–2.6 GiB (boot-dependent), DSH-sized request OOM'd rank 0 (`torch.OutOfMemoryError` in scheduler: 16 MiB alloc, 11 MiB free) | Lowered to `--mem-fraction-static 0.80` + `--cuda-graph-max-bs 32` (TP=2) → ~7 GiB/GPU headroom; verified 227K-token ladder + 3× DSH-shaped load. Also mounted persistent kernel cache `/data/cache/sglang_qwen38` (SGLANG/TRITON/flashinfer), cutting switch boot time from ~147s to ~90–110s so the "Connection error during boot window" failure mode shrinks too. |
| 2026-08-20 | DeepSeek Harness + local SGLang Qwen3.8: `<think>` reasoning rendered as plain text, and the reply stopped right after a `<tool_call>` instead of executing the tool | Root cause: SGLang was launched without `--reasoning-parser`/`--tool-call-parser`, so it streamed `<think>…</think>` and `<tool_call>…</tool_call>` as raw text in `content` (`reasoning_content` stayed `null`, finish_reason stayed `stop`). Fixed `serve/sglang-qwen38-dspark.sh` to add `--reasoning-parser qwen3` + `--tool-call-parser qwen3_coder`; requires a container restart to take effect. |
| 2026-08-19 | Service Hub: clicking switch twice (or after a Stop) raced — the second request's stop phase killed the first's in-flight container boot, and the hub recorded "success" for a profile that never came up | Added a switch/stop serialization lock (concurrent requests get 409/"already in progress"), serve-script failures now return status error/partial with the script's stderr, history records "failed", and the frontend toasts reflect the real status. Serve script errors now go to stderr. |
| 2026-08-19 | Qwen3.8-27B-NVFP4 (DSPARK) served with `--context-length 262144 --mem-fraction-static 0.95 --mamba-full-memory-ratio 11.93` (TP=1): every DeepSeek Harness message returned "Connection error" | Root cause: idle VRAM 84414/85651 MiB (1.2 GiB free); DSH-sized requests OOM the scheduler → 500 → server dies → DSH retries hit the dead port. Full sweep in `bench/RESULTS.md`. Now managed by Service Hub via `qwen38-dspark-1gpu` (131K ctx, 0.85/8, ~337 tok/s, 4.9 GiB headroom, GPU 0) and `qwen38-dspark-2gpu` (~227K+ ctx, 0.80/8, ~475 tok/s, GPU 0+1, NCCL_P2P_DISABLE=1). Ad-hoc container removed. |
| 2026-05-24 | SGLang/vLLM TP=2 hang on RTX 6000 Blackwell (GPU 100%, NCCL deadlock) | Root cause: IOMMU DMA remapping. Fix: `iommu=off` + `uvm_disable_hmm=1`. |
| | Initial setup | |
