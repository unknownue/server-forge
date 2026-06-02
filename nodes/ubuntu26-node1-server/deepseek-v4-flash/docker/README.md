# DSV4-Flash-Acti-MTP — Docker image

Reproducible Docker image for serving
[`LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8`](https://huggingface.co/LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8)
via the patched `jasl/vllm` fork at the validated pin (`b158e5001`) with all
three Acti MTP-loader patches applied inline.

The image is the **vLLM serving stack**. Model weights are **not** baked in —
mount them as a volume at runtime so the image stays ~12 GB instead of ~160 GB.

## What's in the image

- NVIDIA CUDA 12.9 + cuDNN runtime, Ubuntu 24.04
- Python 3.12, torch 2.11.0+cu128
- vLLM fork `jasl/vllm@b158e5001`
- pasta-paul's `packed_modules_mapping` patch on `DeepseekV4ForCausalLM`
- Acti's three MTP-loader patches on `DeepSeekV4MTP`
  (patch 4a: `prefix=` on e_proj/h_proj · patch 4b: class-level
  `packed_modules_mapping` · patch 4c: `.weight_scale` not `_inv`)
- An entrypoint that launches vLLM with the validated production config
  (524k context, MTP self-spec, `--disable-custom-all-reduce`, NCCL Max-Q tuning)

## Prerequisites

1. Docker 24+ on a host with NVIDIA GPUs.
2. **`nvidia-container-toolkit`** installed and Docker configured to use it (this image's `docker run --gpus all` requires it):

   ```bash
   # Add NVIDIA's apt repo, then:
   sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   ```

   Verify with `docker info | grep -i nvidia` — you should see `Runtimes: io.containerd.runc.v2 nvidia runc` and `nvidia-container-runtime` listed.

## Build

```bash
cd docker
docker build -t dsv4-flash-acti-mtp:0.1.0 .
```

Build time on a fast workstation: ~25–45 min (vLLM CUDA kernels compile). The image lands at ~10.5 GB.

## Download the model weights

```bash
mkdir -p $HOME/dsv4-models
HF_HUB_ENABLE_HF_TRANSFER=1 hf download \
  LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8 \
  --local-dir $HOME/dsv4-models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8
```

Total size: ~146 GB. Allow 30–60 min on a 100 MB/s connection.

## Run

Two-GPU production config (RTX PRO 6000 Max-Q / DGX Spark / H200-class):

```bash
docker run --rm --gpus all \
  --shm-size=16g \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -p 8000:8000 \
  -v $HOME/dsv4-models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8:/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8:ro \
  dsv4-flash-acti-mtp:0.1.0
```

Or via the included docker-compose:

```bash
MODEL_HOST_PATH=$HOME/dsv4-models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8 \
  docker compose up
```

## Smoke test

After ~75 s the server prints `Application startup complete`:

```bash
curl -fsS http://127.0.0.1:8000/v1/models | jq .
curl -fsS -X POST http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer EMPTY" \
  --data '{"model":"deepseek-v4-flash","stream":false,"max_tokens":16,"temperature":0.0,
           "messages":[{"role":"user","content":"Reply with exactly: DOCKER_OK"}]}'
```

## Knobs (override via `-e`)

| Env var | Default | Notes |
|---|---|---|
| `MODEL_PATH` | `/models/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8` | Mounted snapshot |
| `TENSOR_PARALLEL_SIZE` | `2` | TP across local GPUs |
| `MAX_MODEL_LEN` | `524288` | Context cap |
| `MAX_NUM_SEQS` | `2` | Concurrent in-flight requests |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | Per-step prefill batch |
| `GPU_MEMORY_UTILIZATION` | `0.93` | Drop to 0.90 if KV pool too small |
| `BLOCK_SIZE` | `256` | Paged-KV page size (V4-Flash requires 256) |
| `DISABLE_CUSTOM_ALL_REDUCE` | `1` | **Must be 1 on Max-Q / no-NVLink** |
| `ENABLE_MTP` | `1` | Set 0 to disable speculative decoding |
| `PORT` | `8000` | HTTP port inside the container |

Alternative profiles (override `MAX_MODEL_LEN` + `MAX_NUM_SEQS`):

| Profile | `MAX_MODEL_LEN` | `MAX_NUM_SEQS` | `GPU_MEMORY_UTILIZATION` | Aggregate TPS (measured) |
|---|---:|---:|---:|---:|
| Long-context (prod) | `524288` | `2` | `0.93` | 124 |
| Medium (256k) | `262144` | `4` | `0.95` | 296 |
| High-concurrency (128k) | `131072` | `8` | `0.90` | 467 |

## Pushing to a registry

The image is not bundled in the HF repo (binary too large for typical use).
To publish your build to Docker Hub or GitHub Container Registry:

```bash
docker tag dsv4-flash-acti-mtp:0.1.0 <your-namespace>/dsv4-flash-acti-mtp:0.1.0
docker login                            # or: docker login ghcr.io
docker push <your-namespace>/dsv4-flash-acti-mtp:0.1.0
```

## License

Apache-2.0 for the Acti-side additions. Underlying components retain their
upstream licenses (vLLM Apache-2.0, DeepSeek-V4-Flash see the base model card,
pasta-paul quant see that author's repo).
