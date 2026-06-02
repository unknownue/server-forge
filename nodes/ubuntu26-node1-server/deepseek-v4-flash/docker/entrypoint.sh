#!/usr/bin/env bash
# Entrypoint: launch vLLM with the validated DSV4-Flash MTP serve config.
# Knobs are env vars (see Dockerfile defaults). Pass any extra CLI args via
# `docker run ... dsv4-flash-acti-mtp:0.1.0 <extra args>`.
set -euo pipefail

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "[entrypoint] MODEL_PATH=$MODEL_PATH not found." >&2
  echo "[entrypoint] Mount the HF snapshot of LordNeel/DeepSeek-V4-Flash-Acti-MTP-W4A16-FP8" >&2
  echo "[entrypoint] at $MODEL_PATH or override with -e MODEL_PATH=..." >&2
  exit 2
fi

cmd=(
  vllm serve "$MODEL_PATH"
  --served-model-name deepseek-v4-flash deepseek-v4-flash-mtp DSV4-W4A16-FP8 deepseek-ai/DeepSeek-V4-Flash
  --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"
  --kv-cache-dtype fp8
  --block-size "$BLOCK_SIZE"
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --tokenizer-mode deepseek_v4
  --tool-call-parser deepseek_v4
  --enable-auto-tool-choice
  --reasoning-parser deepseek_v4
  --trust-remote-code
  --host "$HOST"
  --port "$PORT"
)

if [[ "${DISABLE_CUSTOM_ALL_REDUCE:-1}" == "1" ]]; then
  cmd+=( --disable-custom-all-reduce )
fi

if [[ "${ENABLE_MTP:-1}" == "1" ]]; then
  cmd+=( --speculative-config '{"method":"mtp","num_speculative_tokens":1}' )
fi

# Append any extra args the caller passed.
cmd+=( "$@" )

echo "[entrypoint] launching: ${cmd[*]}"
exec "${cmd[@]}"
