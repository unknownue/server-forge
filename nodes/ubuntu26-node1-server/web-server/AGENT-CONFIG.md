# Agent Inference Configuration — Web Development Deployment Guide

**Date**: 2026-05-28
**Target**: ubuntu26-node1-server (4× RTX 6000D 85.6GB)
**Context**: Claude Code agent teams for web development (TypeScript, React, Node, Go, Python, SQL).

## Architecture Overview

This deployment provides **local inference endpoints** for Claude Code agents
working on web development tasks. All 4 GPUs dedicated to text inference —
no image generation overhead.

| Advantage | Applies To |
|-----------|-----------|
| No API cost per token | High-volume code generation, design iteration |
| No rate limits | Parallel agent teams |
| Data locality | Proprietary codebase stays on-prem |
| 3×27B interchangeable pool | High-concurrency cross-file architecture reasoning |

## Endpoint Topology

```
┌──────────────────────────────────────────────────────────────────┐
│                       ubuntu26-node1-server                       │
│                                                                   │
│  GPU 0: Qwen3.6-27B FP8  ──→  :8000                              │
│  GPU 1: Qwen3.6-35B-A3B   ──→  :8001  (MoE, FP8)                 │
│  GPU 2: Qwen3.6-27B FP8  ──→  :8002                              │
│  GPU 3: Qwen3.6-27B FP8  ──→  :8003                              │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Translation Proxy :8090                                     │ │
│  │  /v1/messages          ← Anthropic SDK                       │ │
│  │  /v1/chat/completions  ← OpenAI SDK (passthrough)            │ │
│  │  Routes: Qwen3.6-27B-FP8→:8000, Qwen3.6-35B-A3B-FP8→:8001  │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  API: OpenAI /v1/chat/completions + Anthropic /v1/messages       │
└──────────────────────────────────────────────────────────────────┘
```

### Quick Reference

| Port | Service | Model | Quant | Context | Tok/s | Characteristics |
|------|---------|-------|-------|---------|-------|-----------------|
| 8000 | SGLang | Qwen3.6-27B | FP8 | 40K | 82.8 | Dense, full-param reasoning, multimodal |
| 8001 | SGLang | Qwen3.6-35B-A3B | FP8 | 40K | 338.1 | MoE (35B→3B active), 4× throughput |
| 8002 | SGLang | Qwen3.6-27B | FP8 | 40K | 82.7 | Dense, identical to :8000 |
| 8003 | SGLang | Qwen3.6-27B | FP8 | 40K | 82.7 | Dense, identical to :8000 |
| 8090 | Proxy | — (translates) | — | — | — | Anthropic + OpenAI unified port |

### Model Name Routing (Proxy)

| Model Name | Routes To | Use With |
|------------|-----------|----------|
| `Qwen3.6-27B-FP8` | :8000 (default among 3×27B pool) | `ANTHROPIC_DEFAULT_OPUS_MODEL` |
| `Qwen3.6-35B-A3B-FP8` | :8001 (MoE) | `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` |
| `Qwen3-72B-FP8` | :8000 (plan-72b) | `ANTHROPIC_DEFAULT_OPUS_MODEL` |
| `claude-opus-4-7` *(alias)* | :8000 | compatibility fallback |
| `claude-sonnet-4-6` *(alias)* | :8001 | compatibility fallback |

Fuzzy matching: `35B`/`A3B`/`MoE` → :8001; `27B`/`72B`/`32B` → :8000; everything else → :8000.

## Routing Recommendations

All four endpoints serve identical APIs. Role assignment is **not enforced**
at the infrastructure level.

- **Code generation** (frontend/backend/DevOps) → prefer `:8001` (MoE, 4× throughput)
- **Architecture, DB design, security, QA** → any 27B instance (`:8000`, `:8002`, `:8003`)
- **Three 27B instances are interchangeable** — distribute across all three for
  higher concurrency rather than reserving for specific roles
- For maximum throughput, use the proxy `:8090` with an Nginx `least_conn` LB
  in front of the 27B pool

## Agent Granularity & Context Management

The 40K SGLang limit (32K Claude Code management target) is sufficient **only
when agents are properly scoped**. Design principle: **don't let a single agent
do too much at once.**

### Context Budget per Agent Type

| Agent Type | Typical Context | Headroom | Strategy |
|-----------|----------------|----------|----------|
| Code gen (single component/endpoint) | 8–15K | Plenty | Direct implementation |
| DB schema design (3-5 tables) | 10–18K | Comfortable | Single-focus design |
| API contract review | 10–16K | Comfortable | Focused review |
| Architecture review (full-stack) | 18–28K | Tight | Summarize first, then decide |
| Cross-service refactor (5+ files) | 25–32K+ | **At risk** | Split across agents |
| Security audit (data flow tracing) | 20–30K | Tight | Use summary agent |

### Work-Splitting Pattern

For tasks that exceed 32K, split across agents:

```
Wrong: One agent reviews 10 files + writes 6 modifications → overflow
Right:
  /tech-lead      → reads all files, writes architecture plan (15K)
  /frontend-dev   → implements UI changes based on plan (12K)
  /backend-dev    → implements API changes based on plan (14K)
  /db-architect   → updates schema and migrations (10K)
  /qa-engineer    → integration tests across changes (12K)
```

### When Context Nears the Limit

Signs (visible in Claude Code):
- Compaction runs more frequently
- File content references use truncated snippets
- `/clear` needed more than once per session
- Error: "Input is too long" from SGLang (rare with 40K headroom)

Mitigations, in priority order:
1. **Narrow the task** — focus on one file/component at a time
2. **Use a summary agent** — have one agent produce condensed analysis, pass to another
3. **Start a fresh session** — `/clear` resets context, compaction keeps critical parts
4. **Split into separate Claude Code sessions** — different directories, different contexts
5. **Route to a 40K-capable instance** — :8000, :8002, :8003 all support 40K
   (8K above Claude Code's 32K management target). Switch model to
   `Qwen3.6-27B-FP8` for tasks needing extra headroom

## Claude Code Configuration

All model names use **real SGLang served-model-name values**.

### Required Environment Variables

```bash
export ANTHROPIC_BASE_URL="http://localhost:8090/v1"
export ANTHROPIC_API_KEY="not-needed"
```

### Model Selection

```bash
# Opus role — complex reasoning, architecture decisions, security audit
export ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-27B-FP8"

# Sonnet role — default for most tasks (code gen, design, review)
export ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"

# Haiku role — lightweight tasks, subagents, compaction
export ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"
```

How Claude Code uses these roles:

| Role | When Used | Model | Route |
|------|-----------|-------|-------|
| Opus | Complex reasoning, architecture, security audit | Qwen3.6-27B-FP8 | :8000 (27B Dense) |
| Sonnet | Default operations, code generation, review | Qwen3.6-35B-A3B-FP8 | :8001 (MoE) |
| Haiku | Subagents, compaction, quick lookups | Qwen3.6-35B-A3B-FP8 | :8001 (MoE) |

### Model Capability Overrides

```bash
# Extended thinking — NOT supported by Qwen/SGLang
export CLAUDE_CODE_DISABLE_THINKING=1

# Prompt caching — NOT supported by local endpoints
export DISABLE_PROMPT_CACHING=1

# Context window — 32K management target, 40K on SGLang
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768
```

### Optional: Display Names

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="Qwen3.6 27B (Local)"
export ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="Qwen3.6 35B MoE (Local)"
export ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="Qwen3.6 35B MoE (Local - Fast)"
export ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES=""
export ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES=""
export ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES=""
```

### Environment Variables NOT Needed

| Variable | Why |
|----------|-----|
| `ANTHROPIC_AUTH_TOKEN` | Proxy doesn't check Authorization |
| `ANTHROPIC_SMALL_FAST_MODEL` | Deprecated — use `ANTHROPIC_DEFAULT_HAIKU_MODEL` |
| `ANTHROPIC_BEDROCK_BASE_URL` / `ANTHROPIC_VERTEX_BASE_URL` | Not using cloud providers |
| `ANTHROPIC_BETAS` / `ANTHROPIC_EXTRA_BODY` | Not needed for local models |

### Complete Configuration

```bash
# ── Endpoint ──
export ANTHROPIC_BASE_URL="http://localhost:8090/v1"
export ANTHROPIC_API_KEY="not-needed"

# ── Model mapping ──
export ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-27B-FP8"
export ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"

# ── Capability overrides ──
export CLAUDE_CODE_DISABLE_THINKING=1
export DISABLE_PROMPT_CACHING=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768
```

### Per-Project Configuration

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

```bash
# Check model detection
claude --model

# Test with a prompt
echo "Write a TypeScript function for deep object comparison." | claude -p

# Check proxy routing
docker logs ws-proxy --tail 20
```

## SDK Integration Patterns

### Pattern A: OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8001/v1",  # MoE for code gen
    api_key="not-needed",
)

response = client.chat.completions.create(
    model="Qwen3.6-35B-A3B-FP8",
    messages=[{"role": "user", "content": "Write a React hook for form validation."}],
    max_tokens=2048,
)
```

### Pattern B: Anthropic SDK (via Proxy)

```python
from anthropic import Anthropic

client = Anthropic(
    base_url="http://localhost:8090/v1",
    api_key="not-needed",
)

response = client.messages.create(
    model="Qwen3.6-35B-A3B-FP8",
    max_tokens=2048,
    system="You are a senior TypeScript developer.",
    messages=[{"role": "user", "content": "Implement a type-safe event emitter."}],
)
```

### Pattern C: Nginx Load Balancer (27B Pool)

```nginx
upstream llm_27b_pool {
    least_conn;
    server 127.0.0.1:8000;
    server 127.0.0.1:8002;
    server 127.0.0.1:8003;
}

server {
    listen 8080;
    location /v1/ {
        proxy_pass http://llm_27b_pool;
        proxy_read_timeout 600s;
    }
}
```

## Aggregate Capacity

Measured at OSL=2048 with reasoning parser enabled.

| Resource | Model | Context Len | Throughput | Concurrent @8K |
|----------|-------|------------|-----------|-----------------|
| :8000 | Qwen3.6-27B FP8 | 40K | 82.8 tok/s | 29 |
| :8001 | Qwen3.6-35B-A3B MoE FP8 | 40K | 338.1 tok/s | ~50 |
| :8002 | Qwen3.6-27B FP8 | 40K | 82.7 tok/s | 29 |
| :8003 | Qwen3.6-27B FP8 | 40K | 82.7 tok/s | 29 |
| **Text total** | — | — | **~586 tok/s** | **~137** |

### Context Length Strategy

All instances use unified `--context-length 40960` (40K). `CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768`
is configured **lower** than SGLang's limit, giving an **8K safety margin**:
Claude Code manages compaction to stay under 32K; if compaction lags, SGLang
still accepts (up to 40K) without hard-fail 400 errors.

MoE FP8 reduces weights from 70 GB (BF16) to 35 GB, freeing 35 GB for KV Cache
(13.6 → 48.6 GB, +257%). All four instances are now interchangeable with
uniform 40K context-length.

The three 27B instances (:8000, :8002, :8003) are an interchangeable pool
of ~248 tok/s Dense capacity with 40K context headroom.

## Deployment Commands

```bash
bash deploy.sh                        # Default: 3×27B + MoE
bash deploy.sh plan-72b               # 72B TP=2 + 2×27B
bash deploy.sh plan-reasoning         # R1-32B CoT + MoE + 2×27B
bash stop.sh                          # Stop all services
```

## Testing

### Smoke Test

```bash
for port in 8000 8001 8002 8003; do
  curl -s http://localhost:$port/v1/models | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])"
done
```

### Multi-Agent Simulation

```bash
# OpenAI format
bash test/simulate-agents.sh http://localhost:8000

# Anthropic format (via proxy)
API_FORMAT=anthropic bash test/simulate-agents.sh http://localhost:8090
```

### Throughput Benchmark

```bash
docker run --rm --network host \
  -v /data/work/benchmarks:/benchmarks \
  aiperf:latest \
  --endpoint http://localhost:8000/v1/chat/completions \
  --model Qwen3.6-27B-FP8 \
  --osl 2048 --num-prompts 64
```
