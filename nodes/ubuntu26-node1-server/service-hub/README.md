# Service Hub

Local service management gateway for `ubuntu26-node1-server`.
Provides an HTTP API to query GPU card status and switch between pre-defined
service profiles (different model deployments on the 4 compute GPUs).

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) — `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Docker (for container management)
- nvidia-smi (for GPU status queries)

## Start

```bash
bash service-hub/deploy.sh          # default port 9090
bash service-hub/deploy.sh 8080     # custom port
```

Or via the project Makefile (from repo root):

```bash
make service-hub                     # default port 9090
make service-hub PORT=8080
```

The first run will install Python dependencies via uv (~10 seconds).

## Stop

```bash
bash service-hub/stop.sh
# or: make service-hub-stop
```

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/gpus` | Query all GPU cards with real-time status |
| `GET` | `/api/gpus/{id}` | Query a single GPU by ID |
| `GET` | `/api/gpu-history` | GPU memory/utilization history |
| `GET` | `/api/profiles` | List all available service profiles |
| `GET` | `/api/profiles/{name}` | View profile details |
| `GET` | `/api/current` | Current active profile |
| `POST` | `/api/switch/{name}` | Switch to a profile (stops old, starts new) |
| `POST` | `/api/stop` | Stop all managed containers |
| `GET` | `/api/health` | Service Hub health check |

Interactive API docs: http://localhost:9090/docs

## Available Profiles

| Profile | GPUs | Description |
|---------|------|-------------|
| `game-server-default` | 0,1,2,3 | 2×27B + 35B-A3B MoE + FLUX.2 |
| `game-server-72b` | 0,1,2,3 | 72B TP=2 + 27B + FLUX.2 |
| `game-server-reasoning` | 0,1,2,3 | R1-Distill-32B + MoE + 27B + FLUX.2 |
| `web-server-default` | 0,1,2,3 | 3×27B + 35B-A3B MoE |
| `web-server-72b` | 0,1,2,3 | 72B TP=2 + 2×27B |
| `web-server-reasoning` | 0,1,2,3 | R1-Distill-32B + MoE + 2×27B |
| `qwen38-dspark-1gpu` | 0 | Qwen3.8-27B-NVFP4 DSPARK, 131K ctx, balanced (4.9 GiB headroom) |
| `qwen38-dspark-2gpu` | 0,1 | Qwen3.8-27B-NVFP4 DSPARK TP=2, 256K model len (~227K+ usable, ~7 GiB/GPU headroom) |
| `unsloth` | 0,1,2,3 | Unsloth Studio (training) |
| `anim-lab` | 0 | ComfyUI FLUX.2 image/video generation |

## Examples

```bash
# Query GPU status
curl http://localhost:9090/api/gpus

# Switch to the Qwen3.8 single-GPU profile
curl -X POST http://localhost:9090/api/switch/qwen38-dspark-1gpu

# Switch to the Qwen3.8 dual-GPU (full 256K ctx) profile
curl -X POST http://localhost:9090/api/switch/qwen38-dspark-2gpu

# Force switch (even if same profile)
curl -X POST "http://localhost:9090/api/switch/game-server-default?force=true"

# Stop all services
curl -X POST http://localhost:9090/api/stop

# Check current profile
curl http://localhost:9090/api/current
```

## Architecture

```
service-hub/
├── pyproject.toml              # uv project + dependencies
├── deploy.sh / stop.sh         # Lifecycle scripts
└── src/service_hub/
    ├── server.py               # FastAPI app + all endpoints
    ├── gpu_monitor.py          # nvidia-smi + Docker inspect
    ├── profile_executor.py     # Profile loading + switch logic
    └── models.py               # Pydantic data models
```

State is persisted in `service-hub/.state.json` (current profile + switch history).
