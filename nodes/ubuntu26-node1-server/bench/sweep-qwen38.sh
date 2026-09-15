#!/bin/bash
# Qwen3.8-27B-NVFP4 memory-parameter sweep: TP=1 vs TP=2 across context-length /
# mem-fraction-static / mamba-full-memory-ratio combinations.
#
# Per run: boot -> idle GPU mem -> bench (64x512in/128out, conc 8) -> accept-rate
#          -> context ladder (ascending, stop at first failure) -> teardown.
# Results appended to tmp/sweep-qwen38/results.csv as each run finishes.
#
# Usage: bash tmp/sweep-qwen38.sh            # all 8 configs, sequential

set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="lmsysorg/sglang:qwen38-27b"
MODEL="/data/work/models/RadixArk/Qwen3.8-27B-NVFP4"
DRAFT="/data/work/models/RadixArk/Qwen3.8-27B-DSpark"
PORT=30000
NAME="qwen-sglang-sweep"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUT="$REPO_ROOT/tmp/sweep-qwen38"
CSV="$OUT/results.csv"
mkdir -p "$OUT"

# tag | gpus | tp | ctx | frac | ratio | spec(1/0)
CONFIGS=(
  "t1-ctx256k-f095-r12|0|1|262144|0.95|11.93|1"
  "t1-ctx128k-f095-r12|0|1|131072|0.95|11.93|1"
  "t1-ctx128k-f085-r8|0|1|131072|0.85|8|1"
  "t1-ctx64k-f075-r5|0|1|65536|0.75|5|1"
  "t1-ctx128k-f085-r8-nospec|0|1|131072|0.85|8|0"
  "t2-ctx256k-f095-r12|0,1|2|262144|0.95|11.93|1"
  "t2-ctx128k-f085-r8|0,1|2|131072|0.85|8|1"
  "t2-ctx64k-f075-r5|0,1|2|65536|0.75|5|1"
)
LADDER_ALL="8192,16384,32768,65536,98304,131072,163840,196608,229376,262144"

log() { echo "[$(date +%H:%M:%S)] $*"; }

gpu_used() { # $1 = gpu index
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$1" 2>/dev/null | tr -d ' '
}

wait_gpus_free() { # $1 = "0" or "0,1"
  IFS=',' read -ra GS <<< "$1"
  for _ in $(seq 1 40); do
    local allfree=1
    for g in "${GS[@]}"; do
      local u
      u=$(gpu_used "$g")
      if [[ -z "$u" ]] || [[ "$u" -gt 2000 ]]; then allfree=0; fi
    done
    [[ $allfree -eq 1 ]] && return 0
    sleep 5
  done
  log "WARN: GPU not free after 200s: $(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits | tr '\n' ' ')"
}

wait_boot() { # $1 = tag; returns boot_ok boot_s
  local t0
  t0=$(date +%s)
  for _ in $(seq 1 120); do
    if curl -sS -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
      echo "1 $(( $(date +%s) - t0 ))"
      return
    fi
    # container died -> boot failed
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      echo "0 $(( $(date +%s) - t0 ))"
      return
    fi
    sleep 5
  done
  echo "0 $(( $(date +%s) - t0 ))"
}

accept_rate() {
  docker logs "$NAME" 2>&1 | grep -oE 'accept len: [0-9.]+' | awk '{s+=$3; n++} END {if (n) printf "%.2f", s/n; else printf ""}'
}

max_model_len() {
  curl -sS -m 3 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
    | grep -oE '"max_model_len":[0-9]+' | head -1 | cut -d: -f2
}

run_config() {
  local tag="$1" gpus="$2" tp="$3" ctx="$4" frac="$5" ratio="$6" spec="$7"
  local runlog="$OUT/$tag.log"
  log "=== START $tag (gpus=$gpus tp=$tp ctx=$ctx frac=$frac ratio=$ratio spec=$spec) ==="
  docker rm -f "$NAME" >/dev/null 2>&1
  wait_gpus_free "$gpus"

  local spec_args=()
  if [[ "$spec" == "1" ]]; then
    spec_args=(--speculative-draft-model-path "$DRAFT" --speculative-algorithm DSPARK)
  fi
  local tp_args=()
  if [[ "$tp" -gt 1 ]]; then tp_args=(--tp-size "$tp"); fi

  docker run -d --rm --name "$NAME" --gpus all \
    -e "CUDA_VISIBLE_DEVICES=$gpus" \
    -e NCCL_P2P_LEVEL=PHB -e NCCL_IB_DISABLE=1 \
    -e NCCL_MIN_NCHANNELS=8 -e NCCL_MAX_NCHANNELS=8 \
    -p "$PORT:$PORT" \
    -v /data/work/models:/data/work/models \
    "$IMAGE" python3 -m sglang.launch_server \
      --model-path "$MODEL" \
      "${spec_args[@]}" "${tp_args[@]}" \
      --context-length "$ctx" \
      --mem-fraction-static "$frac" \
      --mamba-full-memory-ratio "$ratio" \
      --host 0.0.0.0 --port "$PORT" \
    >"$runlog" 2>&1
  local drc=$?
  if [[ $drc -ne 0 ]]; then
    log "docker run failed rc=$drc"; echo "$tag,boot_rc=$drc" >> "$CSV"; return
  fi

  local boot_ok boot_s
  read -r boot_ok boot_s <<< "$(wait_boot "$tag")"
  log "$tag: boot_ok=$boot_ok boot_s=${boot_s}s"
  if [[ "$boot_ok" != "1" ]]; then
    local tailmsg
    tailmsg=$(docker logs "$NAME" 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-160)
    echo "$tag,$gpus,$tp,$ctx,$frac,$ratio,$spec,0,$boot_s,,,,,,,,,,,,,,,,boot_fail: $tailmsg" >> "$CSV"
    docker rm -f "$NAME" >/dev/null 2>&1
    return
  fi

  local mml idle0 idle1
  mml=$(max_model_len)
  idle0=$(gpu_used 0)
  idle1=""
  if [[ "$gpus" == *","* ]]; then idle1=$(gpu_used 1); fi
  log "$tag: idle mem gpu0=${idle0}MiB gpu1=${idle1:-n/a}MiB max_model_len=$mml"

  # ---- bench ----
  local bench_json
  bench_json=$(MODEL_ID="$MODEL" N_PROMPTS=64 CONC=8 INPUT_TOKENS=512 MAX_TOKENS=128 node "$SCRIPT_DIR/bench-client-qwen38.cjs" bench 2>&1)
  log "$tag: bench $bench_json"
  local ar
  ar=$(accept_rate)
  log "$tag: accept_rate=$ar"

  # ---- context ladder (sizes <= ctx) ----
  local ladder_sizes=()
  IFS=',' read -ra ALL <<< "$LADDER_ALL"
  for s in "${ALL[@]}"; do [[ "$s" -le "$ctx" ]] && ladder_sizes+=("$s"); done
  local lad
  lad=$(IFS=','; echo "${ladder_sizes[*]}")
  local ladder_json
  ladder_json=$(MODEL_ID="$MODEL" MAX_TOKENS=32 LADDER_SIZES="$lad" node "$SCRIPT_DIR/bench-client-qwen38.cjs" ladder 2>&1)
  log "$tag: ladder $ladder_json"

  local post0 post1 alive
  post0=$(gpu_used 0)
  post1=""
  if [[ "$gpus" == *","* ]]; then post1=$(gpu_used 1); fi

  # parse ladder max ok size + prompt tokens
  local lmax=0 lpt=0 lalive=0
  lmax=$(echo "$ladder_json" | grep -oE '"size":[0-9]+,"ok":1' | grep -oE '[0-9]+$' | tail -1)
  [[ -z "$lmax" ]] && lmax=0
  lpt=$(echo "$ladder_json" | grep -oE '"promptTokens":[0-9]+' | tail -1 | grep -oE '[0-9]+')
  [[ -z "$lpt" ]] && lpt=0
  lalive=$(echo "$ladder_json" | grep -oE '"serverAlive":[01]' | grep -oE '[01]$')
  [[ -z "$lalive" ]] && lalive=0

  local b_ok b_fail b_wall b_ops b_tt b_tt50 b_itl b_err
  b_ok=$(echo "$bench_json" | grep -oE '"ok":[0-9]+' | head -1 | grep -oE '[0-9]+$'); [[ -z "$b_ok" ]] && b_ok=""
  b_fail=$(echo "$bench_json" | grep -oE '"failed":[0-9]+' | grep -oE '[0-9]+$'); [[ -z "$b_fail" ]] && b_fail=""
  b_wall=$(echo "$bench_json" | grep -oE '"wallSec":[0-9.]+' | grep -oE '[0-9.]+$')
  b_ops=$(echo "$bench_json" | grep -oE '"outputTokPerSec":[0-9.]+' | grep -oE '[0-9.]+$')
  b_tt=$(echo "$bench_json" | grep -oE '"ttftMeanMs":[0-9]+' | grep -oE '[0-9]+$')
  b_tt50=$(echo "$bench_json" | grep -oE '"ttftP50Ms":[0-9]+' | grep -oE '[0-9]+$')
  b_itl=$(echo "$bench_json" | grep -oE '"itlMeanMs":[0-9.]+' | grep -oE '[0-9.]+$')

  echo "$tag,$gpus,$tp,$ctx,$frac,$ratio,$spec,1,$boot_s,$idle0,${idle1:-},$mml,$b_ok,$b_fail,$b_wall,$b_ops,$b_tt,$b_tt50,$b_itl,$ar,$lmax,$lpt,$lalive,$post0,${post1:-}" >> "$CSV"

  docker rm -f "$NAME" >/dev/null 2>&1
  log "=== DONE $tag ==="
}

echo "tag,gpus,tp,ctx,frac,ratio,spec,boot_ok,boot_s,idle_mem0_mib,idle_mem1_mib,max_model_len,bench_ok,bench_failed,wall_s,out_tok_s,ttft_mean_ms,ttft_p50_ms,itl_mean_ms,accept_rate,ladder_max_ok_tokens,ladder_prompt_tokens,ladder_server_alive,post_mem0_mib,post_mem1_mib" > "$CSV"

for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r tag gpus tp ctx frac ratio spec <<< "$cfg"
  run_config "$tag" "$gpus" "$tp" "$ctx" "$frac" "$ratio" "$spec"
done

log "ALL CONFIGS DONE. Results: $CSV"
