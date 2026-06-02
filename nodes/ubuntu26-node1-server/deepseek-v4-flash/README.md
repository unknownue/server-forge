# DeepSeek-V4-Flash — vLLM + MTP Deployment

**Date**: 2026-06-01
**Hardware**: ubuntu26-node1-server (4× RTX 6000D 85.6GB, Intel Xeon w7-3545 48T, 247GB RAM)
**vLLM Image**: `dsv4-flash-acti-mtp:0.1.0` (jasl/vllm + CT quant + Acti MTP patches)

## Sources

Configurations validated against:
- [LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8](https://huggingface.co/LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8) model card
- [AIServerSetup: DS4-Flash production config](../../submodules/AIServerSetup/07-RTX%20PRO%206000%20Blackwell%20Server%20Setup/DS4-Flash.md)

## Model

| Attribute | Value |
|-----------|-------|
| Model ID | `LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8` |
| Architecture | MoE + MLA + MTP (43 decoder layers + 1 MTP layer) |
| Total params | 284B (13B activated) |
| Routed experts | 256 per layer, top-K=6 with noaux_tc routing |
| Quantization | W4A16 INT4 (routed experts) + FP8_BLOCK (attention) + BF16 (shared) |
| Size | ~145 GB on disk, ~145 GB in VRAM (4-bit) |
| MTP Head | model-mtp-w4a16.safetensors (3.55 GB, GPTQ v2) |
| Location | `/data/work/models/LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8/` |

## VRAM Budget

Model requires **2 GPUs** — W4A16 weights occupy ~145 GB in VRAM, single RTX 6000D has 85.6 GB.

| Resource | Value |
|----------|-------|
| 2× RTX 6000D total VRAM | 171.2 GB |
| Model weights (W4A16 INT4) | ~145 GB |
| MLA KV cache rate | ~27 KB/token (FP8) |
| At 0.93 util | 159.2 GB usable → ~14.2 GB for KV → ~526K tokens |
| At 0.90 util | 154.1 GB usable → ~9.1 GB for KV → ~337K tokens |

Reference hardware (model card): 2× RTX PRO 6000 Blackwell Max-Q 96GB = 192 GB total.
We have ~89% of reference VRAM — profiles scaled accordingly.

## Deployment

### Default Plan (one-click)

```bash
bash nodes/ubuntu26-node1-server/deepseek-v4-flash/deploy.sh
```

```
GPU 0,1: DeepSeek-V4-Flash W4A16-FP8 TP=2 → :8000
128K context, 3 concurrent, 0.93 util, MTP enabled
```

### Profile Options

| Profile | Context | Concurrent | GPU Util | KV Used | Est. TPS¹ | Use Case |
|---------|--:|--:|--:|--:|--:|------|
| **default** | 128K | 3 | 0.93 | 10.6 GB | ~200 | Balanced multi-user |
| **plan-long** | 256K | 2 | 0.93 | 14.2 GB | ~150 | Deep analysis, RAG |
| **plan-524k** | 524K | 1 | 0.93 | 14.2 GB | ~85 | Solo max-context |
| **plan-high** | 64K | 5 | 0.90 | 8.9 GB | ~250 | Agent fleet, high concurrency |

¹ Estimated on 2×85.6GB, scaled from model card benchmarks on 2×96GB.

### Model Card Validated Benchmarks (for reference, 2×96GB)

| Profile | Context | Concurrent | GPU Util | Aggregate TPS |
|---------|--:|--:|--:|--:|
| 128k | 131072 | 8 | 0.90 | 467 |
| 256k | 262144 | 4 | 0.95 | 296 |
| 524k | 524288 | 3 | 0.93 | 138 |

Single-stream: 87 tok/s @524k, 111 tok/s @128k. MTP gives 1.62× speedup vs no-MTP baseline.

## Architecture Notes

### vLLM Patches (applied in Docker image)
1. **jasl/vllm** fork at `abad5dc7` — SM120 Blackwell support
2. **CT quant** (kyle-ct-quant.patch) — compressed-tensors W4A16 support
3. **packed_modules_mapping** — pasta-paul's patch on DeepseekV4ForCausalLM
4. **MTP loader patches** — Acti's 3 patches for MTP weight loading
   - 4a: `prefix=` on e_proj/h_proj ReplicatedLinear
   - 4b: class-level packed_modules_mapping
   - 4c: `.weight_scale` (not `_inv`) in MTP loader

### MTP (Multi-Token Prediction)
`--speculative-config '{"method":"mtp","num_speculative_tokens":1}'`.
Predicts 1 draft token per step (num_nextn_predict_layers=1). Main model verifies.
1.62× decode speedup over no-MTP baseline.

### MLA (Multi-head Latent Attention)
DeepSeek V4 uses compressed KV cache via low-rank latent attention:
- kv_lora_rank=512, qk_rope_head_dim=64
- KV per token ≈ 2 × 43 × 576 × 1 byte (FP8) ≈ **27 KB/token**
- ~20× smaller than standard MHA KV cache (~512 KB/token)

### No NVLink
RTX 6000D uses PCIe Gen5 (no NVLink). `--disable-custom-all-reduce` is **required** —
vLLM's CustomAllreduce uses CUDA P2P that deadlocks on PCIe-only topology.
NCCL Ring algorithm used instead.

## Quick Start

```bash
# 1. Build image (one-time)
bash nodes/ubuntu26-node1-server/deepseek-v4-flash/docker/build.sh

# 2. Deploy
bash nodes/ubuntu26-node1-server/deepseek-v4-flash/deploy.sh

# 3. Test endpoint
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer EMPTY" \
  -d '{"model":"deepseek-v4-flash","stream":false,"max_tokens":32,"temperature":0.0,
       "messages":[{"role":"user","content":"Hello"}]}'

# 4. Stop
bash nodes/ubuntu26-node1-server/deepseek-v4-flash/stop.sh

# 5. Switch profile
bash nodes/ubuntu26-node1-server/deepseek-v4-flash/deploy.sh plan-524k
```

## Key Flags

| Flag | Value | Purpose |
|------|-------|---------|
| `--tensor-parallel-size` | 2 | Split model across 2 GPUs |
| `--kv-cache-dtype` | fp8 | FP8 KV cache for memory efficiency |
| `--block-size` | 256 | Paged-KV page size (V4-Flash requires 256) |
| `--disable-custom-all-reduce` | 1 | Required on PCIe-only (no NVLink) |
| `--speculative-config` | mtp, 1 token | MTP speculative decoding |
| `--tokenizer-mode` | deepseek_v4 | DSV4-specific tokenizer handling |
| `--reasoning-parser` | deepseek_v4 | Split thinking/content output |
| `--tool-call-parser` | deepseek_v4 | Native function calling |
| `--enable-auto-tool-choice` | — | Auto-select tools |

## NCCL Tuning (from Acti's validated set)

| Env | Value | Why |
|-----|-------|-----|
| `NCCL_P2P_DISABLE=1` | Disable CUDA P2P | No NVLink |
| `NCCL_PROTO=LL` | Low-latency protocol | Small TP messages |
| `NCCL_ALGO=Ring` | Ring algorithm | PCIe topology |
| `NCCL_MIN_NCHANNELS=8` | 8 channels | Reduces TTFT ~40% |
| `NCCL_NTHREADS=512` | 512 threads | Sufficient for 2-GPU |
| `VLLM_USE_FLASHINFER_SAMPLER=0` | Disable | Compatibility |
| `VLLM_ENABLE_DEEPSEEK_V4_SPARSE_MLA_WARMUP=0` | Disable | Stability |

## File Structure

```
deepseek-v4-flash/
├── README.md              # This file
├── deploy.sh              # One-click deployment (4 profiles)
├── stop.sh                # Stop all containers
├── config/
│   └── services.yaml      # Service definitions
├── docker/                 # Docker build and compose files
│   ├── Dockerfile          # vLLM patched build
│   ├── build.sh            # Build script
│   ├── docker-compose.yml  # Compose alternative
│   ├── entrypoint.sh       # vLLM launch script
│   ├── apply_mtp_patches.py
│   └── kyle-ct-quant.patch
├── serve/
│   └── serve-text.sh       # Start single model instance
├── test/
│   ├── throughput-test.sh
│   └── simulate-agents.sh
└── results/                # Benchmark outputs
```
