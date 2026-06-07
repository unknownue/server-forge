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
| `GET` | `/gpus` | Query all GPU cards with real-time status |
| `GET` | `/gpus/{id}` | Query a single GPU by ID |
| `GET` | `/profiles` | List all available service profiles |
| `GET` | `/profiles/{name}` | View profile details |
| `GET` | `/current` | Current active profile |
| `POST` | `/switch/{name}` | Switch to a profile (stops old, starts new) |
| `POST` | `/stop` | Stop all managed containers |
| `GET` | `/health` | Service Hub health check |

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
| `dsv4-flash-default` | 0,1 | DeepSeek-V4-Flash 128K×3 |
| `dsv4-flash-long` | 0,1 | DeepSeek-V4-Flash 256K×2 |
| `dsv4-flash-524k` | 0,1 | DeepSeek-V4-Flash 524K×1 |
| `dsv4-flash-high` | 0,1 | DeepSeek-V4-Flash 64K×5 |
| `unsloth` | 0,1,2,3 | Unsloth Studio (training) |

## Examples

```bash
# Query GPU status
curl http://localhost:9090/gpus

# Switch to DeepSeek-V4-Flash
curl -X POST http://localhost:9090/switch/dsv4-flash-default

# Force switch (even if same profile)
curl -X POST "http://localhost:9090/switch/game-server-default?force=true"

# Stop all services
curl -X POST http://localhost:9090/stop

# Check current profile
curl http://localhost:9090/current
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
