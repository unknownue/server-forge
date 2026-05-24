# Benchmark Suite

LLM inference performance tests for AI training servers.

## Quick Start

```bash
# Full pipeline: download model, start server, run benchmark
bash benchmark/llm/bench/run-all.sh [MODEL_ID] [GPUS] [BACKEND]

# Or run each step individually:
bash benchmark/llm/serve/serve-sglang.sh [MODEL_ID] [GPUS] [PORT]   # start SGLang server
bash benchmark/llm/serve/serve-vllm.sh [MODEL_ID] [GPUS] [PORT]    # start vLLM server
bash benchmark/llm/serve/serve-unsloth.sh                           # start Unsloth Studio
bash benchmark/llm/bench/bench-aiperf.sh [BASE_URL] [MODEL] [HF_ID] # run benchmark
```

## LLM Inference Benchmark

End-to-end pipeline: download model → start inference server → run AIPerf benchmark.

### `serve/` — Inference Servers

| Script | Backend | Notes |
|--------|---------|-------|
| [serve-sglang.sh](llm/serve/serve-sglang.sh) | SGLang | Blackwell-compatible (default), FP8/NVFP4 optimized |
| [serve-vllm.sh](llm/serve/serve-vllm.sh) | vLLM | General-purpose OpenAI-compatible server |
| [serve-unsloth.sh](llm/serve/serve-unsloth.sh) | Unsloth Studio | Custom image (built from `nodes/.../unsloth/Dockerfile`) |

All servers expose an OpenAI-compatible API at `http://localhost:8000`.

### `bench/` — Benchmark Tools

| Script | Purpose |
|--------|---------|
| [run-all.sh](llm/bench/run-all.sh) | Full pipeline orchestrator (download → serve → bench) |
| [bench-aiperf.sh](llm/bench/bench-aiperf.sh) | Run AIPerf against any OpenAI-compatible endpoint |
| [build-aiperf.sh](llm/bench/build-aiperf.sh) | Build the AIPerf Docker image from submodule |
| [test-sglang.sh](llm/bench/test-sglang.sh) | Quick smoke test for SGLang server |

Results are saved to `tmp/benchmark-results/`.

## Model Management

Models are downloaded with [nodes/ubuntu26-node1-server/download-model.sh](../nodes/ubuntu26-node1-server/download-model.sh) to `/data/work/models/<org>/<model_name>/`, pinned by revision. The format field controls which files are downloaded (`safetensors` default, `gguf`, or `full`).
