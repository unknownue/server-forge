# Agent Inference Configuration — Claude Code Game Studios Deployment Guide

**Date**: 2026-05-29
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
┌──────────────────────────────────────────────────────────────────┐
│                       ubuntu26-node1-server                       │
│                                                                   │
│  GPU 0: Qwen3.6-27B FP8  ──→  :8000  (Anthropic + OpenAI)       │
│  GPU 1: Qwen3.6-35B-A3B   ──→  :8001  (Anthropic + OpenAI, MoE)  │
│  GPU 2: Qwen3.6-27B FP8  ──→  :8002  (Anthropic + OpenAI)       │
│  GPU 3: FLUX.2 FP8        ──→  :8188  (ComfyUI)                   │
│                                                                   │
│  All text endpoints serve both Anthropic /v1/messages and         │
│  OpenAI /v1/chat/completions natively (SGLang built-in).          │
│  No translation proxy needed.                                     │
└──────────────────────────────────────────────────────────────────┘
```

### Quick Reference

| Port | Service | Model | Quant | Tok/s (4 agents) | Characteristics |
|------|---------|-------|-------|---------------------|-----------------|
| 8000 | SGLang | Qwen3.6-27B | FP8 | 82.8 | Dense, full-param reasoning, multimodal |
| 8001 | SGLang | Qwen3.6-35B-A3B | FP8 | 695.7 | MoE (35B→3B active), 8× throughput |
| 8002 | SGLang | Qwen3.6-27B | FP8 | 82.7 | Dense, full-param reasoning, multimodal |
| 8188 | ComfyUI | FLUX.2 FP8 | FP8m | — | Image generation |

### Model Selection

Each SGLang endpoint serves the model loaded on that GPU. To use a specific model,
point `ANTHROPIC_BASE_URL` at the corresponding port:

| Endpoint | Model (served-model-name) | Best For |
|----------|---------------------------|----------|
| `http://localhost:8000` | `Qwen3.6-27B-FP8` | Reasoning, architecture, multimodal |
| `http://localhost:8001` | `Qwen3.6-35B-A3B-FP8` | Code generation, high throughput (MoE) |
| `http://localhost:8002` | `Qwen3.6-27B-FP8` | Reasoning, architecture, multimodal |

Set `ANTHROPIC_BASE_URL` to the endpoint serving your preferred model. All three
endpoint URLs also work with the OpenAI SDK at `/v1/chat/completions`.

## Routing Recommendations

Role assignment is **not enforced at the infrastructure level**. All three text
endpoints serve the same API and accept any prompt. Downstream consumers (CCGS
agents, load balancers, orchestration scripts) decide which endpoint to call.

**Simple starting point:**

- **Code-heavy tasks** → prefer `:8001` (MoE, 8× throughput, wider code knowledge)
- **Design, analysis, multimodal** → any 27B endpoint (`:8000` or `:8002`)
- **High concurrency** → distribute across all 3 endpoints

Since `:8000` and `:8002` run identical models, treat them as **interchangeable
capacity** — distribute load across both for higher throughput rather than
reserving each for a specific role. CCGS Tier 1 director agents (creative-director,
technical-director, producer) benefit from Anthropic-hosted Claude models for
multi-document synthesis and high-stakes decisions; the local 27B models lack
the context window and reasoning depth for director-level work.

## Agent Granularity & Context Management

The 32K context window is sufficient **only when agents are properly scoped**.
The design principle: **don't let a single agent do too much at once.**

### Context Budget per Agent Type

| Agent Type | Typical Context | 32K Headroom | Strategy |
|-----------|----------------|--------------|----------|
| Code gen (single function/class) | 8–15K | Plenty | Direct implementation |
| Design doc (one GDD section) | 10–18K | Comfortable | Single-focus authoring |
| QA validation (read tests + code) | 10–16K | Comfortable | Focused review |
| Architecture review (cross-file) | 18–28K | Tight | Summarize first, then decide |
| Multi-file refactor (5+ files) | 25–32K+ | **At risk** | Split across agents |

### Work-Splitting Pattern

For tasks that exceed 32K, split across agents instead of forcing one agent to
handle everything:

```
❌ Wrong: One agent reads 8 files + writes 5 modifications → overflow
✅ Right:
  /architect-agent     → reads all files, writes a summary/plan (15K)
  /programmer-agent-1  → implements group A based on the plan (12K)
  /programmer-agent-2  → implements group B based on the plan (14K)
  /qa-agent            → reviews final result against the plan (10K)
```

The CCGS agent hierarchy naturally supports this:
- **Tier 2 leads** read broad scope, produce focused specs
- **Tier 3 specialists** execute narrow, well-defined changes
- Each agent stays within 32K by design

### When Context Nears the Limit

Signs that context is filling up (visible in Claude Code):

- Compaction runs more frequently (messages summarized before you asked)
- File content references start using truncated snippets
- `/clear` needed more than once per session
- Error: "Input is too long" from SGLang

Mitigations, in priority order:

1. **Narrow the task** — ask the agent to focus on one file/function at a time
2. **Use a summary agent** — have one agent produce a condensed analysis, pass it to another
3. **Start a fresh session** — `/clear` resets context, compaction keeps the critical parts
4. **Split the work into separate Claude Code sessions** — different directories, different contexts
5. **Route to a 40K-capable instance** — :8000 and :8002 support 40K context
   (8K above Claude Code's 32K management target). Switch model to
   `Qwen3.6-27B-FP8` for tasks that need the extra headroom.

### Claude Code Configuration

Configure Claude Code to talk directly to SGLang's native Anthropic Messages API
(`/v1/messages`). No translation proxy needed — SGLang serves Anthropic format natively.

SGLang requires two small patches for full Claude Code compatibility (see
[config/sglang-patches/](config/sglang-patches/)): accept `role=system` in messages,
merge system messages into the top-level `system` field, and skip `thinking` blocks
in conversation history. `deploy.sh` mounts these patches automatically.

### Required Environment Variables

```bash
# API endpoint — point directly at any SGLang instance (no /v1 suffix!)
export ANTHROPIC_BASE_URL="http://localhost:8001"

# API key — any non-empty string, SGLang does not validate
export ANTHROPIC_API_KEY="not-needed"
```

### Model Selection

Point ANTHROPIC_BASE_URL at the SGLang instance serving your preferred model.
All three endpoints expose the same Anthropic API:

| Endpoint | Model | Best For |
|----------|-------|----------|
| `http://localhost:8001` | Qwen3.6-35B-A3B-FP8 (MoE) | Code generation, high throughput |
| `http://localhost:8000` | Qwen3.6-27B-FP8 | Reasoning, multimodal |
| `http://localhost:8002` | Qwen3.6-27B-FP8 | Reasoning, multimodal |

Model names use **SGLang served-model-name values** (the `--served-model-name` flag):

```bash
# Opus role — complex multi-step reasoning, architecture decisions
# Use a 27B Dense endpoint (:8000 or :8002)
export ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-27B-FP8"

# Sonnet role — default for most tasks, balanced speed/quality
# Use the MoE endpoint (:8001) for speed
export ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"

# Haiku role — lightweight tasks, subagents, compaction, background work
# MoE for fast turnaround
export ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"
```

**How Claude Code uses these roles:**

| Claude Code Role | When Used | Recommended Model |
|------------------|-----------|-------------------|
| Opus (`ANTHROPIC_DEFAULT_OPUS_MODEL`) | Complex reasoning, architecture decisions, `opusplan` plan phase | `Qwen3.6-27B-FP8` (Dense) |
| Sonnet (`ANTHROPIC_DEFAULT_SONNET_MODEL`) | Default for most operations, `opusplan` execution phase | `Qwen3.6-35B-A3B-FP8` (MoE) |
| Haiku (`ANTHROPIC_DEFAULT_HAIKU_MODEL`) | Subagents, compaction, quick lookups, background tasks | `Qwen3.6-35B-A3B-FP8` (MoE) |

**Optional overrides:**

```bash
# Lock all operations to a single model (overrides role-specific settings)
# export ANTHROPIC_MODEL="Qwen3.6-35B-A3B-FP8"

# Override subagent model specifically
# export CLAUDE_CODE_SUBAGENT_MODEL="Qwen3.6-35B-A3B-FP8"
```

### Model Capability Overrides

Local models lack features that Claude's hosted models support. Disable them
to prevent Claude Code from sending unsupported parameters:

```bash
# Extended thinking — NOT supported by Qwen/SGLang
export CLAUDE_CODE_DISABLE_THINKING=1

# Prompt caching — NOT supported by local endpoints
export DISABLE_PROMPT_CACHING=1

# Context window — local models use 32K, not 200K
# Set to match --context-length from deploy.sh
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768
```

### Optional: Display Names in /model Picker

Set friendly display names visible in Claude Code's `/model` selector:

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="Qwen3.6 27B (Local GPU 0)"
export ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="Qwen3.6 35B MoE (Local GPU 1)"
export ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="Qwen3.6 35B MoE (Local GPU 1 - Fast)"

# Declare supported capabilities (local models support none of these)
export ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES=""
export ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES=""
export ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES=""
```

### Environment Variables NOT Needed

These are unnecessary for local endpoints — do **not** set them:

| Variable | Why Not Needed |
|----------|---------------|
| `ANTHROPIC_AUTH_TOKEN` | Proxy doesn't check Authorization header |
| `ANTHROPIC_SMALL_FAST_MODEL` | **Deprecated** — use `ANTHROPIC_DEFAULT_HAIKU_MODEL` instead |
| `ANTHROPIC_BEDROCK_BASE_URL` / `ANTHROPIC_VERTEX_BASE_URL` / `ANTHROPIC_FOUNDRY_BASE_URL` | Not using AWS Bedrock / GCP Vertex / Azure Foundry |
| `CLAUDE_CODE_USE_BEDROCK` / `CLAUDE_CODE_USE_VERTEX` / `CLAUDE_CODE_USE_FOUNDRY` | Not using third-party providers |
| `ANTHROPIC_BETAS` | No beta features needed for local models |
| `ANTHROPIC_EXTRA_BODY` | SGLang handles translation natively |

### Complete Configuration

All essential vars in one block — add to `~/.bashrc` or a per-project `.env`:

```bash
# ── Endpoint ──
export ANTHROPIC_BASE_URL="http://localhost:8001"
export ANTHROPIC_API_KEY="not-needed"

# ── Model mapping (real model names) ──
export ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-27B-FP8"
export ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"

# ── Capability overrides ──
export CLAUDE_CODE_DISABLE_THINKING=1
export DISABLE_PROMPT_CACHING=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768

# ── Optional: friendly names ──
export ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="Qwen3.6 27B (Local)"
export ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="Qwen3.6 35B MoE (Local)"
export ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="Qwen3.6 35B MoE (Local - Fast)"
```

### Per-Project Configuration

To configure per CCGS project instead of globally, add to the project's
`.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8001",
    "ANTHROPIC_API_KEY": "not-needed",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "Qwen3.6-27B-FP8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "Qwen3.6-35B-A3B-FP8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "Qwen3.6-35B-A3B-FP8",
    "CLAUDE_CODE_DISABLE_THINKING": "1",
    "DISABLE_PROMPT_CACHING": "1",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "32768"
  }
}
```

### Verification

After configuration, verify Claude Code is routing directly to SGLang:

```bash
# Check which models Claude Code detects
claude --model

# Test with a simple prompt (non-interactive mode)
echo "Say hello in one word." | claude -p --model Qwen3.6-35B-A3B-FP8
```

Check SGLang logs to confirm routing:
```bash
docker logs gs-35b-moe-code --tail 20
```

## SDK Integration Patterns

For direct SDK usage (bypassing Claude Code), all SGLang endpoints serve both formats natively.

### Pattern A: OpenAI SDK (Direct API Calls)

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
    server 127.0.0.1:8000;  # Qwen3.6-27B FP8
    server 127.0.0.1:8001;  # Qwen3.6-35B-A3B FP8 MoE
    server 127.0.0.1:8002;  # Qwen3.6-27B FP8
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
(:8001) processes requests 8× faster and naturally receives more traffic.
Access the unified endpoint at `http://localhost:8080/v1/chat/completions`.

### Pattern D: Anthropic SDK (via Translation Proxy)

Use the Anthropic Python SDK to call SGLang endpoints directly.
SGLang serves the Anthropic Messages API natively, including streaming and multimodal content.

```python
# Example: gameplay-programmer calls MoE endpoint via Anthropic SDK
from anthropic import Anthropic

client = Anthropic(
    base_url="http://localhost:8001",
    api_key="not-needed",  # local endpoint, no auth
)

response = client.messages.create(
    model="claude-sonnet-4-6",  # auto-routes to :8001 MoE
    max_tokens=2048,
    system="You are a gameplay programmer writing GDScript for Godot 4.",
    messages=[
        {"role": "user", "content": "Write an inventory system with drag-and-drop."}
    ],
)

print(response.content[0].text)
```

**Streaming:**

```python
with client.messages.stream(
    model="claude-opus-4-7",  # routes to :8000 coordinator
    max_tokens=2048,
    messages=[{"role": "user", "content": "Review this architecture..."}],
) as stream:
    for event in stream:
        if event.type == "content_block_delta":
            print(event.delta.text, end="", flush=True)
```

**Image understanding (multimodal):**

```python
import base64

with open("game_screenshot.png", "rb") as f:
    image_data = base64.b64encode(f.read()).decode()

response = client.messages.create(
    model="claude-haiku-4-5",  # routes to :8002 multimodal
    max_tokens=1024,
    messages=[{
        "role": "user",
        "content": [
            {"type": "image", "source": {
                "type": "base64", "media_type": "image/png", "data": image_data}},
            {"type": "text", "text": "Describe the UI layout visible in this screenshot."}
        ]
    }],
)
```

**Model routing — no code changes needed:**

| Parameter | Routes To | Real Model |
|-----------|-----------|------------|
| `model="claude-opus-4-7"` | :8000 | Qwen3.6-27B FP8 |
| `model="claude-sonnet-4-6"` | :8001 | Qwen3.6-35B-A3B MoE |
| `model="claude-haiku-4-5"` | :8002 | Qwen3.6-27B FP8 |

SGLang also serves **OpenAI `/v1/chat/completions`** on all text endpoints, so
OpenAI SDK users can point to any port directly. Every endpoint serves both formats.

## Aggregate Capacity

Measured at OSL=2048 with reasoning parser enabled (Qwen3 native format).

| Resource | Model | Context Len | Throughput | Concurrent @8K |
|----------|-------|------------|-----------|-----------------|
| :8000 | Qwen3.6-27B FP8 | 40K | 82.8 tok/s | 29 |
| :8001 | Qwen3.6-35B-A3B MoE FP8 | 32K | 695.7 tok/s | 39 |
| :8002 | Qwen3.6-27B FP8 | 40K | 82.7 tok/s | 29 |
| **Text total** | — | — | **~861 tok/s** | **97** |
| :8188 | FLUX.2 FP8 | — | ~15-30s per 1024×1024 image | — |

### Context Length Strategy

`CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768` is deliberately configured **lower** than
SGLang's `--context-length` (40K on 27B instances). This gives an **8K safety margin**:

- Claude Code manages compaction to stay under 32K → normal operations unaffected
- If compaction lags or a request spikes over 32K → SGLang still accepts it (up to 48K)
- Result: no hard-fail 400 errors from borderline requests

**Why MoE stays at 32K:** GPU 1 has 48.6 GB KV cache (FP8 weights consume 34.5 GB).
32K keeps concurrency high (39 agents @8K). Code generation, the MoE's primary role,
rarely needs >32K context.

The two 27B instances (:8000, :8002) are identical — treat them as a pool of
~165 tok/s combined Dense capacity with 40K context headroom. For maximum
throughput, distribute requests across all three text endpoints using
`least_conn` load balancing (e.g. Nginx).

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

### Why MoE Uses a Tuned Kernel Config

Qwen3.6-35B-A3B FP8 runs on RTX 6000D (Ada Lovelace AD102, 99 KB shared memory/SM)
via a manually tuned Triton kernel configuration. SGLang's default fused MoE config
uses `num_stages=4`, which requires ~144 KB shared memory — exceeding the 99 KB limit.

The fix: `num_stages=2` with conservative block sizes, deployed automatically by
`deploy.sh` via `setup_moe_configs()`. Configs are mounted into the container at
`/moe_configs` via `SGLANG_MOE_CONFIG_DIR`. See [MOE-FP8-MIGRATION.md](MOE-FP8-MIGRATION.md) for details.

Additionally, `--max-running-requests` must equal `--cuda-graph-max-bs` (both set to 8)
to prevent the scheduler from forming batches that exceed the CUDA graph range, which
would trigger a buggy eager-mode decode path (`'DecodeMetadata' object has no attribute 'use_ragged'`).

**Result**: FP8 halves weight memory (70 GB → 34.5 GB), freeing ~35 GB for KV cache
while roughly doubling throughput (338 → 696 tok/s at 8 concurrent agents).

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

