# unknownue-manjaro

## Hardware
Full hardware report: [hardware-info.txt](hardware-info.txt)

## Operating System
- OS: Manjaro Linux (rolling)
- Kernel: 6.12.77-1-MANJARO (x86_64)
- Partition layout:

| Mount point | Size | FS | Source |
|:---|:---|:---|:---|
| `/boot/efi` | 300M | vfat | nvme0n1p1 |
| `/` | 477G | xfs | nvme0n1p2 |

- Other drives (sda, sdb, sdc, nvme1n1) are NTFS-formatted and not mounted by default.

## Driver Configuration

- GPU: `nvidia` 590.48.01 (proprietary)
- Single GPU setup — no heterogeneous display/compute split needed.

## Roles

- `workstation` — development machine, runs this project and other dev workloads
- `compute` — capable of single-GPU AI inference/training workloads via RTX 4090

## Provisioning Log

### 1. OS Installation
- Manjaro Linux, installed to nvme0n1 with XFS root.

### 2. System Packages
- Installed via `pacman` / `pamac`.

### 3. GPU Driver
- NVIDIA proprietary driver 590.48.01 via Manjaro's driver manager.

### 4. Docker
```bash
# Manjaro uses podman by default; install docker if needed:
sudo pacman -S docker docker-buildx
sudo systemctl enable --now docker
```

### 5. NVIDIA Container Toolkit
```bash
# On Arch/Manjaro, available from AUR:
# nvidia-container-toolkit
```

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-05-24 | Node initialization | Created node directory, hardware report, and README |
