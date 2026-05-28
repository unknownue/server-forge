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
┌──────────────────────────────────────────────────────────────────┐
│                       ubuntu26-node1-server                       │
│                                                                   │
│  GPU 0: Qwen3.6-27B FP8  ──→  :8000                              │
│  GPU 1: Qwen3.6-35B-A3B   ──→  :8001  (MoE, BF16)                │
│  GPU 2: Qwen3.6-27B FP8  ──→  :8002                              │
│  GPU 3: FLUX.2 FP8        ──→  :8188  (ComfyUI)                   │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Translation Proxy :8090                                     │ │
│  │  /v1/messages          ← Anthropic SDK                       │ │
│  │  /v1/chat/completions  ← OpenAI SDK (passthrough)            │ │
│  │  Routes: claude-opus→:8000, claude-sonnet→:8001,             │ │
│  │          claude-haiku→:8002                                  │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  API: OpenAI /v1/chat/completions + Anthropic /v1/messages       │
│  Image: ComfyUI REST API /prompt + /history                       │
└──────────────────────────────────────────────────────────────────┘
```

All text endpoints expose an **OpenAI-compatible API** at `/v1/chat/completions`.
The **translation proxy** at `:8090` adds **Anthropic Messages API** (`/v1/messages`)
support. Both formats can be used simultaneously.

### Quick Reference

| Port | Service | Model | Quant | Tok/s (4 agents) | Characteristics |
|------|---------|-------|-------|---------------------|-----------------|
| 8000 | SGLang | Qwen3.6-27B | FP8 | 82.8 | Dense, full-param reasoning, multimodal |
| 8001 | SGLang | Qwen3.6-35B-A3B | BF16 | 338.1 | MoE (35B→3B active), 4× throughput |
| 8002 | SGLang | Qwen3.6-27B | FP8 | 82.7 | Dense, full-param reasoning, multimodal |
| 8090 | Proxy | — (translates) | — | — | Anthropic + OpenAI unified port |
| 8188 | ComfyUI | FLUX.2 FP8 | FP8m | — | Image generation |

### Model Name Routing (Proxy)

The proxy resolves model names with this priority:
1. **Exact match** in the table below
2. **Fuzzy match** — name contains `35B`/`A3B`/`MoE` → :8001; `27B`/`72B`/`32B` → :8000
3. **Fallback** → :8000 (default)

| Model Name | Routes To | Local Model | Use With |
|------------|-----------|-------------|----------|
| `Qwen3.6-27B-FP8` | :8000 | Qwen3.6-27B Dense | `ANTHROPIC_DEFAULT_OPUS_MODEL` |
| `Qwen3.6-35B-A3B-FP8` | :8001 | Qwen3.6-35B-A3B MoE | `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` |
| `Qwen3-72B-FP8` | :8000 | Qwen3-72B Dense (plan-72b) | `ANTHROPIC_DEFAULT_OPUS_MODEL` |
| `claude-opus-4-7` *(alias)* | :8000 | same as Qwen3.6-27B-FP8 | compatibility fallback |
| `claude-sonnet-4-6` *(alias)* | :8001 | same as Qwen3.6-35B-A3B-FP8 | compatibility fallback |
| `claude-haiku-4-5` *(alias)* | :8002 | Qwen3.6-27B Dense | compatibility fallback |

**Recommendation**: Use real model names (`Qwen3.6-27B-FP8`, `Qwen3.6-35B-A3B-FP8`)
for Claude Code configuration. Anthropic aliases exist only for backward compatibility.

## Routing Recommendations

Role assignment is **not enforced at the infrastructure level**. All three text
endpoints serve the same API and accept any prompt. Downstream consumers (CCGS
agents, load balancers, orchestration scripts) decide which endpoint to call.

**Simple starting point:**

- **Code-heavy tasks** → prefer `:8001` (MoE, 4× throughput, wider code knowledge)
- **Design, analysis, multimodal** → any 27B endpoint (`:8000` or `:8002`)
- **High concurrency** → use the proxy `:8090` with `least_conn` LB, or
  distribute across all 3 endpoints

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

Configure Claude Code to route through the translation proxy. All model names
use **real SGLang served-model-name values**, not Anthropic aliases.

### Required Environment Variables

```bash
# API endpoint — must point to the proxy, NOT directly to SGLang
export ANTHROPIC_BASE_URL="http://localhost:8090/v1"

# API key — any non-empty string, proxy does not validate
export ANTHROPIC_API_KEY="not-needed"
```

### Model Selection

Map Claude Code's model roles to local models. All values use real model names
that the proxy routes to appropriate backends:

```bash
# Opus role — complex multi-step reasoning, architecture decisions
# Routes to :8000 (Qwen3.6-27B Dense, full-param reasoning)
export ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-27B-FP8"

# Sonnet role — default for most tasks, balanced speed/quality
# Routes to :8001 (Qwen3.6-35B-A3B MoE, 4× throughput)
export ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"

# Haiku role — lightweight tasks, subagents, compaction, background work
# Routes to :8001 (MoE, fast turnaround)
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
| `ANTHROPIC_EXTRA_BODY` | Proxy handles all translation |

### Complete Configuration

All essential vars in one block — add to `~/.bashrc` or a per-project `.env`:

```bash
# ── Endpoint ──
export ANTHROPIC_BASE_URL="http://localhost:8090/v1"
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
    "ANTHROPIC_BASE_URL": "http://localhost:8090/v1",
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

After configuration, verify Claude Code is routing through the proxy:

```bash
# Check which models Claude Code detects
claude --model

# Test with a simple prompt (non-interactive mode)
echo "Say hello in one word." | claude -p --model Qwen3.6-35B-A3B-FP8

# Or with role aliases
echo "Say hello." | claude -p --model sonnet
```

The proxy logs each request to stdout — check Docker logs to confirm routing:
```bash
docker logs gs-proxy --tail 20
```

## SDK Integration Patterns

For direct SDK usage (bypassing Claude Code), the proxy accepts both formats.

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

### Pattern D: Anthropic SDK (via Translation Proxy)

Use the Anthropic Python SDK to call local endpoints through the translation proxy
at `:8090`. The proxy translates Anthropic Messages API ↔ OpenAI Chat Completions
transparently, including streaming and multimodal content.

```python
# Example: gameplay-programmer calls MoE endpoint via Anthropic SDK
from anthropic import Anthropic

client = Anthropic(
    base_url="http://ubuntu26-node1-server:8090/v1",
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

The proxy also supports **OpenAI passthrough** at `/v1/chat/completions`, so
OpenAI SDK users can point to the same port `:8090` instead of individual
service ports. Model name routing works identically for both formats.

## Aggregate Capacity

Measured at OSL=2048 with reasoning parser enabled (Qwen3 native format).

| Resource | Model | Context Len | Throughput | Concurrent @8K |
|----------|-------|------------|-----------|-----------------|
| :8000 | Qwen3.6-27B FP8 | 40K | 82.8 tok/s | 29 |
| :8001 | Qwen3.6-35B-A3B MoE BF16 | 32K | 338.1 tok/s | 39 |
| :8002 | Qwen3.6-27B FP8 | 40K | 82.7 tok/s | 29 |
| **Text total** | — | — | **~504 tok/s** | **97** |
| :8188 | FLUX.2 FP8 | — | ~15-30s per 1024×1024 image | — |

### Context Length Strategy

`CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768` is deliberately configured **lower** than
SGLang's `--context-length` (40K on 27B instances). This gives an **8K safety margin**:

- Claude Code manages compaction to stay under 32K → normal operations unaffected
- If compaction lags or a request spikes over 32K → SGLang still accepts it (up to 48K)
- Result: no hard-fail 400 errors from borderline requests

**Why MoE stays at 32K:** GPU 1 has only 13.6 GB KV cache (BF16 weights consume
70 GB). 40K would reduce concurrency to ~1. Keep 32K for high-throughput short
requests — code generation, the MoE's primary role.

The two 27B instances (:8000, :8002) are identical — treat them as a pool of
~165 tok/s combined Dense capacity with 40K context headroom. For maximum
throughput, distribute requests across all three text endpoints using the proxy
at `:8090` with `least_conn` balancing.

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

