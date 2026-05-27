# Game Studio Server — Multi-GPU Deployment for Claude Code Agent Teams

**Date**: 2026-05-27
**Hardware**: ubuntu26-node1-server (4× RTX 6000D 85.6GB, Intel Xeon w7-3545 48T, 247GB RAM)
**SGLang Image**: `voipmonitor/sglang:test-cu132` (CUDA 13.2, Blackwell SM120)

> **CCGS Integration**: See [AGENT-CONFIG.md](AGENT-CONFIG.md) for the complete
> Claude Code Game Studios agent-to-endpoint mapping, performance budgets per
> workflow, and integration patterns.

## Overview

Multi-model, multi-GPU inference service supporting Claude Code Agent Teams (49 agents).
27B Dense models use FP8 runtime quantization. 35B-A3B MoE runs BF16 (hardware limitation, see below).
Image generation via ComfyUI + FLUX.2 FP8 on dedicated GPU.

| 能力 | 负责模型 | 状态 |
|------|---------|------|
| 项目统筹、架构规划 | Qwen3.6-27B FP8 (GPU 0) | ✅ 已部署 |
| 代码生成主力 | Qwen3.6-35B-A3B BF16 (GPU 1) | ✅ 已部署 |
| 多模态 + 深度推理 | Qwen3.6-27B FP8 (GPU 2) | ✅ 已部署 |
| 图像生成（游戏美术） | FLUX.2 FP8 via ComfyUI (GPU 3) | ✅ 已部署 |

## Why This Topology

### 2× Dense 27B + 1× MoE 35B-A3B

After evaluating 4B models for fast iteration, the conclusion is that **4B models don't add value
for agent-driven development**. IDE tooling (LSP, linter, formatter) handles syntax fixes faster
and more reliably. A 4B agent producing low-quality diffs that need rework by a larger model is
a net negative in both time and token cost.

Instead, we use three capable models on GPUs 0-2:

| GPU | Model | Type | Role |
|-----|-------|------|------|
| 0 | Qwen3.6-27B FP8 | Dense | Project coordination, architecture, multimodal (screenshot/UI review) |
| 1 | Qwen3.6-35B-A3B BF16 | MoE | Code generation powerhouse (35B knowledge, 3B compute/token) |
| 2 | Qwen3.6-27B FP8 | Dense | Multimodal + deep reasoning + QA validation |

### Dense vs MoE: Complementary Strengths

**Qwen3.6-27B (Dense)** — all 27B parameters participate in every token.
Deep reasoning, cross-file dependency analysis, architecture decisions.
Also the **multimodal hub**: built-in 27-layer vision encoder for screenshot/video understanding.

**Qwen3.6-35B-A3B (MoE)** — 35B total parameters, only 3B activated per token.
Routes each token through a subset of expert FFNs. This means:
- **Wider knowledge** (35B parameters seen during training) — more code patterns, more frameworks
- **Faster inference** (3B compute per token) — higher throughput than 27B Dense
- **Ideal for code generation**: the bulk of agent work is reading files and writing code,
  where breadth of knowledge matters more than depth of reasoning

The router automatically directs different token types to different experts — game logic
to one expert, rendering code to another, data structures to a third.

## Deployment

### Default Plan (one-click)

```bash
bash nodes/ubuntu26-node1-server/game-server/deploy.sh
```

```
GPU 0: Qwen3.6-27B    FP8  TP=1 → :8000  统筹规划 + 多模态(截图/UI审核)
GPU 1: Qwen3.6-35B-A3B BF16 TP=1 → :8001  代码生成主力(MoE 35B→3B active)
GPU 2: Qwen3.6-27B    FP8  TP=1 → :8002  多模态 + 深度推理 + QA
GPU 3: FLUX.2 FP8     ComfyUI   → :8188  图像生成(游戏美术)
```

| 指标 | 数值 |
|------|------|
| 总文本吞吐 | ~504 tok/s (2×82.8 + 338.1) |
| 27B (FP8) 吞吐 | 82.8 tok/s (4 agent 并发) |
| 35B-A3B (BF16) 吞吐 | 338.1 tok/s (4 agent 并发, 4x 27B) |
| 图像生成 | ✅ :8188 |

### Alternative Plans

```bash
bash nodes/ubuntu26-node1-server/game-server/deploy.sh plan-72b       # 72B TP=2 coordinator
bash nodes/ubuntu26-node1-server/game-server/deploy.sh plan-reasoning # R1-32B deep reasoning
```

### Plan 72B — Strongest Coordinator

Download `Qwen/Qwen3-72B` first.

```
GPU 0,1: Qwen3-72B   FP8 TP=2 → :8000  最强统筹/架构
GPU 2:   Qwen3.6-27B FP8 TP=1 → :8001  多模态 + 代码
GPU 3:   FLUX.2 FP8  ComfyUI  → :8188  图像生成
```

### Plan Reasoning — Deep CoT + MoE

Download `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` first.

```
GPU 0: R1-Distill-32B  FP8 TP=1 → :8000  深度推理(CoT)
GPU 1: Qwen3.6-35B-A3B FP8 TP=1 → :8001  代码生成(MoE)
GPU 2: Qwen3.6-27B     FP8 TP=1 → :8002  多模态 + QA
GPU 3: FLUX.2 FP8      ComfyUI  → :8188  图像生成
```

## Concurrency Analysis

Concurrency = available KV cache memory / (KV per token × context length).
All numbers assume FP8 KV cache (`--kv-cache-dtype fp8_e5m2`).

### Per-Model KV Structure

| Model | Params | FP8 Weights | KV Cache | KV/token(fp8) | Concurrent @8K |
|-------|--------|------------|----------|---------------|-----------------|
| Qwen3.6-27B | 27B Dense | 26 GB | 57.6 GB | 256 KB | 29 |
| Qwen3.6-35B-A3B | 35B MoE (3B active) | 70 GB (BF16) | 13.6 GB | 256 KB | 39 |
| Qwen3-72B | 72B Dense | 72 GB (TP2) | 47.6 GB/each | 512 KB | 38 |
| R1-Distill-32B | 32B Dense | 31 GB | 52.6 GB | 256 KB | 53 |

### Default Plan Concurrency

```
                     Model Memory    KV Cache     Max Concurrent
                     per GPU         per GPU      @32K    @8K
GPU 0: 27B  FP8      26.0 GB         57.6 GB       7      29
GPU 1: 35B  FP8(MoE) 35.0 GB         48.6 GB      10      39
GPU 2: 27B  FP8      26.0 GB         57.6 GB       7      29
GPU 3: FLUX.2        50.0 GB         35.6 GB      —       —
TOTAL (text)                                        24      97
```

At typical game dev prompt lengths (2-4K tokens), effective concurrency is 4-16× higher.
The default plan handles **hundreds** of simultaneous agent requests.

## Model Download Reference

Models are registered in `nodes/ubuntu26-node1-server/config/models.conf`. Download all at once:

```bash
bash scripts/lib/download-model.sh     # download all registered models
bash scripts/lib/download-model.sh Qwen/Qwen3.6-35B-A3B  # single model
```

| Model | Format | Size | Notes |
|-------|--------|------|-------|
| Qwen3.6-35B-A3B | safetensors | ~70 GB | MoE, 26 shards |
| FLUX.2 FP8 | FP8-only files | ~50 GB | VAE + diffusion + text encoder + Turbo LoRAs |
| Qwen3.6-27B | safetensors | ~52 GB | Already available |

FLUX.2 uses custom patterns to download only FP8 files (skips BF16/FP4 text encoders).

```bash
# Alternative plans (add to models.conf or download individually)
bash scripts/lib/download-model.sh Qwen/Qwen3-72B                          # plan-72b
bash scripts/lib/download-model.sh deepseek-ai/DeepSeek-R1-Distill-Qwen-32B # plan-reasoning
```

## Image Generation

FLUX.2 FP8 runs on GPU 3 via ComfyUI with REST API. Claude Code agents interact
programmatically — no manual UI operation needed:

```bash
# Submit a generation workflow
curl -X POST http://localhost:8188/prompt \
  -H "Content-Type: application/json" \
  -d '{"prompt": {...workflow JSON...}}'

# Check result (returns base64 image or file path)
curl http://localhost:8188/history/{prompt_id}
```

ComfyUI at `:8188/system_stats` for health checks.

For CCGS integration, the art-director and technical-artist agents submit workflows
programmatically to `:8188/prompt`. See [AGENT-CONFIG.md](AGENT-CONFIG.md) for complete
agent-to-endpoint routing.

## CCGS Agent Routing Summary

| Agent Tier | Primary Endpoint | Task Types |
|-----------|-----------------|------------|
| Tier 1 Directors | Claude-hosted (Opus) | Vision, architecture, gate decisions |
| Code Generation (~15 agents) | **:8001 (MoE)** | GDScript, C#, C++, shaders, tools |
| Design & Narrative (~8 agents) | **:8000 (27B)** | GDD authoring, systems, world-building |
| QA & Validation (~6 agents) | **:8002 (27B)** | Test plans, bug analysis, accessibility |
| Art & Visual (~3 agents) | **:8188 (FLUX.2)** | Sprites, concept art, UI mockups |

Detailed per-agent mapping, integration patterns, and performance budgets
in [AGENT-CONFIG.md](AGENT-CONFIG.md).

## Quick Start

```bash
# 1. Download models (one-time, ~120 GB)
bash scripts/lib/download-model.sh

# 2. Deploy
bash nodes/ubuntu26-node1-server/game-server/deploy.sh

# 3. Stop all services
bash nodes/ubuntu26-node1-server/game-server/stop.sh
```

## Throughput Testing

```bash
# Single endpoint benchmark
bash nodes/ubuntu26-node1-server/game-server/test/throughput-test.sh http://localhost:8000

# Multi-agent simulation
NUM_AGENTS=8 AGENT_REQUESTS=10 bash nodes/ubuntu26-node1-server/game-server/test/simulate-agents.sh http://localhost:8000

# Cross-plan comparison
bash nodes/ubuntu26-node1-server/game-server/test/compare-configs.sh full
```

## Design Decisions

1. **FP8 runtime quantization** on Dense models — halves memory, doubles instance density.
   MoE (35B-A3B) runs BF16: RTX 6000D has 99KB shared memory/SM, too small for Triton FP8
   MoE kernels (require 144KB). BF16 kernels fit within the hardware limit.

2. **No 4B models** — IDE tooling handles "fast" tasks better. Agent-quality code requires
   at minimum 27B-class models.

3. **MoE for code generation** — 35B-A3B provides wider knowledge (35B params) with fast
   inference (3B compute/token). The Dense/MoE split matches the Dense/reasoning + MoE/writing
   natural division of agent work.

4. **Dual 27B for multimodal redundancy** — both GPU 0 and GPU 2 can handle screenshots,
   so visual analysis is never bottlenecked by a single endpoint.

5. **Dedicated GPU for image generation** — FLUX.2 FP8 on ComfyUI API, isolated from
   text inference to avoid VRAM contention.

6. **No TP=2 unless forced** — lockstep barrier amplifies tail latency. Independent TP=1
   instances serve concurrent agents better. TP=2 only for 72B (too large for one card).

7. **`--user $(id -u):$(id -g)`** on all containers — avoids Docker root ownership issues
   on host-mounted cache directories (see CLAUDE.md).

## Benchmark Reference

Measured with 4-agent concurrent simulation, OSL=2048, reasoning-parser qwen3.

### Multi-Agent Simulation (this deployment)

| Model | Config | GPUs | Output tok/s | Per-Agent | Success |
|-------|--------|------|-------------|-----------|---------|
| Qwen3.6-27B FP8 | TP=1 | 1 | 82.8 | 20.7 | 100% |
| Qwen3.6-35B-A3B BF16 | TP=1, MoE | 1 | **338.1** | 84.5 | 100% |
| Qwen3.6-27B FP8 | TP=1 | 1 | 82.7 | 20.7 | 100% |

### Historical Benchmarks

From [bench/RESULTS.md](../bench/RESULTS.md), same `voipmonitor/sglang:test-cu132` image:

| Model | Config | GPUs | Output tok/s | Notes |
|-------|--------|------|-------------|-------|
| Qwen3.5-4B | TP=1 × 4 parallel | 4 | 5,415 | 99.4% scaling efficiency |
| Qwen3.6-27B | TP=2 phb+nch8+LL | 2 | 418 | Best NCCL config (+12.5%) |

## File Structure

```
game-server/
├── README.md                    # Architecture doc + quick start
├── AGENT-CONFIG.md              # CCGS agent-to-endpoint mapping + deployment guide
├── deploy.sh                    # One-click deployment (default/plan-72b/plan-reasoning)
├── stop.sh                      # Stop all containers
├── config/
│   ├── nginx-lb.template.conf   # Nginx load balancer template
│   └── services.yaml            # Service definitions and routing table
├── serve/
│   ├── serve-text.sh            # Start single text model instance
│   └── serve-image-gen.sh       # ComfyUI + FLUX.2 FP8 launcher
├── test/
│   ├── throughput-test.sh       # AIPerf benchmark on single endpoint
│   ├── simulate-agents.sh       # Multi-agent workload simulation
│   └── compare-configs.sh       # Cross-plan comparison tool
└── results/                     # Benchmark outputs
```
