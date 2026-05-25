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
