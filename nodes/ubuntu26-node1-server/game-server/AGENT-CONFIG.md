# Agent Inference Configuration — Claude Code Game Studios Deployment Guide

**Date**: 2026-05-27
**Target**: ubuntu26-node1-server (4× RTX 6000D 85.6GB)
**Context**: [Claude Code Game Studios](https://github.com/Donchitos/Claude-Code-Game-Studios) (CCGS) —
49-agent game development studio template for Claude Code.

## Architecture Overview

CCGS agents run within Claude Code CLI sessions and by default use Anthropic's hosted
Claude models (Haiku/Sonnet/Opus). This deployment provides **local inference endpoints**
as an alternative backend, targeting tasks where self-hosted models offer advantages:

| Advantage | Applies To |
|-----------|-----------|
| No API cost per token | High-volume code generation, design iteration |
| No rate limits | Parallel agent teams (up to 49 agents) |
| Data locality | Proprietary game assets stay on-prem |
| Specialized models | MoE for code, FLUX.2 for game art |

CCGS agents can be configured to route specific task types to local endpoints while
keeping critical coordination and creative direction on Claude's hosted models.

## Endpoint Topology

```
┌─────────────────────────────────────────────────────────┐
│                  ubuntu26-node1-server                    │
│                                                          │
│  GPU 0: Qwen3.6-27B FP8  ──→  :8000  Coordinator        │
│  GPU 1: Qwen3.6-35B-A3B   ──→  :8001  Code Gen (MoE)    │
│  GPU 2: Qwen3.6-27B FP8  ──→  :8002  Multimodal + QA    │
│  GPU 3: FLUX.2 FP8        ──→  :8188  Image Gen (ComfyUI)│
│                                                          │
│  API: OpenAI-compatible /v1/chat/completions             │
│  Image: ComfyUI REST API /prompt + /history              │
└─────────────────────────────────────────────────────────┘
```

All text endpoints expose an **OpenAI-compatible API** at `/v1/chat/completions`,
making them drop-in compatible with any tool that supports custom OpenAI base URLs.

### Quick Reference

| Port | Model | Quant | Tok/s (4 agents) | Best For |
|------|-------|-------|---------------------|----------|
| 8000 | Qwen3.6-27B | FP8 | 82.8 | Architecture review, coordination, multimodal |
| 8001 | Qwen3.6-35B-A3B | BF16 | 338.1 | Code generation (4× faster than 27B) |
| 8002 | Qwen3.6-27B | FP8 | 82.7 | Visual analysis, QA validation, reasoning |
| 8188 | FLUX.2 FP8 | FP8m | — | Game art, sprites, concept renders |

## CCGS Agent → Endpoint Mapping

### Tier 1 — Directors (keep on Claude-hosted models)

CCGS Tier 1 agents (creative-director, technical-director, producer) handle
multi-document synthesis, creative vision, and high-stakes gate decisions.
These benefit from Claude Opus's reasoning depth and should **remain on
Anthropic-hosted models**. The local 27B models lack the context window and
reasoning depth for director-level work.

### Tier 2 — Department Leads (hybrid)

Department leads can offload specific analyses to local endpoints while keeping
judgment calls on Claude:

| CCGS Agent | Local Endpoint | Offload Task |
|-----------|---------------|--------------|
| lead-programmer | :8001 (MoE) | Code pattern analysis, boilerplate review |
| game-designer | :8000 (27B) | GDD consistency checks, formula validation |
| qa-lead | :8002 (27B) | Test plan generation, edge case enumeration |
| art-director | :8188 (FLUX.2) | Style reference generation, mood board iteration |

### Tier 3 — Specialists (primary local-endpoint users)

These are the highest-volume agents and benefit most from local inference:

#### Code Generation Agents → :8001 (MoE)
```
gameplay-programmer, engine-programmer, ai-programmer,
network-programmer, tools-programmer, ui-programmer,
devops-engineer, security-engineer, performance-analyst,
godot-specialist, godot-gdscript-specialist, godot-csharp-specialist,
unity-specialist, unity-dots-specialist, ue-specialist
```

The MoE model (338 tok/s) is 4× faster than the 27B Dense for code generation
and provides 35B parameters of programming knowledge with only 3B activated
per token — ideal for the high throughput demands of programming agents.

#### Design & Analysis Agents → :8000 (27B)
```
systems-designer, economy-designer, ux-designer, level-designer,
world-builder, prototyper, narrative-director, writer
```

Design tasks require deep cross-document reasoning. The 27B Dense model's
full-parameter activation per token provides better coherence for design
documents than the MoE model.

#### QA & Validation Agents → :8002 (27B)
```
qa-tester, accessibility-specialist, analytics-engineer,
live-ops-designer, community-manager
```

QA and validation are read-heavy tasks that benefit from the 27B's
multimodal capability (screenshot review) and reasoning parser.

#### Visual/Creative Agents → :8188 (FLUX.2)
```
art-director, technical-artist, sound-designer
```

FLUX.2 FP8 generates game-ready art assets via ComfyUI's REST API:
sprites, textures, concept art, and UI mockups. The `/prompt` endpoint
accepts standard ComfyUI workflow JSON.

## Integration Patterns

### Pattern A: Direct API Calls

For ad-hoc use by individual agents, configure the OpenAI base URL:

```python
# Example: gameplay-programmer calls the MoE endpoint
from openai import OpenAI

client = OpenAI(
    base_url="http://ubuntu26-node1-server:8001/v1",
    api_key="not-needed"  # local endpoint, no auth
)

response = client.chat.completions.create(
    model="Qwen3.6-35B-A3B-FP8",
    messages=[
        {"role": "user", "content": "Write GDScript for an inventory system..."}
    ],
    max_tokens=2048
)
```

### Pattern B: CCGS Agent Configuration

To configure a CCGS agent to use a local endpoint, set the `OPENAI_BASE_URL`
environment variable in the agent's session or the project's `.claude/settings.json`:

```json
{
  "env": {
    "LOCAL_LLM_CODE": "http://localhost:8001/v1",
    "LOCAL_LLM_DESIGN": "http://localhost:8000/v1",
    "LOCAL_LLM_QA": "http://localhost:8002/v1",
    "LOCAL_IMAGE_GEN": "http://localhost:8188"
  }
}
```

### Pattern C: Nginx Load Balancer

For production agent teams, deploy an Nginx reverse proxy to distribute
requests across all three text endpoints using `least_conn` balancing:

```nginx
upstream llm_backend {
    least_conn;
    server 127.0.0.1:8000;  # 27B FP8 Coordinator
    server 127.0.0.1:8001;  # 35B-A3B BF16 MoE Code Gen
    server 127.0.0.1:8002;  # 27B FP8 Multimodal QA
}

server {
    listen 8080;
    location /v1/ {
        proxy_pass http://llm_backend;
        proxy_read_timeout 600s;
    }
}
```

The `least_conn` strategy routes new requests to the endpoint with the
fewest active connections. This is effective because the MoE endpoint
(:8001) processes requests 4× faster and naturally receives more traffic.
Access the unified endpoint at `http://localhost:8080/v1/chat/completions`.

## Performance Budget per CCGS Workflow

Measured at OSL=2048 with reasoning parser enabled (Qwen3 native format).

### /design-system → :8000 + :8002 (27B Dense)

```
Workload:  Design doc generation + cross-reference validation
Throughput: 2 × 82.8 = ~166 tok/s combined
Latency:   ~99s per 2048-token design section
Capacity:  2 concurrent design agents comfortably
```

### /create-epics + /dev-story → :8001 (MoE)

```
Workload:  Code generation, boilerplate, implementation
Throughput: 338 tok/s (4 agents concurrent)
Latency:   ~24s per 2048-token code block
Capacity:  4 concurrent programming agents at full speed
Note:     MoE uses BF16 — limited KV cache (~13.6GB) but sufficient
          for agent workloads at typical OSL=2048-4096
```

### /review-all-gdds → :8000 (27B)

```
Workload:  Multi-GDD cross-referencing, consistency checks
Throughput: 82.8 tok/s (single agent)
Latency:   ~99s per document analysis
Note:     Deep reasoning benefits from Dense architecture
```

### Game Art Generation → :8188 (FLUX.2)

```
Workload:  Sprite sheets, concept art, UI mockups
Latency:   ~15-30s per 1024×1024 image (FP8, 20-step Euler)
Batch:     1-4 images per workflow submission
API:       POST /prompt → poll /history/{id} → download image
```

## Deployment Commands

The game-server deployment provides three plans selectable at launch time.

### Default Plan (one-click)

```bash
bash deploy.sh
```

Launches all 4 services: coordinator (GPU 0, :8000), MoE code generator
(GPU 1, :8001), multimodal QA (GPU 2, :8002), and FLUX.2 image generation
(GPU 3, :8188).

### Alternative Plans

```bash
bash deploy.sh plan-72b       # Replace coordinator with 72B TP=2
bash deploy.sh plan-reasoning # Replace coordinator with R1-32B CoT
```

### Stop All Services

```bash
bash stop.sh
```

Stops and removes all game-server Docker containers.

### Model Download (one-time, ~120 GB)

```bash
bash download-model.sh                    # All registered models
bash download-model.sh Qwen/Qwen3.6-35B-A3B  # Single model
```

Downloads models to `/data/work/models/` with pinned revisions for reproducibility.

## Hardware Constraints & Design Decisions

### Why MoE is BF16 (not FP8)

The RTX 6000D (Ada Lovelace AD102) has **99 KB shared memory per SM**.
Triton's FP8 MoE kernels for Qwen3.6-35B-A3B require **144 KB shared memory**
— a hardware incompatibility. The BF16 kernels fit within the 99 KB limit.

Attempted mitigations that failed:
- `--moe-runner-backend cutlass`: requires block quantization (not available)
- `--moe-runner-backend flashinfer_trtllm`: `use_ragged` attribute error
- `--moe-runner-backend triton_kernel`: crashes during model loading
- `--moe-runner-backend deep_gemm`: missing attribute in SGLang build
- `TRITON_MAX_SHARED_MEMORY` env var: not a real Triton setting

**Trade-off accepted**: MoE runs BF16, using ~70GB for weights (vs 35GB FP8),
leaving ~13.6GB for KV cache. This is sufficient for agent workloads at
OSL=2048–4096. The 4× throughput advantage over 27B Dense justifies the VRAM cost.

### Page Size Must Be Auto (Not 64)

Qwen3 models use a GDN/Mamba hybrid architecture with linear attention layers.
Setting `--page-size 64` causes: `AssertionError: Page size must be 1 for
MambaRadixCache v1`. SGLang auto-detects the correct page size when the flag
is omitted.

### Reasoning Parser Overhead

Qwen3 models with `--reasoning-parser qwen3` spend ~30-50% of output tokens
on internal reasoning before producing the final answer. At OSL=2048, the
effective content output is ~1000-1400 tokens. For code generation, this
overhead is acceptable — the reasoning improves code quality. For fast
iteration tasks, consider disabling the reasoning parser to get more
content tokens per request.

## Testing & Validation

### Smoke Test All Endpoints

```bash
# Verify all 3 text endpoints respond
for port in 8000 8001 8002; do
  curl -s http://localhost:$port/v1/models | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])"
done

# Verify ComfyUI is healthy
curl -s http://localhost:8188/system_stats -o /dev/null -w "ComfyUI: HTTP %{http_code}\n"
```

### Multi-Agent Simulation

Simulate concurrent agent workload against any endpoint using
OpenAI-compatible chat completion requests. Example with 4 agents
sending 10 requests each at OSL=2048:

```bash
# Against the MoE code generator
for agent_id in $(seq 1 4); do
  for req in $(seq 1 10); do
    curl -s http://localhost:8001/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"Qwen3.6-35B-A3B-FP8\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Write a GDScript function for saving game state.\"}],
        \"max_tokens\": 2048
      }" &
  done
done
wait
```

### Throughput Benchmark

```bash
# Single-endpoint benchmark (AIPerf)
docker run --rm --network host \
  -v /data/work/benchmarks:/benchmarks \
  aiperf:latest \
  --endpoint http://localhost:8000/v1/chat/completions \
  --model Qwen3.6-27B-FP8 \
  --osl 2048 --num-prompts 64
```

### Cross-Plan Comparison

Run the same benchmark workload against all three deployment plans to
compare throughput and latency characteristics before selecting the
plan that best fits the agent team size.

