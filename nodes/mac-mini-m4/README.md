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
- `always-on-service` — hosts the Multica self-hosted stack for the LAN. See
  [multica/](multica/README.md) and [caddy/](caddy/README.md).

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
│   ├── set-git-config.sh
│   ├── set-docker-mirror.sh   # Docker Desktop registry mirrors (Docker Hub unreachable here)
│   ├── dsh-web-lan.patch.yml  # dsh profile patch: binds the Web GUI to 0.0.0.0
│   ├── install-dsh-lan.sh     # Applies + validates that patch (see "Exposing the DSH Web GUI")
│   └── patch-documentpreview-iterator.sh  # Guard pdf.js's Iterator probe (see "Iterator is not defined")
├── multica/             # Multica self-host stack (PostgreSQL + backend + frontend)
│   ├── README.md
│   ├── docker-compose.yml
│   ├── .env.example     # template (tracked); .env is generated and gitignored
│   ├── deploy.sh
│   └── stop.sh
├── caddy/               # Reverse proxy for multica — a PEER service, not nested inside it
│   ├── README.md
│   ├── Caddyfile
│   ├── docker-compose.yml
│   ├── deploy.sh
│   └── stop.sh
└── provision/
    ├── install-packages.sh
    └── collect-hardware-info.sh
```

`multica/` and `caddy/` are independent Compose projects that can be started and
stopped separately; they are peers rather than parent/child because the proxy is a
generic edge component, not part of the Multica stack. They share the Docker
network `multica-net` (owned by `multica/`, attached as external by `caddy/`).

**Agent runtimes are out of scope for this node.** It serves the Multica control
plane only. Daemons run on the LAN development machines, installed there by
whatever means fits that machine — this node neither builds nor ships an agent
image. What this node does owe a remote daemon is reachability, which is why
`caddy/Caddyfile` forwards `/api/daemon/*` and `.env` sets
`MULTICA_DAEMON_SERVER_URL`.

## Services

| Service | Entry point | Docs |
|:---|:---|:---|
| Multica (control plane: web, API, database) | http://192.168.50.248:3000 | [multica/README.md](multica/README.md) |
| Caddy (reverse proxy; LAN entry + daemon API) | http://192.168.50.248:3000 | [caddy/README.md](caddy/README.md) |
| DSH Web GUI (permanent LAN mode) | http://192.168.50.248:3080 | [Exposing the DSH Web GUI to the LAN](#exposing-the-dsh-web-gui-to-the-lan) |

Start order matters — the network must exist first:

```bash
bash nodes/mac-mini-m4/multica/deploy.sh
bash nodes/mac-mini-m4/caddy/deploy.sh
```

## Exposing the DSH Web GUI to the LAN

This machine runs `dsh web` in **permanent LAN mode**: the GUI binds all interfaces on
every start, so a plain `dsh web` is already reachable from `192.168.50.0/24`. No
wrapper script and no special flags.

```bash
dsh web                 # binds 0.0.0.0:3080 and prints a tokenised LAN URL
dsh web --port 13080    # same, on another port
```

Open the `(LAN: …)` URL that dsh prints, from any other machine on the subnet.

### How it is configured

The setting lives in the dsh **profile patch layer**, which is composed on every boot
of the web profile:

```
tracked : nodes/mac-mini-m4/config/dsh-web-lan.patch.yml
live    : ~/.dsh/profiles/web/cordis.patch.yml
```

The live copy is what dsh reads, and `~/.dsh` is user state that is **not**
version-controlled — so the tracked file plus an installer are what make the posture
reproducible:

```bash
bash nodes/mac-mini-m4/config/install-dsh-lan.sh
```

The installer backs up the previous live layer (timestamped `.bak.*` beside it), copies
the tracked patch into place, and then **validates the result by running the real
composer** (`dsh web --dump-config`) — so a schema or syntax mistake fails loudly here
rather than as a broken GUI on the next start.

To revert: restore the newest `.bak.*` beside the live layer (verified — this restores
the shipped loopback default), or delete the live file.

### Why the profile layer rather than `--host 0.0.0.0`

The flag is deliberately refused by this dsh build — `dsh-web-app/lib/startup.js`:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety:
       it would expose remote code execution to the network; use 127.0.0.1 instead
```

That guard lives **only in the flag parser**. `dsh-host-webserver`'s own schema accepts
`0.0.0.0`, so overriding the composed `webserver` row in the profile layer reaches the
same configuration without passing through the parser — and without patching dsh itself.

The profile layer also **wins over the CLI flag**: `dsh web --host 127.0.0.1` still
binds `*` (verified). That precedence is desirable here — the machine's committed
posture cannot be silently downgraded by a stray flag.

Three details make the patch work, each verified against this dsh build:

- **Every key the row owns must be restated.** A patch replaces the row's whole config
  rather than merging into it. `port` in particular is declared `.required()`, so
  omitting it fails the boot with `$.port missing required value`; it is re-derived from
  `webStartup` so `--port` stays authoritative (a literal would pin every launch to one
  port). `inject: [webStartup]` must be restated too, or `ctx.webStartup` is undefined
  when the `!!js` expression is evaluated.
- **`host` is the only intentional change**; the compression keys are restated at their
  shipped values so response encoding is not silently altered.

### Risk

This exposes the `/api` endpoint — and the **shell tool behind it** — to the whole
subnet over plain HTTP. The browser token exchange still gates every request
(`/` returns `401` without a token, and `/api` refuses an untrusted `Host` with
`403`), but a leaked token is remote code execution as `unknownue`. Keep this on a
trusted network; do not port-forward it.

### Community plugins were reviewed and rejected

Two npm plugins solve related problems — [dsh-lan-access](https://github.com/Leon0555/dsh-lan-access)
and [@yueker/dsh-lan-access](https://www.npmjs.com/package/@yueker/dsh-lan-access) —
and both bundle a `crypto.randomUUID` polyfill plus LAN-friendly bundle patches. Neither
is needed on this dsh version (0.1.5-rc.3), and adding one would mean running
third-party code that wraps every `/api` route and WebSocket upgrade:

- **The `randomUUID` problem is already fixed upstream.** `crypto.randomUUID` is a
  secure-context-only API, absent on plain-HTTP LAN origins. This build ships
  `@deepseek-ai/dsh-util-crypto`, whose own doc comment describes exactly that scenario
  and mints UUIDs from `crypto.getRandomValues` instead (unrestricted in every context);
  a `no-restricted-properties` lint rule points callers at it. Verified in the served
  bundle: all four `crypto.randomUUID` references are behind
  `typeof crypto.randomUUID === "function"` guards, and the module-level `randomUUID()`
  uses `getRandomValues`. The GUI loads correctly over the LAN IP (verified below).
- **The privileged-API restriction it also patches does not exist here.** Neither
  `PRIVILEGED_METHODS` nor a loopback-only gate for settings/credentials is present in
  this build's `dsh-client-connection`.

So the profile patch alone is both sufficient and smaller: it changes one bind address
rather than injecting scripts and wrapping the API surface.

### Caddy is not used here, on purpose

The other LAN services (`multica`, `caddy/`) reach their upstreams by container name
over `multica-net`. That does **not** work for the DSH GUI: the GUI is a host process,
and on Docker Desktop a container cannot reach the host's loopback — neither
`host.docker.internal` nor `network_mode: host` reaches it (both verified, both refused
the connection). So no container-based proxy can front it; widening the bind directly
is one process instead of three.

### Verification

With plain `dsh web` (no flags), over the LAN IP `192.168.50.248`:

| Check | Result |
|:---|:---|
| `/` without a token | `401` |
| token exchange | `303` + cookie |
| authenticated page | `200`, 27724 bytes, `<title>DeepSeek Harness</title>` |
| `/api` with the LAN `Host` | `401` (fence passed, auth still required) |
| `/api` with an untrusted `Host` | `403` (blocked) |

### Known issue: `Iterator is not defined` on older browsers

**Symptom** — the GUI logs, for clients on some browsers:

```
failed to import loader entry b16e0599
(@deepseek-ai/dsh-client-ui-sidebar-documentpreview): Iterator is not defined
```

and the document-preview plugin does not load.

**Cause** — a pdf.js defect, not a LAN or configuration problem. The bundle embeds
pdf.js 6.3.289, which ends `src/shared/util.js` with an unguarded feature probe:

```js
// TODO: Remove this once `Iterator.prototype.join` is generally available.
if (typeof Iterator.prototype.join !== "function") {
  Iterator.prototype.join = function (separator) { return [...this].join(separator) };
}
```

`Iterator` is a **global introduced by the iterator-helpers proposal**, not a
long-standing built-in, and it is absent on Safari < 18.4, Chrome < 122 and
Firefox < 131. Where it is missing, `Iterator.prototype` is a member access on an
*undeclared* identifier, so it throws before `typeof` can make it safe:

```
typeof Undeclared        -> "undefined"     (typeof itself is safe)
typeof Undeclared.proto  -> ReferenceError  (the property read happens first)
```

That throw happens while the module is being evaluated, which is why the whole
plugin fails to import. The defect is still present in pdf.js master, so there is
no fixed release to upgrade to.

> **This is not caused by LAN exposure.** Binding `0.0.0.0` only changes who may
> connect; the same browser hits the same bug on `http://127.0.0.1`. It shows up
> during LAN use because a phone or an older browser is usually the *second*
> client, while this host runs a current Chrome/Safari that never evaluates the
> throwing branch.

**Fix** — guard the probe so the global is never dereferenced when absent:

```bash
bash nodes/mac-mini-m4/config/patch-documentpreview-iterator.sh
```

Then restart the GUI and hard-refresh the affected browser. The script patches both
copies of the probe (the readable one in the module body and the escaped copy inside
the embedded pdf.js worker source), validates that the file still parses, and
restores its backup if any check fails. Verified: the original statement raises
`ReferenceError: Iterator is not defined` in an engine without the global, while the
patched statement does not; the polyfill still installs when `Iterator` exists but
`join` does not, and a native `join` is left untouched. Revert with `--revert`;
re-running is a no-op when already patched.

**Important** — reinstalling or upgrading dsh replaces this file and silently drops
the fix. Re-run the script after any `npm i -g @deepseek-ai/dsh`, and treat a
reappearing `Iterator is not defined` as the signal to re-apply it.

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
| Docker daemon config is per-user, not `/etc/docker/` | Docker Desktop reads `~/.docker/daemon.json` and applies it from the GUI. The Linux nodes' `set-docker-registry.sh` (which writes `/etc/docker/daemon.json` and restarts `dockerd`) does **not** apply here. `config/set-docker-mirror.sh` is the macOS equivalent and needs no sudo — but Docker Desktop must be restarted by hand. |
| Docker Hub is unreachable from this network | `registry-1.docker.io`'s token endpoint returns `EOF`, so any Docker Hub pull hangs. Configure a mirror with `config/set-docker-mirror.sh` and confirm it took effect via `docker info --format '{{json .RegistryConfig.Mirrors}}'`. Registry mirrors do **not** cover `ghcr.io` — see `multica/README.md`. |
| Docker Desktop injects host proxy env into containers | Containers inherit `HTTP_PROXY`/`HTTPS_PROXY` from `~/.docker/config.json`'s `proxies.default`. Any container that makes outbound HTTP (Caddy's upstream dials, `curl`, `wget`) routes through it and fails on Docker-internal hostnames with `502`, or on external hosts if the proxy is dead — the container starts cleanly and every request fails. Neutralise per-service in the compose file (see `caddy/docker-compose.yml`) or pass `--noproxy '*'` in test commands. |
| **Stale `proxies.default` in `~/.docker/config.json` breaks all image builds** | This node had `httpProxy`/`httpsProxy` pointing at `host.docker.internal:7897` with **nothing listening on that port**. Docker Desktop injects those values into `docker build` and `docker run`, so `apt-get update` and `corepack prepare pnpm` failed with `Ign:`/`Unable to connect to host.docker.internal:7897` while the HOST reached the same URLs fine (`deb.debian.org` 200, `registry.npmjs.org` 200). The asymmetry — host works, containers do not — is the signature of this problem. Fix: remove the `proxies` block from `~/.docker/config.json` (a `.bak` is left behind), then verify from inside a container: `docker run --rm node:22-bookworm-slim sh -c 'apt-get update -qq 2>&1 \| grep -c "^W:"'` should print `0`. |
| `github.com` unreachable, but `api.github.com` works | Measured here: `github.com:443` times out after 75 s while `api.github.com` returns 200, so `git clone` and `curl` of release URLs fail but the REST API works. Workaround for source: fetch a tarball via `https://api.github.com/repos/<owner>/<repo>/tarball/<ref>`. For a release asset, resolve its id from `api.github.com/repos/<owner>/<repo>/releases/tags/<tag>` and download it with `Accept: application/octet-stream`. Match the asset by **name** — the release JSON lists ~38 assets and `checksums.txt` comes first, so taking the first `url` field downloads a 1 KB text file. |
| `timeout` is not available | macOS has no GNU `timeout` by default (it is `gtimeout` from coreutils). Use `curl --max-time` instead in scripts. |
| Restarting Docker Desktop is not instant | After `osascript -e 'quit app "Docker"'`, the engine can take minutes to accept connections again, and one restart may not fully bring the VM up. Wait on `docker info` in a loop rather than assuming readiness; containers with `restart: unless-stopped` come back on their own. |

## Maintenance Log

| Date | Issue / Action | Resolution |
|:---|:---|:---|
| 2026-05-24 | Node initialization | Created `nodes/mac-mini-m4/` using `unknownue-manjaro` as template. Added macOS-native `collect-hardware-info.sh` (shared collector is Linux-only), generated `hardware-info.txt`, wrote this README, and registered the node in `inventory/hosts.yml`. |
| 2026-05-24 | Deployed Multica (self-hosted AI agent workspace) | New peer services `multica/` and `caddy/` under this node. Compose stack derived from upstream as an independent copy (no submodule dependency); Caddy containerised as the single LAN entry point on port 3000, forwarding `/ws` to the backend for WebSocket support. Added `config/set-docker-mirror.sh` because Docker Hub is unreachable here, plus a GHCR prefix-rewrite pull for the Multica images. Verified: `/readyz` reports `db`/`migrations` ok, LAN entry returns the frontend and backend responses, `/ws` reaches the backend. |
| 2026-05-24 | Multica pointed at a remote-agent topology | This host serves only the Multica **server**; agents run on the LAN development machines. Set `MULTICA_DAEMON_SERVER_URL` explicitly, because the backend's fallback chain would otherwise advertise the frontend origin to daemons that speak `/api/daemon/*` to the Go backend. Added a `/api/daemon` block to `caddy/Caddyfile` so remote daemons reach the backend through the single LAN entry point rather than needing the loopback-bound 8080. |
| 2026-05-24 | Removed the agent-runtime build from this node | A containerised daemon + dsh image (`multica-agent/`) was built here and then dropped: this node is the control plane, and how a development machine installs its daemon is that machine's business. Removing it also reclaimed a 1.6 GB image and ~5.4 GB of build cache. The network requirements a remote daemon depends on — `MULTICA_DAEMON_SERVER_URL` and Caddy's `/api/daemon/*` route — are unaffected and remain in place. |
| 2026-05-24 | Fixed broken container networking | `~/.docker/config.json` carried a `proxies.default` block pointing at `host.docker.internal:7897` with nothing listening there. Docker Desktop injected it into every build and run, so `apt-get update` and `corepack prepare pnpm` failed inside containers while the host reached the same URLs fine. Removed the block (backup kept as `~/.docker/config.json.bak.*`); container builds now reach `deb.debian.org` and `registry.npmjs.org` directly. |
| 2026-05-25 | `Iterator is not defined` in the LAN Web GUI | The document-preview plugin failed to import for clients on browsers lacking the `Iterator` global (Safari < 18.4, Chrome < 122, Firefox < 131). Root cause is a pdf.js 6.3.289 defect — an unguarded `typeof Iterator.prototype.join` probe, which throws `ReferenceError` because the property read precedes `typeof` — still unfixed in pdf.js master. Added `config/patch-documentpreview-iterator.sh`, which guards both copies of the probe (module body + embedded worker source), verifies the file still parses, and restores its backup on any failure. Confirmed the original statement throws the exact reported error in an engine without the global while the patched one does not, and that the polyfill still installs when `Iterator` exists but `join` does not. Not LAN-specific — the same browser fails identically over loopback. |
| 2026-05-25 | Exposed the DSH Web GUI to the LAN | `dsh web` bound loopback-only and the CLI hard-refuses `--host 0.0.0.0`, but that guard is only in the flag parser while `dsh-host-webserver` already accepts `0.0.0.0`. Added `config/dsh-web-lan.patch.yml` (a dsh profile patch overriding the composed `webserver` row) plus `config/install-dsh-lan.sh`, which installs it into `~/.dsh/profiles/web/cordis.patch.yml` and validates it through the real composer. A plain `dsh web` now binds `0.0.0.0` with no flags or wrapper. Verified from the LAN IP: `/` → `401` without a token, token exchange → `303` + cookie, authenticated page → `200` (27 KB, `<title>DeepSeek Harness</title>`); `/api` passes for the LAN authority (`401`, needs auth) and returns `403` for an untrusted `Host`. The community plugins `dsh-lan-access` / `@yueker/dsh-lan-access` were evaluated first and rejected: their `crypto.randomUUID` fix is already upstream in this build (`@deepseek-ai/dsh-util-crypto` mints UUIDs from `getRandomValues`, and all four `crypto.randomUUID` references in the served bundle are feature-guarded), and the privileged-API restriction they also patch does not exist here. Caddy was also evaluated and rejected — on Docker Desktop neither `host.docker.internal` nor `network_mode: host` reaches the host's loopback, so no container-based proxy can front it. |