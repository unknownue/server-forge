# MoE FP8 Migration Guide

**Date**: 2026-05-28
**Status**: Pending — blocked by RTX 6000D shared memory hardware limitation

## Current State

Qwen3.6-35B-A3B runs BF16 on GPU 1 because Triton's FP8 MoE kernels require
**144 KB shared memory per SM**, but the RTX 6000D (Ada Lovelace AD102) only
has **99 KB shared memory per SM**. The BF16 kernels fit within 99 KB.

This forces a suboptimal allocation:

```
GPU 1 (MoE BF16):  权重 70 GB + KV Cache 13.6 GB  ← KV Cache 严重不足
GPU 0 (27B FP8):   权重 26 GB + KV Cache 57.6 GB  ← 充裕
GPU 2 (27B FP8):   权重 26 GB + KV Cache 57.6 GB  ← 充裕
```

Consequences:
- `--context-length 32768` on MoE (vs 40960 on 27B) — non-uniform limits
- Only ~1 concurrent request at 32K full — bottleneck for multi-agent workloads
- Routing complexity: downstream must distinguish "long context → 27B" vs "short → MoE"
- MoE's 4× throughput advantage underutilized because it can't handle enough concurrent requests

## After FP8 Fix

Once a compatible FP8 kernel becomes available (via SGLang update, Triton update,
or driver fix), the MoE instance transforms:

| Metric | BF16 (current) | FP8 (fixed) | Change |
|--------|---------------|-------------|--------|
| Weights | 70 GB | 35 GB | -50% |
| KV Cache pool | 13.6 GB | **48.6 GB** | +257% |
| Concurrent @32K (max) | 1 | **5** | 5× |
| Concurrent @8K (typical) | 6 | **24** | 4× |
| Concurrent @4K (lightweight) | 12 | **48** | 4× |

GPU 1's KV Cache pool becomes **48.6 GB**, comparable to the 27B instances
(57.6 GB). The MoE is no longer the bottleneck.

## Deployment Changes

### Context-Length Options

**Option A: Uniform 40K across all instances (recommended for simplicity)**

```bash
# All three instances use the same context-length
GPU 0: --context-length 40960  (27B FP8)
GPU 1: --context-length 40960  (35B MoE FP8)  ← raised from 32768
GPU 2: --context-length 40960  (27B FP8)
```

Benefit: three interchangeable instances, no routing complexity.
Trade-off: MoE concurrency drops from ~5 to ~4 at max context (acceptable).

**Option B: Keep 32K, maximize concurrency (recommended for throughput)**

```bash
GPU 0: --context-length 40960  (27B FP8, long context)
GPU 1: --context-length 32768  (35B MoE FP8, high concurrency)  ← unchanged
GPU 2: --context-length 40960  (27B FP8, long context)
```

Benefit: MoE gets 5× concurrency boost at 32K. 27B handles long context.
Trade-off: non-uniform limits remain (but MoE is no longer a single-request bottleneck).

### deploy.sh Changes Required

In `load_plan()`, update GPU 1's `INSTANCE_EXTRA_ARGS`:

```bash
# Before (BF16):
INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 32768 --cuda-graph-max-bs 4 \
  --reasoning-parser qwen3 --served-model-name Qwen3.6-35B-A3B-FP8"

# After (FP8):
INSTANCE_EXTRA_ARGS[1]="$SHARED_ARGS --context-length 40960 \
  --quantization fp8 --reasoning-parser qwen3 --served-model-name Qwen3.6-35B-A3B-FP8"
```

Key changes:
1. Add `--quantization fp8` (the fix enables this)
2. Remove `--cuda-graph-max-bs 4` (FP8 kernel should not need this workaround)
3. Context-length: 40960 (Option A) or keep 32768 (Option B)

Also update the log message and comments:
```bash
log "  GPU 1: Qwen3.6-35B-A3B FP8→ :8001 (MoE 35B→3B)"  # was "BF16"
log "  Note: MoE now runs FP8 — kernel compatibility resolved"
```

### Aggregate Capacity After Fix

| Plan | Config | Total Throughput | 27B Pool Concurrency | MoE Concurrency |
|------|--------|-----------------|---------------------|-----------------|
| Current (BF16) | 2×27B FP8 + MoE BF16 | ~504 tok/s | 58 @8K | 39 @8K (limited by KV cache) |
| After FP8 (40K) | 2×27B FP8 + MoE FP8 | ~504 tok/s | 58 @8K | **~45 @8K** (+15%) |
| After FP8 (32K) | 2×27B FP8 + MoE FP8 | ~504 tok/s | 58 @8K | **~96 @8K** (+146%) |

Throughput stays the same (~504 tok/s total) because FP8 quantization doesn't
change the compute per token. The gains are purely in **concurrency** — more
simultaneous requests without queuing.

## When to Trigger

Watch for these signals that the FP8 kernel issue is resolved:

1. New SGLang image with updated Triton/CUTLASS MoE kernels
2. NVIDIA driver update expanding shared memory limits (less likely)
3. SGLang release notes mentioning "FP8 MoE support for Ada Lovelace"
4. `--quantization fp8` succeeds on Qwen3.6-35B-A3B without crashes

## Verification After Migration

```bash
# 1. Confirm FP8 loading
docker logs ws-35b-moe-code 2>&1 | grep -i "fp8\|quantization"

# 2. Verify KV cache allocation
docker logs ws-35b-moe-code 2>&1 | grep -i "kv_cache\|gpu_memory"

# 3. Smoke test with 32K context request
curl http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3.6-35B-A3B-FP8","messages":[{"role":"user","content":"..."}],"max_tokens":30720}'

# 4. Verify concurrency improvement
API_FORMAT=anthropic NUM_AGENTS=8 AGENT_REQUESTS=10 \
  bash test/simulate-agents.sh http://localhost:8090
```
