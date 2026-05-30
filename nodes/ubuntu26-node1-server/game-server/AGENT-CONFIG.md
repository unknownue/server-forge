# Agent Inference Configuration — Claude Code Game Studios Deployment Guide

**Date**: 2026-05-29
**Target**: ubuntu26-node1-server (4× RTX 6000D 85.6GB)
**Context**: [Claude Code Game Studios](https://github.com/Donchitos/Claude-Code-Game-Studios) (CCGS) —
49-agent game development studio template for Claude Code.

Advantages of local endpoints: no API cost, no rate limits, data locality, specialized models (MoE for code, FLUX.2 for art).

## Endpoint Topology

```
┌──────────────────────────────────────────────────────────────────┐
│                       ubuntu26-node1-server                       │
│                                                                   │
│  GPU 0: Qwen3.6-27B FP8  ──→  :8000  (128K solo agent)           │
│  GPU 1: Qwen3.6-35B-A3B   ──→  :8001  (80K MoE, 2 concurrent)    │
│  GPU 2: Qwen3.6-27B FP8  ──→  :8002  (48K dual subagent)         │
│  GPU 3: FLUX.2 FP8        ──→  :8188  (ComfyUI)                   │
│                                                                   │
│  --reasoning-parser qwen3 active. Thinking OFF by default         │
│  (enable_thinking=false). Opt-in: thinking: {type: "enabled"}.    │
└──────────────────────────────────────────────────────────────────┘
```

### Quick Reference

| Port | Model | Context | Concurrency | Role | Routing |
|------|-------|---------|------------|------|---------|
| **:8001** | Qwen3.6-35B-A3B-FP8 (MoE) | 80K | 2 | **Primary** — main session, code gen | `ANTHROPIC_BASE_URL` |
| :8000 | Qwen3.6-27B-FP8-Long | 128K | 1 | Solo agent — director synthesis, deep overflow | Explicit model override |
| :8002 | Qwen3.6-27B-FP8 | 48K | 2 | Throughput — QA, quick edits, single-file | Explicit model override |
| :8188 | FLUX.2 FP8 (ComfyUI) | — | — | Image generation | Direct API call |

**Routing for CCGS agents:**

| Task | Model to use | Why |
|------|-------------|-----|
| Main CC session | MoE (:8001) | 8× throughput, 80K context, 2 concurrent |
| Director subagents | Long (:8000) | 128K solo for multi-GDD synthesis |
| Code gen subagents | MoE (:8001) | Long (:8000) if MoE saturated |
| QA / quick subagents | Fast (:8002) | 48K, dual concurrent |

## Claude Code Configuration

SGLang serves Anthropic Messages API natively. Two small patches
([config/sglang-patches/](config/sglang-patches/)) handle `role=system` and
`thinking` block compatibility. `deploy.sh` mounts them automatically.

### Complete Environment

```bash
# ── Endpoint (default to MoE) ──
export ANTHROPIC_BASE_URL="http://localhost:8001"
export ANTHROPIC_API_KEY="not-needed"

# ── Model mapping — all roles route to MoE by default ──
export ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-35B-A3B-FP8"
export ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"

# ── Thinking: OFF by default at serving layer. CLAUDE_CODE_DISABLE_THINKING
#    is optional/no-op. Opt-in per-request: thinking: {type: "enabled"}.
export DISABLE_PROMPT_CACHING=1

# ── Context compaction (80K window matching default :8001, compact at 85% ≈ 68K) ──
#    When using :8000 (128K): set this to 131072 for full context utilization.
#    When using :8002 (48K):  serving layer auto-caps max_tokens to prevent overflow.
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=81920
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=85

# ── Optional: friendly model names ──
export ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="Qwen3.6 35B MoE"
export ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="Qwen3.6 35B MoE"
export ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="Qwen3.6 35B MoE"
```

**Per-project** (`.claude/settings.json`):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8001",
    "ANTHROPIC_API_KEY": "not-needed",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "Qwen3.6-35B-A3B-FP8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "Qwen3.6-35B-A3B-FP8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "Qwen3.6-35B-A3B-FP8",
    "DISABLE_PROMPT_CACHING": "1",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "81920",
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "85"
  }
}
```

**Don't set**: `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BETAS`, `ANTHROPIC_SMALL_FAST_MODEL` (deprecated),
or any Bedrock/Vertex/Foundry vars — unnecessary for local endpoints.

### Verification

```bash
claude --model
echo "Say hello." | claude -p --model Qwen3.6-35B-A3B-FP8
docker logs gs-35b-moe-code --tail 20
```

## Context Strategy

### Subagent vs Main Session

Claude Code's own system prompt and tool definitions consume ~23K tokens.
This overhead applies to the **main session** but **NOT to subagents** —
subagents only load their custom prompt (~1-8K).

| Endpoint | SGLang Context | Main session (after 23K) | /start (34K overhead) | Subagent (1-8K) |
|----------|---------------|-------------------------|----------------------|-----------------|
| :8001 (MoE) | 81,920 | ~58K | ~47K | ~73-80K |
| :8000 (Long) | 131,072 | ~108K | ~97K | ~123-130K |
| :8002 (Fast) | 49,152 | ~26K* | ~15K* | ~41-48K |

*Serving layer auto-caps max_tokens to prevent context overflow.

### Context Budget per Agent Type (subagents)

| Agent Type | Typical Content | Fast (40K) | MoE (65K) | Long (80K) |
|-----------|----------------|-----------|----------|-----------|
| QA / single-file edit | 5–15K | Comfortable | Comfortable | Comfortable |
| Code gen | 8–20K | Comfortable | Comfortable | Comfortable |
| Architecture review | 18–30K | Tight | Comfortable | Comfortable |
| Director synthesis | 30–55K | **At risk** | Tight | Comfortable |

### Compaction

- `CLAUDE_CODE_AUTO_COMPACT_WINDOW=81920` — matches default endpoint :8001 (80K)
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=85` — compact at ~68K used
- When overflowing to :8000 (128K): `export CLAUDE_CODE_AUTO_COMPACT_WINDOW=131072`
- When switching to :8002 (48K): no config change needed — serving layer auto-caps max_tokens
- **Do NOT use `CLAUDE_CODE_MAX_CONTEXT_TOKENS`** — requires `DISABLE_COMPACT=1`, which disables compaction entirely

### Three-Tier Design

| Endpoint | Context | max_running | KV pool | Max usage | Design rationale |
|----------|---------|------------|---------|-----------|-----------------|
| Long (:8000) | 131,072 | 1 | 689K | 131K (19%) | 27B Dense. Solo agent, full context, no contention |
| MoE (:8001) | 81,920 | 2 | 1965K | 164K (8%) | 35B→3B active. Tiny KV per token, massive headroom |
| Fast (:8002) | 49,152 | 2 | 689K | 98K (14%) | 27B Dense. Dual subagent, good headroom |

**Aggregate**: ~861 tok/s text throughput, up to 5 concurrent requests (1+2+2).

## Deployment Commands

```bash
bash nodes/ubuntu26-node1-server/game-server/deploy.sh              # Default plan
bash nodes/ubuntu26-node1-server/game-server/deploy.sh plan-72b      # 72B TP=2 coordinator
bash nodes/ubuntu26-node1-server/game-server/deploy.sh plan-reasoning # R1-Distill-32B coordinator
bash nodes/ubuntu26-node1-server/game-server/stop.sh                 # Stop all
```

## Hardware Constraints

### MoE Kernel Config (RTX 6000D, 99 KB shared memory/SM)
SGLang default fused MoE `num_stages=4` needs ~144 KB → exceeds 99 KB limit.
Fix: `num_stages=2` with conservative block sizes via `setup_moe_configs()`
in `deploy.sh`. Mounted at `/moe_configs` via `SGLANG_MOE_CONFIG_DIR`.
See [MOE-FP8-MIGRATION.md](MOE-FP8-MIGRATION.md).

`--max-running-requests` must equal `--cuda-graph-max-bs` (both 8 for MoE)
to prevent eager-mode decode path bug.

### Page Size
Qwen3 GDN/Mamba hybrid requires auto page size. `--page-size 64` causes:
`AssertionError: Page size must be 1 for MambaRadixCache v1`.

### Tool Calling

All endpoints run `--tool-call-parser qwen3_coder`, which parses Qwen3.6's
native XML tool call format (`<tool_call><function=n><parameter=p>v</parameter></function></tool_call>`)
into structured tool calls. The Anthropic conversion layer maps them to
standard `tool_use` content blocks.

```bash
# Tool calling works via the Anthropic endpoint
curl -s http://localhost:8001/v1/messages \
  -H "Content-Type: application/json" -H "x-api-key: dummy" \
  -d '{"model":"Qwen3.6-35B-A3B-FP8","max_tokens":512,
       "tools":[{"name":"Read","description":"Read a file",
                 "input_schema":{"type":"object","properties":{"file_path":{"type":"string"}}}}],
       "messages":[{"role":"user","content":"Read README.md"}]}'
# → content: [tool_use {name: "Read", input: {file_path: "README.md"}}]
```

This enables Claude Code's full skill/tool ecosystem (AskUserQuestion, Read,
Write, Bash, etc.) on local Qwen3 endpoints.

### Thinking Mode & Content Guarantee

Qwen3 models are trained to think internally. Without control, this consumes
30-50% of output tokens on reasoning. The Anthropic serving layer **defaults
thinking to OFF** (`enable_thinking: false`) — all output tokens go directly
to content. No token waste.

The server keeps `--reasoning-parser qwen3` for clean thinking/content
separation when thinking IS explicitly opted-in.

```bash
# Default: thinking off, all tokens to output (100% token efficiency)
curl -s http://localhost:8001/v1/messages \
  -H "Content-Type: application/json" -H "x-api-key: dummy" \
  -d '{"model":"x","max_tokens":256,
       "messages":[{"role":"user","content":"Write a quick sort."}]}'

# Opt-in: enable thinking with optional budget
curl -s http://localhost:8001/v1/messages \
  -H "Content-Type: application/json" -H "x-api-key: dummy" \
  -d '{"model":"x","max_tokens":4096,
       "thinking":{"type":"enabled","budget_tokens":1024},
       "messages":[{"role":"user","content":"Design a game inventory system."}]}'
```

| Parameter | Effect | Token efficiency |
|-----------|--------|-----------------|
| *(default)* | Thinking off, direct output | 100% |
| `thinking: {type: "enabled"}` | Thinking on | 50-70% |
| `thinking: {type: "enabled", budget_tokens: N}` | Thinking on with token cap | ≥ (max_tokens - N) / max_tokens |

**Content guarantee**: When thinking is enabled and consumes all max_tokens,
the serving layer falls back to exposing thinking content as text. Clients
never receive an empty response.

### Streaming Strategy

| Scenario | Streaming | Reason |
|----------|-----------|--------|
| Main CC session (interactive) | ✅ `stream: true` | Real-time user feedback is essential |
| All subagents (programmatic) | ❌ `stream: false` | Output consumed by code, not humans |

### Per-Request Control

`thinking: {type: "disabled"}` is no longer needed for disabling — it's the
default. Use `thinking: {type: "enabled"}` to opt back in when needed
(complex code gen, director synthesis).

Works with both `stream: true` and `stream: false`.

## SDK Integration

All endpoints serve Anthropic `/v1/messages` and OpenAI `/v1/chat/completions` natively.

### Anthropic SDK (Claude Code compatible)

```python
from anthropic import Anthropic

client = Anthropic(base_url="http://localhost:8001", api_key="not-needed")
response = client.messages.create(
    model="claude-sonnet-4-6",  # routes to MoE
    max_tokens=2048,
    messages=[{"role": "user", "content": "Write an inventory system."}],
)
# Streaming: client.messages.stream(...)
# Multimodal: pass base64 images in content blocks
```

### OpenAI SDK

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8001/v1", api_key="not-needed")
```

### Nginx Load Balancer (optional)

```nginx
upstream llm_backend {
    least_conn;
    server 127.0.0.1:8000;
    server 127.0.0.1:8001;
    server 127.0.0.1:8002;
}
server {
    listen 8080;
    location /v1/ { proxy_pass http://llm_backend; proxy_read_timeout 600s; }
}
```

## Testing

```bash
# Smoke test all endpoints
for port in 8000 8001 8002; do
  curl -s http://localhost:$port/v1/models | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])"
done
curl -s http://localhost:8188/system_stats -o /dev/null -w "ComfyUI: HTTP %{http_code}\n"

# Multi-agent simulation (4 agents × 10 req @OSL=2048)
for agent in $(seq 1 4); do
  for req in $(seq 1 10); do
    curl -s http://localhost:8001/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen3.6-35B-A3B-FP8","messages":[{"role":"user","content":"Write a GDScript function for saving game state."}],"max_tokens":2048}' &
  done
done
wait
```
