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
- Display GPU: `nouveau` (in-kernel, loaded early via initramfs)
- GRUB params: `nvidia-drm.modeset=1 nvidia-drm.fbdev=1 iommu=off`

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

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-05-24 | SGLang/vLLM TP=2 hang on RTX 6000 Blackwell (GPU 100%, NCCL deadlock) | Root cause: IOMMU DMA remapping. Fix: `iommu=off` + `uvm_disable_hmm=1`. |
| | Initial setup | |
