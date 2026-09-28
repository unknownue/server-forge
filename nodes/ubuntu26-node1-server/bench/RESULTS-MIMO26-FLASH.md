# MiMo-V2.6-Flash-RL on 4× RTX 6000D (SM120) — measured results

Deployment: vLLM `0.29.1rc1.dev449+geb8798058` (day-0 MiMo image) plus the
SM120 kernel/attention stack published for RTX PRO 6000 Blackwell
([diffbot recipe](https://huggingface.co/diffbot/MiMo-V2.6-Flash-RL-FP8KV-W4A8-2x-RTX-PRO-6000),
vendored read-only at `/data/work/vendor/diffbot-mimo26-recipe`).

Launcher: `serve/mimo26-flash.sh` · profile: `profiles/mimo26-flash-8c-1m-lan.yaml`
Model: `/data/work/models/XiaomiMiMo/MiMo-V2.6-Flash-RL` (pinned revision
`5711b268169967567844e1e560e8a3966da959b1`, 177.8 GB, MXFP4 experts + FP8 dense)

## Serving configuration

| Knob | Value |
|---|---|
| Parallelism | TP4 (one card per KV-head shard), draft TP4, PP1, no EP |
| `--kv-cache-dtype` | `fp8` (E4M3 on the DiffKV layers, upstream patch) |
| `--kv-offloading-size` | 64 GiB host RAM as the CPU KV tier |
| MoE backend | `marlin` with `VLLM_MARLIN_INPUT_DTYPE=fp8` (W4A8) |
| Speculative decoding | DFlash, 3 draft tokens |
| `--gpu-memory-utilization` | 0.90 |
| `--max-model-len` / `--max-num-seqs` | 1,048,576 / 8 |
| `--max-num-batched-tokens` | 4096 |
| Attention | Triton DiffKV + upstream split-KV/wide-tile patches + custom CUDA prefill kernel (`prefill_attn_v1.cu`) |
| Misc | `--disable-custom-all-reduce`, cudagraphs `FULL_DECODE_ONLY`, prefix caching + chunked prefill on |

## Capacity (the headline number)

Engine startup line, measured on this node at the default
`--gpu-memory-utilization 0.95`:

```
GPU KV cache size: 10,877,194 tokens, Maximum concurrency for 1,048,576 tokens
per request: 10.37x
Available KV cache memory: 34.76 GiB   (per GPU)
```

(At the earlier 0.90 setting the same engine reported 9,553,364 / 9,577,937
tokens and 30.53 GiB. See "VRAM utilization" below for the trade-off.)

| | DeepSeek-V4.1-Flash (incumbent) | MiMo-V2.6-Flash (this run) |
|---|---|---|
| KV pool | 1,953,792 tokens | **10.88 M tokens (5.6×)** |
| Per-request cap | 1,048,576 | 1,048,576 |
| Concurrency at 1M | 1 | **9** (engine-reported) |
| Weights per card | 74.70 GB | ~45 GB |
| Host RAM held | 189 GiB locked (Engram) | 0 (64 GiB optionally used as KV tier) |
| GPU memory used | ~81.5 GiB/card | 78.1 GiB/card at util 0.90 |

VRAM accounting per card (85,651 MiB = 83.65 GiB): weights ~41.4 GiB (178 GB / 4),
CUDA context + activations ~3 GiB, KV pool 30.53 GiB.

## Verified behaviour

| Probe | Result |
|---|---|
| Short chat completion | pass (`SMOKE OK`), reasoning tokens reported separately |
| 29K needle (recipe `needle-test.py`) | **found = True**, 6.3 s, ~4,593 tok/s prefill |
| Tool call (recipe `test-toolcall.py`) | **pass** — `finish_reason=tool_calls`, arguments valid JSON, `reasoning` field present; no-tool case returns `stop` |
| 1M-context request | **pass** — 1,003,512 prompt tokens accepted, no OOM |
| 4 × 200K unique-prefix concurrency | **4/4 succeeded**, no OOM, no retractions |
| CPU KV tier | active (`vllm:kv_offload_store_bytes` / `load_bytes` moving every 10 s) |

## Throughput (measured)

Recipe `bench-sbs.py`, 46K-token prompts, warm cache:

| Concurrency | Prefill (aggregate) | Decode single-stream | Decode aggregate |
|---:|---:|---:|---:|
| 1 | 7,319–7,427 tok/s | 215–219 tok/s | 215–219 tok/s |
| 4 | 15,060 tok/s | — | 251 tok/s (an earlier run measured 488) |
| 8 | 19,675–19,809 tok/s | — | unstable: 190 tok/s first run, 2,578 tok/s second |

The aggregate-decode column comes from the recipe's cache-differencing method and
is not stable across runs; treat it as an order-of-magnitude figure only.

Long-context probe (`tmp/mimo26-lctx-bench.py`, unique prompts, streaming):

| Shape | Result |
|---|---|
| 4 × 200K, 256 output tokens | wall 132.4 s; prompt sum 802,960; TTFT min 14.5 s / max 131.4 s; aggregate prefill 6,113 tok/s; fastest single-stream prefill ≈ 13,800 tok/s; decode under concurrent prefill starved (median 4.7 tok/s), clean single-stream decode at 200K = 155.5 tok/s |
| 1 × 1M, 64 output tokens | wall 567.1 s; TTFT 566.7 s (≈1,771 tok/s prefill at full 1M); decode after TTFT **149.1 tok/s** |

## Against the incumbent on the same hardware

| Metric | DeepSeek-V4.1-Flash | MiMo-V2.6-Flash |
|---|---|---|
| 1M request TTFT | ~35 min (measured preset) | **9.4 min** |
| Decode at long context | 108 tok/s/req at 3 × 620K (323 tok/s aggregate) | 149 tok/s single-stream at 1M; 218 tok/s at 46K |
| Pool-limited concurrency at 620K | 3 | ~15 (9.55M / 620K) |
| Host RAM | 189 GiB locked, mlock must succeed | free |

## Known limits / next tuning steps

- **1M prefill is attention-bound**: 1,771 tok/s at 1M versus ~13,800 tok/s at 200K
  is the quadratic cost of the 9 global-attention layers. Raising
  `--max-num-batched-tokens` (4096 → 16384) is the first lever to test; upstream
  measured that 8192-token chunks reduce the KV pool on 2 cards, which this node
  can afford (pool 9.55M).
- **Decode during concurrent prefill** drops hard (chunked prefill interleaves with
  decode). If interactive latency under load matters, cap concurrent long prefills
  or lower `--max-num-batched-tokens`.
- Multimodal warmup warns that the configured image/video limits exceed the
  checkpoint's own maxima (`image.width` 1920 > 1440, `video.num_frames` 32 > 2);
  text and image paths were exercised, video/audio were not.
- `--limit-mm-per-prompt` should be lowered to the model's real limits.
- Quality: only the recipe's smoke-level probes were run here (GSM8K canary in the
  recipe was not executed on this node).

## Same-harness comparison with DeepSeek-V4.1-Flash

Both models were driven by the **same probe** (`tmp/llm-lctx-probe.py`): unique
random-word prompt per stream (no shared prefix, so no radix-cache hits),
`temperature=0`, 128 output tokens, streaming, thinking disabled
(`chat_template_kwargs` `thinking`/`enable_thinking` false), C requests started
simultaneously, TTFT = first generated token, decode = `(completion-1)/(end-TTFT)`.

Configuration caveat: each model ran on its own best working preset on this node.
MiMo: TP4, 1M context, fp8 KV. DeepSeek: TP4, 450K context / 4 slots (its
production preset is 620K / 3 slots — 4 slots at 620K does not fit the 1.95M-token
pool), fp8 KV.

| Cell | MiMo-V2.6-Flash | DeepSeek-V4.1-Flash | Ratio (MiMo / DS) |
|---|---:|---:|---:|
| 46K, C=1 — prefill | 6,973 tok/s | 1,507 tok/s | **4.6×** |
| 46K, C=1 — decode | 242.6 tok/s | 93.2 tok/s | **2.6×** |
| 46K, C=1 — TTFT | 6.5 s | 33.8 s | 5.2× faster |
| 46K, C=4 — prefill (aggregate) | 7,576 tok/s | 1,842 tok/s | **4.1×** |
| 46K, C=4 — decode (aggregate) | 191.5 tok/s | 78.8 tok/s | 2.4× |
| 46K, C=4 — TTFT min/median/max | 6.5 / 18.4 / 23.9 s | 28.1 / 83.1 / 110.8 s | — |
| 200K, C=1 — prefill | 5,018 tok/s | 1,570 tok/s | **3.2×** |
| 200K, C=1 — decode | 191.2 tok/s | 92.1 tok/s | **2.1×** |
| 200K, C=1 — TTFT | 39.1 s | 141.2 s | 3.6× faster |
| 200K, C=4 — prefill (aggregate) | 5,076 tok/s | 1,604 tok/s | **3.2×** |
| 200K, C=4 — decode (aggregate) | 196.5 tok/s | 70.7 tok/s | 2.8× |
| 200K, C=4 — TTFT min/median/max | 38.9 / 116.5 / 154.8 s | 142.0 / 417.0 / 553.2 s | — |
| 200K, C=4 — wall clock | 155.5 s | 555.3 s | 3.6× faster |
| KV pool | 9.55–9.58 M tokens | 1.91 M tokens (this run) | **5.0×** |
| 1M single request (documented) | TTFT 566.7 s, 149.1 tok/s | TTFT ~2,100 s (35 min), ~154 tok/s | 3.7× faster TTFT |

Tokenizer caveat: the same document costs DeepSeek ~13–17% more tokens
(46K cell: 50,952 vs 45,185; 200K cell: 221,732 vs 196,366). So per *unit of
text* the prefill gap is slightly wider than the token-based ratios above
(≈5.2× at 46K, ≈3.6× at 200K).

Both models starve decode while another stream is prefilling: at 200K/C=4 the
median per-stream decode falls to 3.1 tok/s (MiMo) and 0.9 tok/s (DS), while the
first stream to finish prefill still decodes at 187 tok/s (MiMo) / 69 tok/s (DS).

Not comparable / skipped: MiMo's 1M-at-concurrency rows have no DeepSeek
counterpart on this node (its pool allows one 1M request, and a cold 1M prefill
takes ~35 min), and DeepSeek's 620K×3 production shape has no identical MiMo cell
(MiMo was measured at 200K×4 and 1M×1 instead).

## 1M-context concurrency sweep (MiMo only)

Same probe, `ctx=1,000,000`, 64 output tokens, unique prompt per stream, cells run
one after another so each gets the whole engine (raw log: `tmp/mimo26-1m-sweep.log`).

| C | wall | prompt tokens (sum) | TTFT min / median / max | aggregate prefill | fastest single-stream prefill | decode |
|---:|---:|---:|---|---:|---:|---|
| 1 | 572.9 s | 981,893 | 572.5 / 572.5 / 572.5 s | 1,715 tok/s | 1,715 tok/s | **169.2 tok/s** (clean, single stream) |
| 2 | 1,143.5 s | 1,963,699 | 572.8 / 1,143.0 / 1,143.0 s | 1,718 tok/s | 1,714 tok/s | first stream 138.4 tok/s; the stream decoding under the other's prefill floor **3.7 tok/s** |
| 4 | 1,141.5 s | 3,926,784 | 572.4 / 1,141.2 / 1,141.2 s | **3,441 tok/s** | 1,715 tok/s | same starvation floor 3.7 tok/s; per-stream numbers for the late streams are not usable (client read buffering), so only the floor is reported |

What the numbers say:

- **Aggregate prefill does not scale at C=2** (1,715 → 1,718 tok/s) but **doubles at
  C=4** (3,441 tok/s). Long prefills are effectively processed one at a time up to
  two requests, then two at a time — the engine's step budget
  (`--max-num-batched-tokens 4096`) is the lever to test next.
- **TTFT grows linearly with queue position**: the third and fourth 1M requests
  wait ~1,141 s, so tail latency at C=4 is ~19 min versus 9.5 min at C=1.
- **Decode is starved while any 1M prefill runs**: a stream that has finished
  prefill decodes at ~3.7 tok/s (same floor as 200K/C=4 → 3.1 tok/s; corroborated
  by the engine's own 10 s metrics, which report 2–6 tok/s aggregate generation
  throughput while 1–2 requests are running). Single-stream decode at 1M is
  169.2 tok/s.
- Practical rule for this node: send at most **2** concurrent 1M prefills when
  interactive latency matters; C=4 doubles aggregate prefill but pushes tail TTFT
  past 19 minutes.

## Decode-only concurrency (the number that matters in production)

Prefill/decode interference is a scheduling artefact users can live with; what
matters is **how fast C already-prefilled streams decode together**. Probe:
`tmp/llm-decode-sweep.py` — warm the shared prefix once (8 output tokens), then
fire C requests that share it (only a ~20-token unique suffix re-prefills) with
`ignore_eos`, 512 forced output tokens. The low TTFT column proves the prefix
cache hit, so the streams go straight to decode. Aggregate = sum of per-stream
rates (the streams overlap in wall time).

**46K context**

| C | MiMo decode/stream | MiMo aggregate | DeepSeek decode/stream | DeepSeek aggregate |
|---:|---:|---:|---:|---:|
| 1 | 358.6 tok/s | 358.6 tok/s | 232.4 tok/s | 232.4 tok/s |
| 2 | 285.8 | 571.7 | 199.9 | 399.8 |
| 4 | 219.3 | 882.9 | 164.3 | 648.1 |
| 8 | 148.1 | **1,122.2** | n/a (pool allows ≤4 slots at ≥400K ctx) | n/a |

**200K context**

| C | MiMo decode/stream | MiMo aggregate | DeepSeek decode/stream | DeepSeek aggregate |
|---:|---:|---:|---:|---:|
| 1 | 284.4 tok/s | 284.4 tok/s | 217.8 tok/s | 217.8 tok/s |
| 2 | 245.7 | 491.3 | 199.7 | 399.5 |
| 4 | 160.4 | 616.0 | 162.4 | **684.4** |
| 8 | 96.9 | **778.9** | n/a | n/a |

**1M context (MiMo only)**

| C | decode/stream | aggregate | median TTFT (warm prefix) |
|---:|---:|---:|---:|
| 1 | 158.2 tok/s | 158.2 tok/s | 4.0 s |
| 2 | 122.5 | 244.9 | 5.1 s |
| 4 | 81.3 | 344.7 | 8.5 s |
| 8 | 62.5 | **561.4** | 13.7 s |

Reading:

- **Per-stream speed falls ~linearly-ish with C**: MiMo keeps 41% of its
  single-stream rate at C=8 (46K), 34% at 200K, 40% at 1M. DeepSeek keeps ~71–75%
  at C=4, i.e. it scales a little more gracefully in *relative* terms, but from a
  lower single-stream base.
- **Aggregate decode scales sub-linearly**: MiMo 46K 358.6 → 1,122.2 tok/s
  (3.1× at 8×), 200K 284.4 → 778.9 (2.7×), 1M 158.2 → 561.4 (3.5×).
- **Context length is the dominant per-stream cost**: 46K → 200K → 1M costs MiMo
  21% / 56% of its single-stream decode rate (fp8 KV, 9 global-attention layers
  re-reading the whole context per token).
- **Absolute winner by cell**: MiMo leads at C≤2 everywhere (1.3–1.5×) and at 46K
  C=4; DeepSeek edges ahead at 200K C=4 aggregate (684 vs 616) and cannot reach
  C=8 at all on this node (its 1.91M-token pool caps ≥400K contexts at 4 slots).
- Warm-prefix TTFT is 0.3–2 s on both models at C≤4 (MiMo 1M: 4–14 s), so a
  continuing session pays the long prefill only once.

## VRAM utilization: how full is the card, and can it be fuller?

Engine-reported breakdown at `--gpu-memory-utilization 0.95` (per card, 85,651 MiB
= 83.65 GiB; device view 83.05 GiB):

```
Free memory on device (82.22/83.05 GiB) on startup.
Desired GPU memory utilization is (0.95, 78.9 GiB). Actual usage is 43.21 GiB for
consumed memory (weights + non-torch), 0.92 GiB for peak activation, and 0.12 GiB
for CUDAGraph memory. Replace gpu_memory_utilization config with
--kv-cache-memory=37035688141 (34.49 GiB) to fit into requested memory, or
--kv-cache-memory=40607249408 (37.82 GiB) to fully utilize gpu memory.
Current kv cache memory in use is 34.76 GiB.
```

| Setting | KV pool | KV per card | nvidia-smi used / card | Idle per card |
|---|---:|---:|---:|---:|
| `--gpu-memory-utilization 0.90` | 9,577,937 tokens | 30.53 GiB | 78,060–78,602 MiB | 6.9–7.4 GiB |
| `--gpu-memory-utilization 0.95` (default) | **10,877,194 tokens** | 34.76 GiB | 82,496 MiB (1M prefill peak 82,784) | **3.1 GiB** |
| `--kv-cache-memory=40607249408` (engine-suggested ceiling) | ~11.8 M tokens (extrapolated) | 37.82 GiB | ~85.0 GiB | ~0.6 GiB |

So the old 0.90 setting left ~7 GiB per card unused (~8.6% of the card); 0.95
recovers 4.2 GiB of KV (+13.6% pool) and still passes a 1M-token cold prefill
(981,754 prompt tokens, TTFT 573 s, no OOM). The engine's own ceiling suggestion
would squeeze the last ~3 GiB but leaves under 1 GiB of headroom, which is where
long-prefill allocation transients live — not enabled by default.

**Decode speed is not affected by this knob.** The A/B measurement at 46K, C=1,
512 forced tokens:

| util | decode | spec-decode acceptance |
|---|---:|---|
| 0.95 | 207.5 / 224.9 / 228.2 / 241.7 tok/s | 1.47 accepted tokens per draft step |
| 0.90 | 233.3 tok/s (earlier runs: 334.6 / 358.6) | 1.57 accepted tokens per draft step |

The spread comes from how well the DFlash drafter predicts the continuation
(χ ≈ 1.5 vs ≈ 2.9 accepted tokens per step measured upstream), not from the KV
pool size. **Treat 46K single-stream decode as 210–360 tok/s depending on
acceptance**, and the concurrency tables above as same-session comparisons.

### Capacity-tuning matrix (each lever tested alone)

All rows: TP4, fp8 KV, 1M context, `max-num-seqs 8`, 64 GiB CPU KV tier. Each
configuration was booted on its own and validated with a 1M-token cold prefill.

| Config | KV pool | Idle per card | 46K prefill C=1 | 1M prefill | 1M prefill peak idle | Verdict |
|---|---:|---:|---:|---:|---:|---|
| `util 0.90` | 9,577,937 | 6.9–7.4 GiB | 6,973 tok/s | 1,713 tok/s (573 s) | ~3.1 GiB | conservative |
| **`util 0.95` (default)** | **10,877,194** | **3.1 GiB** | 6,973 tok/s | 1,713 tok/s (573 s) | 2.9 GiB | **adopted** |
| `util 0.95` + `--max-num-batched-tokens 16384` | 8,353,998 (−23%) | 4.1 GiB | **7,420 tok/s (+6%)** | **1,906 tok/s (515 s, +11%)** | 2.1 GiB | speed-first opt-in |
| `--kv-cache-memory=40607249408` (37.82 GiB, engine suggestion) | — | — | — | — | — | **does not boot**: CUDA OOM, 6 MiB free |
| `--kv-cache-memory=38654705664` (36.0 GiB) | 11,264,034 | 2.0 GiB | — | 1,705 tok/s (576 s) | 1.4 GiB | boots, tight |
| `util 0.97` | **11,396,895** | 1.4–1.5 GiB | — | 1,724 tok/s (569 s) | **~1.05 GiB** | max capacity opt-in |

Reading:

- The engine's "fully utilize gpu memory" suggestion (37.82 GiB) **overshoots**:
  `--kv-cache-memory` skips memory profiling, so cudagraph and activation
  allocations have nothing left and startup dies with
  `CUDA out of memory. Tried to allocate 64.00 MiB ... 6.12 MiB is free`.
  Use the utilization knob (profiling preserved) instead of that number.
- `util 0.97` beats `util 0.95` by only **+4.8% pool** (11.40 M vs 10.88 M tokens)
  and gives up two thirds of the headroom (1.05 GiB vs 2.9 GiB left during a 1M
  prefill). It passed, but it is an opt-in, not the default.
- Raising `--max-num-batched-tokens` 4096 → 16384 buys **+11% at 1M prefill and
  +6% at 46K** and costs **23% of the pool** (activation memory has to come from
  somewhere). Worth it only for prefill-heavy workloads.
- The levers were not combined: 16384-token chunks plus util 0.97 would need both
  the activation budget and the pool, which does not fit.

Opt-in switches on the launcher: `MIMO26_UTIL=0.97` (max capacity),
`MIMO26_MAX_BATCHED=16384` (max prefill speed), `MIMO26_KV_MEM=<bytes>` (manual
pool pinning).

## Raw logs

- Launcher/startup: `tmp/mimo26-start.log`, `docker logs mimo26-flash`
- 1M probe: `tmp/mimo26-1m-test.log`
- Recipe probe output: this file (commands in `## Verified behaviour`)
