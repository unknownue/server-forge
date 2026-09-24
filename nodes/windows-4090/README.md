# windows-4090

Windows 11 Pro workstation — Ryzen 7 9800X3D + RTX 4090, the fleet's Windows development node.

> This directory is deliberately named `windows-4090` rather than after the machine's
> OEM hostname `SK-20260811BZVK`. See [Hostname aliasing](#hostname-aliasing).

## Hostname aliasing

`scripts/lib/discover.sh` derives the node directory from the machine's hostname,
which here is the vendor-generated `SK-20260811BZVK`. Rather than name this
directory after that string, the directory is `windows-4090` and an alias file
records the mapping:

```
nodes/windows-4090/.hostname  ->  SK-20260811BZVK
```

When the direct `nodes/<hostname>` lookup fails, `discover.sh` scans
`nodes/*/.hostname` for a file whose first line matches the detected hostname
and uses that directory instead.

## Hardware
Full hardware report: [hardware-info.txt](hardware-info.txt)

- CPU: AMD Ryzen 7 9800X3D, 8 cores / 8 threads (SMT disabled), AM5
- RAM: 32 GiB (2x 16 GB DDR5-6000)
- Motherboard: Gigabyte B850I AORUS PRO (mini-ITX), BIOS FA8
- dGPU: NVIDIA GeForce RTX 4090 (24564 MiB)
- Storage: 1 TB Predator GM7 NVMe (single drive)

## Operating System
- OS: Microsoft Windows 11 Pro, build 22631 (23H2)
- Installed: 2026-08-11
- Volume layout:

| Volume | Size | FS | Content |
|:---|:---|:---|:---|
| `C:` | 200 GB | NTFS | Windows system |
| `D:` | 754 GB | NTFS | Data — hosts this repository |

## Driver Configuration

- dGPU: NVIDIA 591.86 (proprietary, Windows)
- iGPU: AMD Radeon Graphics 32.0.21025.10016
- Single dGPU setup — no heterogeneous display/compute split configured.

## Roles

- `workstation` — Windows development machine; runs this project (via Git Bash) and local dev workloads

## Environment

- Git Bash (MSYS2) — primary shell for working with this repository
- PowerShell 5.1
- Scoop package manager (git 2.55.0 installed via Scoop)
- Toolchain: Python 3.14.7, Node v26.7.0 / npm 11.19.0, clang 22.1.8, GNU Make 4.4.1
- Docker: not installed

## Known Quirks

- WMI reports 8 threads (SMT disabled) on the 9800X3D, which is 8C/16T stock.
- `Win32_VideoController.AdapterRAM` reports 4 GB for the RTX 4090 — a 32-bit
  truncation quirk; the real 24564 MiB comes from `nvidia-smi`.
- A "GameViewer Virtual Display Adapter" is installed (virtual display software).

## Provisioning Log

### 1. OS Installation
- Windows 11 Pro preinstalled by the vendor; first boot 2026-08-11.

### 2. Node Initialization
- Initialized as `nodes/SK-20260811BZVK/` with hardware report and this README (2026-09-24).
- Hardware report collected via `collect-hwinfo.ps1` (WMI/CIM + `nvidia-smi`),
  because `scripts/lib/hardware-info.sh` relies on Linux tools. Re-run it any
  time to refresh `hardware-info.txt`.

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-09-24 | Node initialization | Created node directory, hardware report, and README |
| 2026-09-24 | Directory renamed to `windows-4090` | Added `.hostname` alias (`SK-20260811BZVK`); updated `inventory/hosts.yml` |
