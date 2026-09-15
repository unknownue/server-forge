# SGLang Benchmark Results — ubuntu26-node1-server

**Date**: 2026-05-26
**Image**: `voipmonitor/sglang:test-cu132` (CUDA 13.2, SM120 Blackwell)
**Bench Tool**: AIPerf, 30 req/config, concurrency=16, OSL=4096

## Hardware

| Component | Detail |
|-----------|--------|
| CPU | Intel Xeon w7-3545, 48 threads, 1 socket, 1 NUMA |
| GPU | 4× NVIDIA RTX 6000D (85.6 GB VRAM each, Blackwell) |
| NCCL Topology | Single-socket, all GPUs on same NUMA node |

## Qwen3.5-4B Results (small model, ~8.8 GB BF16)

### TP=1 Per-GPU (sequential)

| GPU | Output tok/s | P50 Latency | E2E tok/s | Duration |
|-----|-------------|-------------|-----------|----------|
| GPU0 | 1,367 | 45,410 ms | 91.1 | 89.9 s |
| GPU1 | 1,359 | 44,679 ms | 90.9 | 90.1 s |
| GPU2 | 1,368 | 45,429 ms | 91.2 | 89.8 s |
| GPU3 | 1,354 | 45,431 ms | 91.2 | 89.7 s |
| **Sum** | **5,449** | — | — | — |

### TP=1 Per-GPU (parallel — all 4 GPUs simultaneously)

| GPU | Output tok/s | P50 Latency | E2E tok/s | Duration |
|-----|-------------|-------------|-----------|----------|
| GPU0 | 1,360 | 44,550 ms | 91.3 | 89.7 s |
| GPU1 | 1,342 | 45,398 ms | 91.5 | 89.5 s |
| GPU2 | 1,356 | 45,344 ms | 91.1 | 89.9 s |
| GPU3 | 1,357 | 45,440 ms | 91.3 | 89.6 s |
| **Sum** | **5,415** | — | — | — |

**Scaling efficiency**: 5,415 / 5,449 = **99.4%** — near-linear scaling, negligible interference.

### TP=2 NCCL Sweep (2 GPUs, 7 configs)

| Config | Output tok/s | Latency Avg | Latency P50 | E2E tok/s | Duration |
|--------|-------------|-------------|-------------|-----------|----------|
| **baseline** | **1,915** | 31,621 ms | 31,604 ms | 128.6 | 63.7 s |
| phb+nch8 | 1,882 | 32,563 ms | 32,606 ms | 125.6 | 65.2 s |
| phb+nch8+LL | 1,835 | 33,500 ms | 33,837 ms | 122.3 | 67.0 s |
| phb+nch16 | 1,883 | 32,638 ms | 32,798 ms | 125.5 | 65.3 s |
| phb+nch16+LL | 1,831 | 32,913 ms | 33,351 ms | 123.2 | 66.4 s |
| p2p-off+nch16 | **1,916** | 31,850 ms | 32,034 ms | 128.1 | 63.9 s |
| p2p-off+nch16+LL | 1,864 | 31,401 ms | 32,110 ms | 127.2 | 64.3 s |

**Conclusion**: For 4B, default NCCL is already optimal. TP=2 throughput (1,915 tok/s) is ~1.4× TP=1 (1,360 tok/s).

---

## Qwen3.6-27B Results (medium model, ~52 GB BF16)

### TP=1 Single GPU

| Output tok/s | Latency Avg | Latency P50 | E2E tok/s |
|-------------|-------------|-------------|-----------|
| 227 | 137,055 ms | 139,857+ ms | 16.9 |

Single GPU can barely serve the 27B model — latency is extremely high due to limited VRAM for KV cache.

### TP=2 NCCL Sweep (2 GPUs, 7 configs)

| Config | Output tok/s | Latency Avg | Latency P50 | E2E tok/s | Duration |
|--------|-------------|-------------|-------------|-----------|----------|
| baseline | 372 | 77,093 ms | 91,747 ms | 30.3 | 207.8 s |
| phb+nch8 | 368 | 72,441 ms | 78,457 ms | 30.5 | 194.0 s |
| **phb+nch8+LL** | **418** | 73,058 ms | 83,840 ms | 29.4 | 171.1 s |
| phb+nch16 | 374 | 83,739 ms | 91,460 ms | 31.5 | 222.5 s |
| phb+nch16+LL | 357 | 77,958 ms | 81,832 ms | 30.8 | 214.2 s |
| p2p-off+nch16 | 374 | 80,536 ms | 93,291 ms | 33.1 | 216.1 s |
| p2p-off+nch16+LL | 315 | 82,017 ms | 84,923 ms | 32.5 | 118.6 s |

**Best config**: `phb+nch8+LL` — 418 tok/s, **12.5% improvement** over baseline (372 tok/s).

TP=2 scaling vs TP=1: 418 / 227 = **1.84×** throughput improvement.

### TP=4 (estimated)

With 4 GPUs, TP=4 should fit the 27B model with KV cache headroom (85.6 GB × 4 = 342 GB total). Expected: throughput scales further with TP=4.

---

## FP8 Model Note

`Qwen3.6-27B-FP8` at `/data/work/models/Qwen/Qwen3.6-27B-FP8/` is **incompatible** with SGLang's text-model loader:
- The checkpoint uses `compressed-tensors` format with per-layer weight_scale_inv parameters
- It appears to be a Qwen3.5-**VL** (multimodal) checkpoint, not text-only
- SGLang fails with shape mismatch: `param_data.shape=[3584] loaded_weight.shape=[5120]`
- `--quantization fp8` flag alone does not resolve the issue
- For FP8 inference, either use a text-only FP8 checkpoint or SGLang's runtime `--quantization fp8` on the BF16 model

---

## Summary

| Model | Best Config | GPUs | Best Output tok/s | Notes |
|-------|------------|------|-------------------|-------|
| Qwen3.5-4B | TP=1 parallel | 4 | 5,415 (aggregate) | 99.4% scaling efficiency |
| Qwen3.5-4B | default NCCL | 2 (TP=2) | 1,915 | NCCL tuning not needed for small models |
| Qwen3.6-27B | phb+nch8+LL | 2 (TP=2) | 418 | NCCL tuning gives +12.5% |
| Qwen3.6-27B | TP=1 | 1 | 227 | VRAM-bound, high latency |
| Qwen3.6-27B-FP8 | — | — | — | Incompatible (VL checkpoint) |

**Key findings**:
1. The image `voipmonitor/sglang:test-cu132` fully utilizes the hardware — no bottleneck detected
2. For small models (4B): default NCCL is optimal, 4× TP=1 achieves 99.4% scaling
3. For medium models (27B): `NCCL_P2P_LEVEL=PHB NCCL_MIN_NCHANNELS=8 NCCL_PROTO=LL` gives 12.5% throughput improvement
4. FP8 quantized checkpoint is incompatible due to VL architecture mismatch

---

## Qwen3.8-27B-NVFP4 (DSPARK speculative) Memory-Parameter Sweep

**Date**: 2026-08-19
**Image**: `lmsysorg/sglang:qwen38-27b` (custom fork, DSPARK + hybrid Mamba/SWA support)
**Bench Tool**: on-host Node client (`bench-client-qwen38.cjs`), 64 req × 512 in / 128 out, concurrency 8, stream
**Context probe**: ascending single-request ladder (32 output tokens) up to the configured `--context-length`
**DSH acceptance test**: 42 KB system prompt + 28 tool schemas + `max_completion_tokens 4096` (the load that crashed the original serving config)

GPU: RTX 6000D 85.6 GiB each. Swept axes: TP 1/2, `--mem-fraction-static` 0.75/0.85/0.95,
`--mamba-full-memory-ratio` 5/8/11.93, `--context-length` 64K/128K/196K/256K, DSPARK on/off.

### TP=1 (single GPU 0)

| Config (ctx / frac / ratio / spec) | Idle VRAM | Headroom | Output tok/s | TTFT p50 | ITL | Max probed input | DSH test |
|:---|:---|:---|:---|:---|:---|:---|:---|
| 256K / 0.95 / 11.93 / on (original) | 84414 MiB | 1.2 GiB | **0/64 reqs OK — server died** | — | — | 0 (dead at 8K probe) | ❌ crashes |
| 128K / 0.95 / 11.93 / on | 83770 MiB | 1.8 GiB | 208.2 | 194 ms | 48 ms | died at ~5K probe (500) | ❌ |
| 128K / 0.85 / 8 / on | 80604 MiB | 4.9 GiB | 336.8 | 107 ms | 38 ms | 130,060 tok OK | ✅ |
| 64K / 0.75 / 5 / on | 72144 MiB | 13.2 GiB | 358.2 | 109 ms | 38 ms | 65,056 tok OK (= ctx) | ✅ |
| 128K / 0.85 / 8 / off | 76820 MiB | 8.6 GiB | 257.6 | 115 ms | 19 ms | 85,304 tok OK | — |
| 196K / 0.85 / 8 / on | 80578 MiB | 4.9 GiB | 435.4 | 112 ms | 38 ms | 130,060 OK; 146,310 → 400 | — |

### TP=2 (GPU 0+1)

TP=2 requires `NCCL_P2P_DISABLE=1` on this machine (PCIe P2P init fails with "unhandled
system error"; see README Maintenance Log IOMMU entry) plus `--shm-size=32g --ipc=host`.

| Config (ctx / frac / ratio) | Idle VRAM g0/g1 | Output tok/s | TTFT p50 | ITL | Max probed input | DSH test |
|:---|:---|:---|:---|:---|:---|:---|
| 256K / 0.95 / 11.93 | **boot OOM** | — | — | — | — | — |
| 64K / 0.75 / 5 | 73402 / 71761 MiB | 545.3 | 96 ms | 30 ms | 65,056 tok OK | — |
| 128K / 0.85 / 8 | 82472 / 80831 MiB | 476.2 | 95 ms | 30 ms | 130,060 tok OK | — |
| 256K / 0.85 / 8 | 82918 / 81275 MiB | 474.5 | 94 ms | 29 ms | **260,066 tok OK (full 256K)** | ✅ |
| 524K / 0.80 / 8 (ctx override) | 78779 / 77163 MiB | 120 s | 503.2 | 138 ms | 35 ms | **524,288 tok OK** | ✅ |

### Concurrent-agent context capacity (TP=2, 256K/0.80/8)

**Date**: 2026-08-23
**Image**: `lmsysorg/sglang:qwen38-27b` (same deployed config as `qwen38-dspark-2gpu`)
**Method**: N concurrent OpenAI-completions requests, each with a **distinct** filler prompt
(no radix prefix sharing), 32 output tokens, stream off. Token counts from `usage.prompt_tokens`.

Key capacity numbers from server logs:

- `--context-length 262144` → **per-agent hard cap = 262,144 tokens** (model's
  `max_position_embeddings`; NOT a VRAM limit — single agent uses only ~260K of the pool).
  Verified: 257,437 tok OK, ~262,500 tok → 400.
- KV cache is **dual-pool**: fp8 `#tokens: 329,735` + bf16 `#tokens: 329,735` (per rank, TP=2)
  → **~659K tokens total, shared by all agents** (hybrid Mamba/SWA: only ~16/64 layers
  use full-attention KV; linear layers use the mamba state cache).
- `max_running_requests 48` (spec decoding) · decode concurrency capped at CUDA-graph max-bs 32.

Measured (distinct prompts, actual total prompt tokens):

| Scenario | Total prompt tokens | Result | Notes |
|:---|:---|:---|:---|
| 2 × 120K | 284,605 | ✅ 2/2 | — |
| 2 × 155K | 367,586 | ✅ 2/2 | — |
| 2 × 190K | 450,566 | ✅ 2/2 | — |
| 2 × 205K | 486,128 | ✅ 2/2 | — |
| 2 × 215K | 509,836 | ✅ 2/2 | — |
| 2 × 220K | 521,691 | ✅ 2/2 | each ~260K, near per-agent cap |
| 3 × 110K | 391,347 | ✅ 3/3 | — |
| 4 × 100K | 474,381 | ✅ 4/4 | TTFT: 15s → 45s (later agents) |
| 5 × 100K | 592,974 | ✅ 5/5 | — |
| 6 × 100K | 711,569 | ✅ 6/6 | TTFT up to 116s for last agent |

Findings:

1. **Per-agent context stays 262,144 tokens regardless of concurrency** — the hard cap is
   `--context-length`, not the KV pool. Multi-agent sharing only divides the shared pool.
2. **The shared pool is ~659K tokens (fp8 + bf16 dual pools), far above the 329,735 single-pool
   number** — the 2×240K "failure" earlier was each request exceeding 262,144 (tokenizer ratio
   1.186), NOT pool exhaustion. Even 6×100K (711K total) succeeds.
3. **Per-agent usable context ≈ min(262,144, 659,470 / N)**. For ≤6 agents the pool is ample;
   the practical ceiling is `max_running_requests 48` (number of agents), not capacity.
4. **The real multi-agent cost is latency, not capacity**: large-context prefills are
   serialized (4×100K → later TTFT 15s→45s; 6×100K → up to 116s), and decode concurrency is
   capped at 32 (CUDA-graph max-bs).
5. Guidance: 2 agents can both run near-full 262K (verified 2×220K ≈ 521K total). For 3+ long-
   context agents, budget ~150K/agent. Short-context agents (<50K) are effectively unlimited
   (48-request cap only).

### TP=4 (GPU 0+1+2+3)

**Date**: 2026-08-22
**Image**: `lmsysorg/sglang:qwen38-27b`
**Bench Tool**: on-host Node client (`bench-client-qwen38.cjs`), 64 req × 512 in / 128 out, concurrency 8, stream
**Context probe**: ascending single-request ladder (32 output tokens) up to the configured `--context-length`
**DSH acceptance test**: 42 KB system prompt + 28 tool schemas + `max_completion_tokens 4096`, 3× runs

Same flags as TP=2 (`NCCL_P2P_DISABLE=1`, `--shm-size=32g --ipc=host`); the
`--cuda-graph-max-bs 32` cap carries over via `serve/sglang-qwen38-dspark.sh`.
`SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` is needed for ctx > 262144 (the
model's derived context cap — added automatically by the serve script).

| Config (ctx / frac / ratio) | Idle VRAM g0/g1-3 | Boot | Output tok/s | TTFT p50 | ITL | Max probed input | DSH test |
|:---|:---|:---|:---|:---|:---|:---|:---|
| 256K / 0.85 / 8 (max-bs 32) | 82713 / 81093 MiB | **stalls ~20 min at verify-graph capture** | — | — | — | — | — |
| 256K / 0.85 / 8 (max-bs 8, no prefill graph) | 82713 / 81093 MiB | 90 s | 376.0 | 411 ms | 45 ms | 262,144 tok OK | 1× ✅ |
| 256K / 0.80 / 8 (max-bs 32) | 82133 / 80511 MiB | 150 s | 557.4 | 128 ms | 31 ms | 262,144 tok OK | 1× ✅ |
| 393K / 0.80 / 8 (max-bs 32, ctx override) | 82431 / 80809 MiB | 150 s | 544.5 | 141 ms | 32 ms | **393,216 tok OK** | — |
| 524K / 0.80 / 8 (max-bs 32, ctx override) | 82729 / 81107 MiB | 150 s | 533.9 | 112 ms | 32 ms | **524,288 tok OK** | 3× ✅ |
| **256K / 0.80 / 8 + parsers (deployed)** | 82133 / 80511 MiB | 150 s | **578.6** | — | — | 262,144 tok OK | 3× ✅ |

### Key findings

1. **The original config (256K / 0.95 / 11.93) is infeasible at any TP.** Idle already uses
   84414/85651 MiB (1.2 GiB free); every multi-K request OOMs the scheduler, returns 500,
   kills the server, and DeepSeek Harness retries land in the restart window — surfacing as
   "Connection error". TP=2 with the same params OOMs at boot.
2. **TP=1 max usable input ≈ 131K tokens**, regardless of `--context-length`. At
   `--mem-fraction-static 0.85` the KV pool fills at 131,106 tokens ("Input length exceeds
   the maximum allowed length", KV usage 0.99); 196K context on one GPU buys nothing.
3. **TP=2 unlocks ~230K+ context**: KV is sharded across both GPUs. At `frac 0.85` the
   full 262,144-token ladder passed once, but idle GPU0 headroom is only 0.7–2.6 GiB and
   varies per boot — a later boot OOM'd rank 0 on the DSH-shaped load (42KB system + 28
   tools + 4096 out) → 500 → "Connection error". `frac 0.80` + `--cuda-graph-max-bs 32`
   fixes this: ~7 GiB/GPU headroom, 227K-token ladder and 3× DSH-shaped load all stable.
4. **Throughput**: TP=2 ≈ 1.4–1.5× TP=1 at the same context (545 vs 358 tok/s; 476 vs 337).
   DSPARK speculative decoding adds ~31% (337 vs 258 tok/s, accept len ≈ 2.6–2.7).
5. **Headroom requirement for agent workloads**: DSH sends ~15–30K-token requests with tools;
   a config needs ≥ 4 GiB idle headroom. `frac 0.95` in any shape fails this test, and
   `frac 0.85` on TP=2 is marginal (boot-dependent).
6. **TP=4 throughput ≈ 1.22× TP=2 (579 vs 475 tok/s) and ~1.7× TP=1**, with `frac 0.80`
   + full CUDA-graph capture (max-bs 32, prefill graph enabled). TP=4 also unlocks
   **524K context** (model's native cap is 262,144; `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1`
   needed) — 524K/0.80 keeps 534 tok/s and passes 3× DSH load, though extension beyond
   the training cap is unverified for quality.
7. **TP=4 constraints** (why frac 0.85 fails):
   - CustomAllreduce auto-disabled on 4 PCIe-only GPUs → NCCL over shm is slower, capping
     the scaling at ~1.22× instead of ~2×.
   - Fixed per-GPU overhead (mamba state pool, CUDA-graph pools, activations) doesn't
     shrink with TP: headroom is only ~2.9 GiB/GPU at frac 0.80 (vs ~7 GiB at TP=2), and
     2.3 GiB at frac 0.85 — below the 4 GiB prefill-graph capture gate.
   - At frac 0.85 + max-bs 32, verify-graph capture **stalls ~20 min** at boot (low
     headroom); frac 0.85 + max-bs 8 + `--disable-prefill-cuda-graph` boots in 90 s but
     only reaches 376 tok/s with 411 ms TTFT.
   - Deployed config must therefore be `frac 0.80`; see profile `qwen38-dspark-4gpu`.
8. **NCCL tuning does not rescue TP=4.** Re-ran the TP=2 sweep's best combo
   (`NCCL_P2P_LEVEL=PHB NCCL_MIN_NCHANNELS=8 NCCL_PROTO=LL`) on TP=4: **511.6 tok/s —
   worse than `NCCL_P2P_DISABLE=1` (557.4)**. SGLang source confirms the cap is hard:
   `custom_all_reduce_utils.py` disables CustomAllReduce whenever `world_size > 2 and
   not full_nvlink` (no env override; only a custom image rebuild could change it).
   The ~1.22× ceiling is hardware topology (4× PCIe, no NVLink, broken P2P), not
   configuration.
9. **TP=2 is this machine's optimal parallelism, not TP=4.** Two parallel TP=2
   instances (GPU 0+1 on :30000, GPU 2+3 on :30001, both 262K/0.80/8) reached
   **504 + 458 = 962 tok/s aggregate** vs 579 tok/s for one TP=4 instance (+66%
   on the same 4 GPUs). CustomAllReduce works at TP=2 (world_size ≤ 2 bypasses the
   NVLink gate) and KV sharding benefits don't grow with TP; use 2×TP=2 for
   throughput, TP=4 only when one model needs > 262K context.
10. **Within 2 GPUs, 2×TP=1 beats 1×TP=2 for throughput (926.8 vs 526.6 tok/s,
    +76%, same parsers/load), but halves the context (131K vs 262K per instance).**
    Two parallel TP=1 instances (GPU 0 :30000, GPU 1 :30001, both 131K/0.85/8)
    measured 443 + 484 tok/s. So the "optimal granularity" for 2 GPUs depends on
    the workload: many independent short sessions → 2×TP=1; one long-context
    session (agent/DSH with >131K prompts, or 262K/524K override) → 1×TP=2.
    Single-instance TP=2 (526 tok/s) is already far beyond what a single DSH
    client needs (requests are serialized per session).
11. **Why "2 GPUs → 256K context" — and how to get more.** The 256K wall is NOT
    VRAM: the model's `max_position_embeddings` is exactly 262144, and SGLang
    refuses to boot with a larger `--context-length` unless
    `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` is set. With the override, 2 GPUs
    run the full **524,288-token ladder (341,053 real tokens) at 503 tok/s** with
    ~6–8 GiB/GPU headroom — the earlier "~230K+ usable" conclusion was the cap
    without override. KV cache is expensive on this model: `head_dim=256` (double
    the usual 128), 4 KV heads, 64 layers → **128 KB per token at FP8**, so 524K
    needs ~67 GB of KV alone.

### Balance point (recommended serving configs)

| Scenario | Config | Why |
|:---|:---|:---|
| **DSH / agent daily use** | TP=1, `--context-length 131072 --mem-fraction-static 0.85 --mamba-full-memory-ratio 8` | 131K usable context, 337 tok/s, 4.9 GiB headroom, 3 GPUs left free. **Deployed on `qwen-sglang-dspark` 2026-08-19.** |
| Maximum safety margin | TP=1, `--context-length 65536 --mem-fraction-static 0.75 --mamba-full-memory-ratio 5` | 13.2 GiB headroom, 358 tok/s; context capped at 64K. |
| Long context / throughput | TP=2, `--context-length 262144 --mem-fraction-static 0.80 --mamba-full-memory-ratio 8 --cuda-graph-max-bs 32` + `NCCL_P2P_DISABLE=1 --shm-size=32g --ipc=host` | ~227K+ verified usable context, ~475 tok/s, ~7 GiB/GPU headroom, costs 2 GPUs. **Deployed as hub profile `qwen38-dspark-2gpu` (2026-08-19).** |
| Extreme long context (2 GPUs) | TP=2, `--context-length 524288 --mem-fraction-static 0.80 --mamba-full-memory-ratio 8 --cuda-graph-max-bs 32` + `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` | **524K verified usable context at 503 tok/s**, ~6–8 GiB/GPU headroom, DSH stable. Beyond the model's native 262K cap — quality of long-context output unverified. |
| Max throughput (4 GPUs) | TP=4, `--context-length 262144 --mem-fraction-static 0.80 --mamba-full-memory-ratio 8 --cuda-graph-max-bs 32` + `NCCL_P2P_DISABLE=1 --shm-size=32g --ipc=host` | 262K verified usable context, **~579 tok/s**, 2.9 GiB/GPU headroom, 3× DSH stable. Costs all 4 GPUs. **Deployed as hub profile `qwen38-dspark-4gpu` (2026-08-22).** |
| Extreme long context (4 GPUs) | TP=4, `--context-length 524288 --mem-fraction-static 0.80 --mamba-full-memory-ratio 8 --cuda-graph-max-bs 32` + `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` | **524K verified usable context**, ~534 tok/s, 2.3 GiB/GPU headroom. Beyond the model's native 262K cap — quality of long-context output unverified. |

Never use `--mem-fraction-static 0.95` or `--mamba-full-memory-ratio 11.93` with this model:
the static KV pool + mamba full-memory preallocation leaves no room for CUDA graphs and
request-time allocations.

### Reproduce

```bash
# single config (adjust args), then:
bash nodes/ubuntu26-node1-server/bench/sweep-qwen38.sh   # full 8-config sweep, results -> tmp/sweep-qwen38/results.csv
```
