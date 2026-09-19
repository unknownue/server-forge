# Service Hub

Local web UI for `ubuntu-server-node-2` (2× AMD Radeon RX 7900 XTX).
Shows live GPU state and starts/stops serving profiles with one click, so
bringing the node up after a reboot does not mean remembering a serve command.

Modeled on `nodes/ubuntu26-node1-server/service-hub`, with two differences that
this AMD node forced:

1. **GPU status comes from sysfs**, not `nvidia-smi`/`rocm-smi`. Neither ROCm CLI
   is installed on the host (ROCm lives inside containers), and sysfs already
   exposes everything needed — busy %, VRAM, hwmon temperature — with no extra
   packages and no privileged calls.
2. **P2P health is surfaced in the UI.** Every multi-GPU profile here depends on
   cross-GPU peer access, which depends on the patched kernel and patched RCCL.
   If either is lost (e.g. a kernel upgrade), TP=2 keeps working but silently
   falls back to host-staged collectives — much slower, no error. The banner
   makes that visible instead of leaving it to be noticed as slow generation.

## Start

```bash
bash nodes/ubuntu-server-node-2/service-hub/deploy.sh        # foreground, port 9090
bash nodes/ubuntu-server-node-2/service-hub/deploy.sh 8080   # custom port
```

Then open <http://localhost:9090/>. First run installs Python deps into the
repo's `.pylibs` tree (there is no `uv`, and `bootstrap.pypa.io` is unreachable
from this network) and builds the frontend if `static/` is missing.

### Run as a service (recommended)

```bash
bash nodes/ubuntu-server-node-2/service-hub/install-service.sh
```

Installs a **systemd user** unit, enables it, and starts it. Manage it with:

```bash
systemctl --user status  service-hub
systemctl --user restart service-hub
systemctl --user stop    service-hub
journalctl --user -u service-hub -f
```

To uninstall: `bash .../install-service.sh --remove`.

`Restart=on-failure` is set, so a crashed hub comes back automatically.

**One sudo step is needed to survive logout.** `enable` only starts the unit at
login; without lingering, the whole user manager stops when your last session
ends:

```bash
sudo loginctl enable-linger $USER
```

`install-service.sh` prints this if lingering is off, and says nothing once it is
on. For a machine that serves models unattended, turning it on is the point.

#### Why it is a *user* unit

The hub needs no privileges — it shells out to `docker` (permitted by the user's
`docker` group membership) and reads sysfs. A user unit also gets `%h` expansion
and the user's environment for free.

One consequence, worth knowing if you edit the unit: `docker.service` is a
**system** unit and is invisible to the user manager, so declaring
`After=docker.service` fails outright with `Unit docker.service not found`.
Ordering is instead handled inside `deploy.sh`, which waits (up to 30 s) for
`docker info` to succeed before starting.

## Stop

```bash
bash nodes/ubuntu-server-node-2/service-hub/stop.sh
# or, when installed as a service: systemctl --user stop service-hub
```

This stops only the hub. Containers it launched keep running — use the UI's
**Stop all** button for those.

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/gpus` | All GPUs: VRAM, utilization, temperature, containers |
| `GET` | `/api/gpus/{id}` | One GPU |
| `GET` | `/api/gpu-history` | 1-hour VRAM/utilization history (30 s samples) |
| `GET` | `/api/p2p` | Dual-GPU peer-access status |
| `GET` | `/api/profiles` | List profiles |
| `GET` | `/api/profiles/{name}` | Profile detail + live service state |
| `GET` | `/api/current` | Active profile |
| `POST` | `/api/switch/{name}` | Stop everything, then start this profile |
| `POST` | `/api/stop` | Stop all managed containers |
| `GET` | `/api/history` | Switch history |
| `GET` | `/api/health` | Hub health check |

Interactive docs: <http://localhost:9090/docs>

`POST /api/switch/{name}` blocks until the profile's services are launched and
reports elapsed time. A switch holds a lock, so concurrent requests get `409`
rather than two servers racing for the same GPUs.

## Profiles

Definitions live in the node-level `profiles/` directory (same convention as
node1), not inside `service-hub/`.

| Profile | GPUs | Description |
|---------|------|-------------|
| `sglang-tp2` | 0,1 | Qwen3.8-27B, TP=2 + MTP-3 — the reproduced topic-1532 config |
| `sglang-single` | 0 | One instance on GPU 0, GPU 1 left free |

There is no two-instance (data-parallel) profile. Splitting per GPU would need
each card to hold the whole 19 GB checkpoint, which does not fit alongside the
KV and mamba state on a 24 GB card — the containers exit during startup. TP=2
works precisely because sharding halves the per-card weights. Full analysis in
`bench/results/tp2-vs-dp2.txt`.

`stop_containers` in each profile lists every container a switch should remove,
so switching profiles never leaves an old server holding VRAM.

### Adding a profile

Drop a YAML file in `profiles/`, then press Refresh — profiles are read from
disk on every request, so no restart is needed:

```yaml
name: my-profile
description: "..."
version: "1.0"

gpu_allocation:
  - role: llm
    gpu: [0, 1]
    model: Some-Model
    note: "..."

services:
  - name: my-service
    script: serve/sglang-tp2.sh      # path relative to the node directory
    args: ["tp2", "8080"]
    health: http://localhost:8080/health_generate
    container_prefix: sglang-tp2

stop_containers:
  - sglang-tp2-tp2
```

## Frontend development

The UI is Vue 3 + Vite and builds into `../static`, served by FastAPI from the
same origin (works offline on an internal network):

```bash
cd frontend
npm install
npm run dev     # hot reload on :5173, proxies /api to :9090
npm run build   # writes ../static
```

`deploy.sh` only builds when `static/index.html` is absent, so re-run
`npm run build` yourself after changing frontend sources.

## Notes

- **Container detection** relies on `ROCR_VISIBLE_DEVICES` / `HIP_VISIBLE_DEVICES`,
  since ROCm containers have no `--gpus` equivalent without the NVIDIA toolkit.
  Only containers named `sglang-*` are attributed to GPUs.
- **GPU order is by PCI slot** (`0000:05:00.0` then `0000:08:00.0`), so indices
  stay stable across reboots — profiles and `ROCR_VISIBLE_DEVICES` refer to them.
- `deploy.sh` runs uvicorn in the foreground; use a background job or a terminal
  multiplexer to keep it alive.