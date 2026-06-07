# MoE FP8 Migration Guide

**Date**: 2026-05-29
**Status**: Resolved — tuned Triton kernel config created for RTX 6000D

## Root Cause

SGLang's fused MoE Triton kernel uses per-device tuned configurations stored as JSON files
at `sglang/srt/layers/moe/fused_moe_triton/configs/triton_3_6_0/`. These configs specify
block sizes, number of warps, and pipeline stages for the fused MoE kernel.

**No config existed for `NVIDIA_RTX_6000D` (Ada Lovelace AD102)**, so the kernel fell back
to the default config:

```json
{"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 128, "BLOCK_SIZE_K": 128, "num_warps": 4, "num_stages": 4}
```

The `num_stages=4` parameter controls pipeline depth — it determines how many input tiles
are prefetched into shared memory. The approximate shared memory formula is:

```
SM ≈ num_stages × BLOCK_SIZE_K × (BLOCK_SIZE_M + BLOCK_SIZE_N) + BLOCK_SIZE_M × BLOCK_SIZE_N × 4 + overhead
   ≈ 4 × 128 × (64 + 128) + 64 × 128 × 4 + ~16KB
   ≈ 144KB
```

RTX 6000D (Ada Lovelace AD102) has only **99 KB shared memory per SM** (reported as 101,376 bytes).
This causes:

```
triton.runtime.errors.OutOfResources: out of resource: shared memory,
  Required: 147456, Hardware limit: 101376.
```

RTX PRO 6000 Blackwell has 228 KB shared memory, so the default config works there.

## Fix

Created tuned kernel config files with `num_stages=2` and conservative block sizes
that fit within the 99 KB shared memory limit. The configs are written to:

```
/data/cache/sglang_jit/moe_configs/configs/triton_3_6_0/
├── E=256,N=512,device_name=NVIDIA_RTX_6000D,dtype=fp8_w8a8.json
└── E=256,N=512,device_name=NVIDIA_RTX_6000D,dtype=fp8_w8a8_down.json
```

Key differences from default config:
- `num_stages`: **2** (vs default 4) — halves pipeline buffer shared memory
- `BLOCK_SIZE_M`: 16–128 (vs default 64) — smaller for low-batch, same for high-batch
- `BLOCK_SIZE_N`: 64–128 (vs default 128) — smaller for most batch sizes
- `BLOCK_SIZE_K`: 64–256 (vs default 128) — adaptive by batch size

The configs are mounted into the container via:
```bash
-v /data/cache/sglang_jit/moe_configs:/moe_configs:ro \
-e SGLANG_MOE_CONFIG_DIR=/moe_configs
```

The `deploy.sh` script auto-generates these configs on first run via `setup_moe_configs()`.

## Additional Issue: Eager-Mode Decode Bug

After fixing the kernel config, disabling CUDA graphs entirely (`--disable-cuda-graph`)
still failed because the eager-mode decode path in this SGLang version has a bug:

```
AttributeError: 'DecodeMetadata' object has no attribute 'use_ragged'
```

This means **CUDA graphs must be enabled** for the MoE model to function properly.
To prevent the scheduler from forming batches larger than the CUDA graph supports
(which would trigger the buggy eager fallback), `--max-running-requests` must be
set equal to `--cuda-graph-max-bs`. This ensures all batches stay within the graph
range and extra requests queue gracefully.

## Results

| Metric | BF16 (old) | FP8 (tuned config + max_running) |
|--------|-----------|----------------------------------|
| Weights | 70 GB | 34.5 GB |
| KV Cache pool | ~13.6 GB | ~18.7 GB |
| Concurrent @8K | 39 | 39 (same) |
| Throughput (8 agents, max_bs=8) | 338.1 (4 agent) | **695.7 tok/s** |
| Throughput (8 agents, max_bs=4) | — | 332.0 tok/s (queued) |
| Stability @24 concurrent | — | 100% (queued, no crash) |

FP8 with `--cuda-graph-max-bs 8 --max-running-requests 8` achieves ~700 tok/s, roughly
double the BF16 throughput at 4 concurrent. The ~35 GB memory saving plus the larger
CUDA graph batch size account for the improvement.

## Deployment

No manual steps required. `deploy.sh` automatically sets up the MoE kernel configs
and mounts them into all SGLang containers. The MoE instance uses:

```bash
--quantization fp8 --cuda-graph-max-bs 8 --max-running-requests 8 --reasoning-parser qwen3
```

The `--max-running-requests 8` flag is **critical for stability** — without it, the
scheduler may form batches > 8, fall back to eager mode, and hit the `use_ragged` bug.

## Tuning for Other GPUs

If deploying on a different GPU, either:
1. Run SGLang's tuning tool: https://github.com/sgl-project/sglang/tree/main/benchmark/kernels/fused_moe_triton
2. Or adapt the config in `deploy.sh:setup_moe_configs()` with:
   - `device_name` set to the GPU model (spaces → underscores)
   - `num_stages=2` (mandatory for Ada Lovelace, optional for Blackwell)
   - Block sizes adjusted for your GPU's shared memory limit

The config filename pattern is:
```
E={num_experts},N={intermediate_size},device_name={GPU_NAME},dtype=fp8_w8a8.json
```
