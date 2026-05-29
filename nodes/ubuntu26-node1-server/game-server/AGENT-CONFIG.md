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
│  GPU 0: Qwen3.6-27B FP8  ──→  :8000  (80K Long, Anthropic+OpenAI)│
│  GPU 1: Qwen3.6-35B-A3B   ──→  :8001  (65K MoE, Anthropic+OpenAI)│
│  GPU 2: Qwen3.6-27B FP8  ──→  :8002  (40K Fast, Anthropic+OpenAI)│
│  GPU 3: FLUX.2 FP8        ──→  :8188  (ComfyUI)                   │
│                                                                   │
│  Native Anthropic /v1/messages + OpenAI /v1/chat/completions.     │
│  No translation proxy needed. SGLang patches auto-mounted.        │
└──────────────────────────────────────────────────────────────────┘
```

### Quick Reference

| Port | Model | Context | Role | Routing |
|------|-------|---------|------|---------|
| **:8001** | Qwen3.6-35B-A3B-FP8 (MoE) | 65K | **Primary** — main session, code gen, default for all CC roles | `ANTHROPIC_BASE_URL` |
| :8000 | Qwen3.6-27B-FP8-Long | 80K | Deep context — director subagents, main session overflow | Explicit model override |
| :8002 | Qwen3.6-27B-FP8 | 40K | Throughput — QA, quick edits, single-file subagents | Explicit model override |
| :8188 | FLUX.2 FP8 (ComfyUI) | — | Image generation | Direct API call |

**Routing for CCGS agents:**

| Task | Model to use | Why |
|------|-------------|-----|
| Main CC session | MoE (:8001) | 8× throughput, 65K, ~42K usable after system overhead |
| Director subagents | Long (:8000) | No CC overhead → ~80K usable for multi-GDD synthesis |
| Code gen subagents | MoE (:8001) | Speed; Long (:8000) if MoE saturated |
| QA / quick subagents | Fast (:8002) | 40K plenty for single-task agents, max concurrency |

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

# ── Capability overrides (unsupported by local models) ──
export CLAUDE_CODE_DISABLE_THINKING=1
export DISABLE_PROMPT_CACHING=1

# ── Context compaction (65K window, compact at 85% ≈ 55K) ──
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=65536
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
    "CLAUDE_CODE_DISABLE_THINKING": "1",
    "DISABLE_PROMPT_CACHING": "1",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "65536",
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

| Endpoint | SGLang Context | Main session (after 23K) | Subagent (after prompt) |
|----------|---------------|-------------------------|------------------------|
| :8001 (MoE) | 65,536 | ~42K | ~60-64K |
| :8000 (Long) | 81,920 | ~58K | ~73-80K |
| :8002 (Fast) | 40,960 | ~18K | ~37-39K |

### Context Budget per Agent Type (subagents)

| Agent Type | Typical Content | Fast (40K) | MoE (65K) | Long (80K) |
|-----------|----------------|-----------|----------|-----------|
| QA / single-file edit | 5–15K | Comfortable | Comfortable | Comfortable |
| Code gen | 8–20K | Comfortable | Comfortable | Comfortable |
| Architecture review | 18–30K | Tight | Comfortable | Comfortable |
| Director synthesis | 30–55K | **At risk** | Tight | Comfortable |

### Compaction

- `CLAUDE_CODE_AUTO_COMPACT_WINDOW=65536` — treat 65K as compaction target
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=85` — compact at ~55K used
- When overflowing to Long (:8000), set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=81920`
- **Do NOT use `CLAUDE_CODE_MAX_CONTEXT_TOKENS`** — requires `DISABLE_COMPACT=1`, which disables compaction entirely

### Three-Tier Design

| Endpoint | Context | max-running | KV/req (full) | Design rationale |
|----------|---------|------------|---------------|-----------------|
| Long (:8000) | 81,920 | 4 | 20.5 GB | 27B Dense, more VRAM for context vs throughput |
| MoE (:8001) | 65,536 | 4 | 16.8 GB | 35B→3B active, 8× throughput, 35B knowledge width |
| Fast (:8002) | 40,960 | auto | 10.5 GB | Higher concurrency, enough for single-task subagents |

**Aggregate**: ~861 tok/s text throughput, 11-13 concurrent agents (mixed loads).

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

### Reasoning Parser
`--reasoning-parser qwen3` spends ~30-50% output tokens on internal reasoning.
Acceptable for code gen (improves quality). Disable for fast iteration.

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
