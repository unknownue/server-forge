# mac-mini-m4

Apple Silicon Mac mini (M4) — the fleet's macOS workstation/control node.

> This directory is deliberately named `mac-mini-m4` rather than after the machine's
> mDNS hostname. See [Hostname aliasing](#hostname-aliasing).

## Hardware

Full hardware report: [hardware-info.txt](hardware-info.txt)

| Item | Value |
|:---|:---|
| Model | Mac mini (Mac16,10) |
| Chip | Apple M4 — 10 cores (4P + 6E) |
| GPU | Integrated Apple M4, 10 cores, Metal 3 |
| Memory | 16 GB unified (soldered, not upgradeable) |
| Storage | 251 GB internal SSD (soldered) |
| Firmware | 11881.61.3 |

> Regenerate the report with
> `bash nodes/mac-mini-m4/provision/collect-hardware-info.sh > nodes/mac-mini-m4/hardware-info.txt`.
> The shared `scripts/lib/hardware-info.sh` is **Linux-only** (lscpu/free/dmidecode/lsblk/lspci)
> and yields nothing useful on Darwin — this node ships its own collector.

## Operating System

- OS: macOS 15.2 (Sequoia), build 24C101
- Kernel: Darwin 24.2.0 (arm64, RELEASE_ARM64_T8132)
- Shell: `/bin/zsh` (default)
- Hostname: `unknownue-servers-Mac-mini.local` (mDNS name; `scutil --get LocalHostName`
  returns `unknownue-servers-Mac-mini`). The node directory is named `mac-mini-m4` —
  see [Hostname aliasing](#hostname-aliasing).

### Hostname aliasing

`scripts/lib/discover.sh` derives the node directory from the machine's hostname.
On macOS there is no `/etc/hostname`, so it falls back to `hostname`, which returns the
full mDNS name `unknownue-servers-Mac-mini.local`. Rather than name this directory after
that string, the directory is `mac-mini-m4` and an alias file records the mapping:

```
nodes/mac-mini-m4/.hostname  ->  unknownue-servers-Mac-mini.local
```

When the direct `nodes/<hostname>` lookup fails, `discover.sh` scans `nodes/*/.hostname`
for a file whose first line matches the detected hostname and uses that directory instead.
So `source scripts/lib/discover.sh` still resolves correctly on this machine, and
`FORGE_NODE_HOSTNAME` keeps reporting the true hostname while `FORGE_NODE_DIR` points at
`nodes/mac-mini-m4/`.

This mechanism is generic — any node whose directory name differs from its hostname can
use it. If you rename the Mac (System Settings → General → Sharing), update the first line
of `.hostname` to match the new hostname.

### Storage layout

| Volume | Size | Mount point | Content |
|:---|:---|:---|:---|
| Macintosh HD (snapshot) | 11.2 GB | `/` | Sealed read-only system volume |
| Data | 127.7 GB | `/System/Volumes/Data` | User data, applications, `/Users` |
| Preboot | 6.9 GB | `/System/Volumes/Preboot` | Boot artifacts |
| VM | 1.1 GB | `/System/Volumes/VM` | Swap / sleep image |
| Recovery | 2.0 GB | — | RecoveryOS |

- APFS container `disk3`: 245.1 GB, ~96 GB not allocated (free space pool).
- Free space: ~90 GiB available. Both the SSD and RAM are soldered —
  **neither is upgradeable**; bulk data must go to external Thunderbolt/USB storage.

## Networking

- Wi-Fi (`en1`): **192.168.50.248** — the active interface and default route (gateway `192.168.50.1`).
- Ethernet (`en0`): MAC `d0:11:e5:b6:07:f8`, DHCP enabled but no link currently.
- `en5`–`en8` are Thunderbolt/USB-adjacent adapters, also DHCP with no active lease.
- The machine sits on the same `192.168.50.0/24` subnet as `ubuntu-server-node-2`.

## Roles

- `workstation` — primary development machine; hosts this repo and DSH.
- `control` — orchestration/entry point for the rest of the fleet.
- `macos-native-compute` — light local inference via Metal/MPS/MLX only.

**Not a compute node.** The integrated GPU has no CUDA/ROCm, so the GPU-heavy nodes
(`ubuntu26-node1-server`, `ubuntu-server-node-2`, `unknownue-manjaro`) carry all
model-serving workloads.

## Provisioning Log

### 1. OS Installation

Pre-installed macOS 15.2; no reinstall performed. This node was registered into the
fleet after the fact, using `unknownue-manjaro` as the structural template.

### 2. Package Manager

Homebrew at `/opt/homebrew` (Apple Silicon prefix). Wired into the shell via
`/Users/unknownue/.zprofile`:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
```

```bash
bash nodes/mac-mini-m4/provision/install-packages.sh
```

### 3. Git Identity

```bash
bash nodes/mac-mini-m4/config/set-git-config.sh "unknownue" "unknownue@outlook.com"
```

### 4. Docker

Docker Desktop (`/Applications/Docker.app`, engine 27.5.1, overlayfs) provides the
`desktop-linux` context over `unix:///Users/unknownue/.docker/run/docker.sock`.

> Unlike the Linux nodes, Docker Desktop runs containers inside a **Linux VM** and
> `$HOME` inside containers is **not** this Mac's home directory. Bind mounts must use
> paths under `/Users/...`, and the `--user $(id -u):$(id -g)` / ACL patterns from
> CLAUDE.md do not map cleanly onto Docker Desktop's VM boundary. Prefer named volumes
> or explicit `-v /Users/unknownue/...:/path` mounts; file ownership is normalized by
> the VirtioFS/gRPC-FUSE layer rather than by host UID.

### 5. `uv` (Python)

`uv` 0.10.8 is installed via Homebrew and is the preferred Python runner here
(`python3` is the system Python 3.9.6). Use `uv run` / `uv tool` instead of `pip install`.

## Directory Structure

```
mac-mini-m4/
├── README.md
├── hardware-info.txt
├── .hostname            # hostname -> this directory alias (see Hostname aliasing)
├── config/
│   └── set-git-config.sh
└── provision/
    ├── install-packages.sh
    └── collect-hardware-info.sh
```

## Installed Tooling

| Tool | Version | Source |
|:---|:---|:---|
| Homebrew | 6.0.12 | `/opt/homebrew` |
| git | 2.39.5 | Apple Git |
| node | v25.9.0 | Homebrew |
| npm | 11.12.1 | Homebrew |
| uv | 0.10.8 | Homebrew |
| Docker | 27.5.1 | Docker Desktop |
| rustup | — | Homebrew |
| ripgrep | 15.1.0 | Homebrew |
| jq | 1.6 | Apple |
| make | GNU Make 3.81 | Apple |
| direnv | — | Homebrew (hooked in `.zshrc`) |
| minio | — | Homebrew |
| ffmpeg | — | Homebrew |

Selected casks: `docker-desktop`, `claude-code`, `google-chrome`, `warp`, `zed`,
`localsend`, `switchhosts`, `uuremote`.

## macOS-Specific Pitfalls

| Pitfall | Detail |
|:---|:---|
| `scripts/lib/hardware-info.sh` / `storage-info.sh` are Linux-only | Both rely on `lscpu`, `free`, `lsblk`, `pvs`/`vgs`/`lvs`. On macOS they print "not available" or fail under `set -eu`. Use this node's `collect-hardware-info.sh` instead. |
| `/etc/hostname` absent | `discover.sh`'s first probe fails; the `hostname` fallback returns the mDNS name including the `.local` suffix. Handled by the `.hostname` alias file (see [Hostname aliasing](#hostname-aliasing)). |
| Hostname may change | `hostname` reflects the mDNS name; renaming the Mac in System Settings → General → Sharing changes it and would break `discover.sh` until `.hostname` is updated to the new hostname. |
| `sudo` semantics differ | macOS has no `require_root`-friendly Bash 4 by default — `/bin/bash` is 3.2. Scripts using `declare -A` or `${var,,}` fail. Homebrew's `bash` (5.x) is installed but not the default `#!/bin/bash`. |
| APFS is case-insensitive | Paths differing only in case collide; be careful with node directory names. |
| System volume is sealed | `/` is a read-only snapshot. Nothing can be persisted there — config must live under `/Users` or `~/Library`. |
| No `/data` tier | The two-tier `/data/work` + `/data/cache` layout from CLAUDE.md does not apply: there is no dedicated volume, and the internal SSD is soldered. |

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-05-24 | Node initialization | Created `nodes/mac-mini-m4/` using `unknownue-manjaro` as template. Added macOS-native `collect-hardware-info.sh` (shared collector is Linux-only), generated `hardware-info.txt`, wrote this README, and registered the node in `inventory/hosts.yml`. |