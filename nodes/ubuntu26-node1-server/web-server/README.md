# Web Studio Server — Multi-GPU Deployment for Web Development

**Date**: 2026-05-28
**Hardware**: ubuntu26-node1-server (4× RTX 6000D 85.6GB, Intel Xeon w7-3545 48T, 247GB RAM)
**SGLang Image**: `voipmonitor/sglang:test-cu132` (CUDA 13.2)

> **Claude Code Integration**: See [AGENT-CONFIG.md](AGENT-CONFIG.md) for Claude Code
> environment variable configuration, model routing, agent roles for web development,
> and context management strategy.

## Overview

Multi-model, 4-GPU text inference service for web development workflows. All 4 GPUs
dedicated to text inference — no image generation. Three interchangeable 27B Dense
instances form a pool for architectural reasoning, DB design, UI/UX, security audit.
One 35B-A3B MoE instance handles high-throughput code generation.

| Capability | Model | Status |
|-----------|-------|--------|
| Text inference (×4) | 3× Qwen3.6-27B FP8 + Qwen3.6-35B-A3B MoE | Deployed |
| API translation | Anthropic↔OpenAI Proxy (:8090) | Deployed |

## GPU Topology

| GPU | Model | Type | Context | Characteristics |
|-----|-------|------|---------|-----------------|
| 0 | Qwen3.6-27B FP8 | Dense | 40K | Full-param reasoning, multimodal |
| 1 | Qwen3.6-35B-A3B FP8 | MoE | 40K | 35B knowledge, 3B compute/token, 4× throughput |
| 2 | Qwen3.6-27B FP8 | Dense | 40K | Identical to GPU 0 |
| 3 | Qwen3.6-27B FP8 | Dense | 40K | Identical to GPU 0 |

GPUs 0, 2, 3 are **interchangeable** — all three run the same 27B model with
40K context. Distribute load across them for higher concurrency. The MoE on
GPU 1 is optimized for high-throughput code generation.

## Why 3×27B + 1×MoE

Web development has heavier cross-file dependencies than game development:
- Frontend → API contract → DB schema → type definitions are tightly coupled
- Architecture decisions require reasoning across the full stack
- Security audits need deep analysis of data flow across boundaries

Three 27B Dense instances provide **interchangeable capacity** for these
reasoning-heavy tasks. The single MoE instance provides **4× throughput**
for code generation (TypeScript, React, Node, Go, Python, SQL).

## Deployment

### Default Plan (one-click)

```bash
bash nodes/ubuntu26-node1-server/web-server/deploy.sh
```

```
GPU 0: Qwen3.6-27B    FP8  TP=1 → :8000
GPU 1: Qwen3.6-35B-A3B FP8 TP=1 → :8001 (MoE 35B→3B active)
GPU 2: Qwen3.6-27B    FP8  TP=1 → :8002
GPU 3: Qwen3.6-27B    FP8  TP=1 → :8003
Proxy: anthropic-proxy  CPU     → :8090  Anthropic↔OpenAI
```

| Metric | Value |
|--------|-------|
| Total text throughput | ~586 tok/s (3×82.8 + 338.1) |
| 27B (FP8) per-instance | 82.8 tok/s |
| 35B-A3B (FP8) | 338.1 tok/s (4× 27B) |
| API formats | OpenAI + Anthropic (via :8090 proxy) |
| Image generation | Not included |

### Alternative Plans

```bash
bash nodes/ubuntu26-node1-server/web-server/deploy.sh plan-72b       # 72B TP=2 + 2×27B
bash nodes/ubuntu26-node1-server/web-server/deploy.sh plan-reasoning # R1-32B CoT + MoE + 2×27B
```

### Plan 72B — Largest Dense Model

Download `Qwen/Qwen3-72B` first.

```
GPU 0,1: Qwen3-72B   FP8 TP=2 → :8000
GPU 2:   Qwen3.6-27B FP8 TP=1 → :8001
GPU 3:   Qwen3.6-27B FP8 TP=1 → :8002
```

### Plan Reasoning — Deep CoT + MoE

Download `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` first.

```
GPU 0: R1-Distill-32B  FP8 TP=1 → :8000
GPU 1: Qwen3.6-35B-A3B FP8 TP=1 → :8001 (MoE)
GPU 2: Qwen3.6-27B     FP8 TP=1 → :8002
GPU 3: Qwen3.6-27B     FP8 TP=1 → :8003
```

## Concurrency Analysis

All numbers assume FP8 KV cache (`--kv-cache-dtype fp8_e5m2`) and actual usage
at typical prompt lengths (not max context-length).

### Per-Model KV Structure

| Model | FP8 Weights | KV Cache | KV/token(fp8) | Concurrent @4K | Concurrent @8K |
|-------|------------|----------|---------------|-----------------|-----------------|
| Qwen3.6-27B | 26 GB | 57.6 GB | 256 KB | 58 | 29 |
| Qwen3.6-35B-A3B | 35 GB (FP8) | 48.6 GB | 256 KB | 97 | 48 |
| Qwen3-72B | 72 GB (TP2) | 47.6 GB/each | 512 KB | 76 | 38 |
| R1-Distill-32B | 31 GB | 52.6 GB | 256 KB | 106 | 53 |

### Default Plan Concurrency

```
                Context  KV Cache     Max Concurrent
                Limit    per GPU      @4K     @8K
GPU 0: 27B      40K      57.6 GB      58      29
GPU 1: 35B MoE  40K      48.6 GB      97      48
GPU 2: 27B      40K      57.6 GB      58      29
GPU 3: 27B      40K      57.6 GB      58      29
─────────────────────────────────────────────────
TOTAL (text)                          271     135
```

At typical web dev prompt lengths (2-4K tokens), effective concurrency is
2-4× higher. The default plan handles **hundreds** of simultaneous agent
requests.

## Routing Recommendations

Role assignment is handled by downstream consumers. All text endpoints serve
identical APIs.

| Endpoint | Model | Throughput | Typical Fit |
|----------|-------|-----------|-------------|
| :8000, :8002, :8003 | Qwen3.6-27B FP8 | 82.8 tok/s each | Architecture, DB design, UI/UX, security, QA |
| :8001 | Qwen3.6-35B-A3B MoE | 338.1 tok/s | Frontend/backend code generation, DevOps config |
| :8090 (proxy) | — | — | Unified entry, Anthropic + OpenAI formats |

- :8000, :8002, :8003 are **interchangeable** — distribute load across all three
- Prefer :8001 for code-heavy, high-volume work (4× throughput)
- **Claude Code setup**: set `ANTHROPIC_BASE_URL=http://localhost:8090/v1` and
  `ANTHROPIC_DEFAULT_SONNET_MODEL=Qwen3.6-35B-A3B-FP8` — full config in
  [AGENT-CONFIG.md](AGENT-CONFIG.md#claude-code-configuration)

## Quick Start

```bash
# 1. Download models (one-time, ~120 GB)
bash scripts/lib/download-model.sh

# 2. Deploy
bash nodes/ubuntu26-node1-server/web-server/deploy.sh

# 3. Test endpoints (OpenAI format)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3.6-27B","messages":[{"role":"user","content":"Hello"}],"max_tokens":32}'

# 4. Test endpoints (Anthropic format, via proxy :8090)
curl http://localhost:8090/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3.6-35B-A3B-FP8","max_tokens":32,"messages":[{"role":"user","content":"Hello"}]}'

# 5. Stop all services
bash nodes/ubuntu26-node1-server/web-server/stop.sh
```

## Design Decisions

1. **No image generation** — web development doesn't require game art assets.
   GPU 3 reallocated to text inference (+50% 27B Dense capacity).

2. **3× interchangeable 27B pool** — web dev has heavier cross-file reasoning
   needs than game dev. More Dense instances = more concurrent deep analysis.

3. **FP8 runtime quantization** on all models — halves memory, doubles
   instance density. MoE FP8 reduces weights 70→35 GB, freeing 35 GB for
   KV Cache (13.6→48.6 GB, +257% concurrency).

4. **MoE for code generation** — 35B-A3B provides wider knowledge (35B params)
   with fast inference (3B compute/token). Primary backend for frontend/backend
   code gen.

5. **40K context on all instances** — unified limit, 8K safety margin above
   Claude Code's 32K management target. No per-instance special cases.

6. **`--user $(id -u):$(id -g)`** on all containers — avoids Docker root
   ownership issues on host-mounted cache directories.

## Related Deployments

- [Game Studio Server](../game-server/README.md) — game development with
  FLUX.2 image generation on GPU 3
- [AGENT-CONFIG.md](../game-server/AGENT-CONFIG.md) — reference for Claude
  Code configuration patterns (shared between deployments)

## File Structure

```
web-server/
├── README.md                    # Architecture doc + quick start
├── AGENT-CONFIG.md              # Claude Code config + web dev agent roles
├── deploy.sh                    # One-click deployment
├── stop.sh                      # Stop all containers
├── config/
│   ├── services.yaml            # Service definitions and routing table
│   └── proxy.dockerfile         # Anthropic↔OpenAI translation proxy image
├── serve/
│   ├── serve-text.sh            # Start single text model instance
│   └── anthropic-proxy.py       # API translation proxy (Anthropic↔OpenAI)
└── test/
    └── simulate-agents.sh       # Multi-agent workload simulation (web prompts)
```
