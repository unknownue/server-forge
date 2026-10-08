#!/bin/bash
# Download the ComfyUI model set for the MiniMax H3 generation service.
#
# The filenames are fixed by the two AMD workflows (spec: tmp/COMFYUI_DEPLOY.md
# §5) — ComfyUI loader dropdowns must list them exactly. Sources are HF repos
# reachable through hf-mirror.com (github.com is unreachable from this network,
# see README "Mirror & offline-install notes").
#
# Layout: files land directly under /data/work/comfyui/models/<dir>/ (the
# ComfyUI app tree lives at /data/work/comfyui; models stay under /data per the
# shared storage layout). Downloads resume (-C -) and run 3-wide in parallel.
#
# Every file's byte size and source revision (resolve-URL ETag = commit SHA) is
# appended to tmp/comfyui/g1-model-sizes.tsv — that table feeds the G1 report.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/download-comfyui-models.sh          # all
#   bash nodes/ubuntu-server-node-2/download-comfyui-models.sh <regex>   # subset

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/discover.sh"

HF="${HF_ENDPOINT:-https://hf-mirror.com}"
DEST_ROOT="${COMFYUI_HOME:-/data/work/comfyui}/models"
MANIFEST_DIR="$REPO_ROOT/tmp/comfyui"
MANIFEST="$MANIFEST_DIR/g1-model-sizes.tsv"
FILTER="${1:-}"
JOBS=3

# src_repo | src_path (relative to repo root) | dest_subdir | dest_filename
# shellcheck disable=SC2016
MODELS=(
    "Comfy-Org/MiniMax-H3|diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors|diffusion_models|minimax_h3_ref2va_int8_convrot.safetensors"
    # §5 #2 — 25.9 GiB (measured, see manifest): exceeds 24 GiB, so the §5 #2f
    # nvfp4/awq fallback is downloaded up front per the spec's own trigger.
    "RunningHubAI/rh-lsfqwen3vl-32b-minimax-h3-ultra-uncensored-heretic-int8-convrot.safetensors-checkpoint|qwen3vl_32b_minimax_h3_ultra_uncensored_heretic_int8_convrot.safetensors|text_encoders|qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors"
    "Comfy-Org/MiniMax-H3|text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders|qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
    "Comfy-Org/MiniMax-H3|vae/minimax_h3_video_vae_fp16.safetensors|vae|minimax_h3_video_vae_fp16.safetensors"
    "Comfy-Org/MiniMax-H3|vae/minimax_h3_audio_vae_fp32.safetensors|vae|minimax_h3_audio_vae_fp32.safetensors"
    "larryvrh/MiniMax-H3-Turbo-Lora|minimax_h3_turbo_v4_step600_ema.safetensors|loras|minimax_h3_turbo_v4_step600_ema.safetensors"
    "Comfy-Org/z_image_turbo|split_files/diffusion_models/z_image_turbo_bf16.safetensors|diffusion_models|z_image_turbo_bf16.safetensors"
    "Comfy-Org/z_image_turbo|split_files/text_encoders/qwen_3_4b.safetensors|text_encoders|qwen_3_4b.safetensors"
    "Comfy-Org/z_image_turbo|split_files/vae/ae.safetensors|vae|ae.safetensors"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

fetch_one() {
    local repo="$1" src="$2" sub="$3" name="$4"
    local url dir out tmp etag size
    dir="$DEST_ROOT/$sub"
    out="$dir/$name"
    tmp="$out.part"
    mkdir -p "$dir"

    if [[ -s "$out" ]]; then
        log "SKIP  $name (already present, $(stat -c%s "$out") bytes)"
        return 0
    fi

    url="$HF/$repo/resolve/main/$src"
    log "GET   $name  <-  $repo/$src"
    if ! curl -fL --retry 8 --retry-delay 5 --connect-timeout 20 -C - -o "$tmp" "$url"; then
        log "FAIL  $name (download error)"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$out"

    # Resolve-URL ETag / x-linked-etag is the HF commit SHA the file came from.
    etag="$(curl -sIL "$url" | tr -d '\r' | awk -F'"' '/^x-linked-etag:|^etag:/{print $2; exit}')"
    size="$(stat -c%s "$out")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$sub" "$size" "$repo" "${etag:-unknown}" "$(date -u +%FT%TZ)" >> "$MANIFEST"
    log "OK    $name ($size bytes, rev ${etag:-unknown})"
}

mkdir -p "$MANIFEST_DIR"
touch "$MANIFEST"

# Deduplicate the manifest: a re-run rewrites rows for files it (re)fetched.
fetch_all() {
    local row rc=0
    local -a pids=()
    for row in "${MODELS[@]}"; do
        if [[ -n "$FILTER" && ! "$row" =~ $FILTER ]]; then continue; fi
        IFS='|' read -r repo src sub name <<<"$row"
        fetch_one "$repo" "$src" "$sub" "$name" &
        pids+=($!)
        # Throttle to $JOBS concurrent transfers.
        while (( $(jobs -rp | wc -l) >= JOBS )); do
            wait -n || rc=1
        done
    done
    for pid in "${pids[@]:-}"; do
        wait "$pid" || rc=1
    done
    return $rc
}

fetch_all

# Collapse duplicate manifest rows (kept when a file was fetched more than once).
if [[ -s "$MANIFEST" ]]; then
    tac "$MANIFEST" | awk -F'\t' '!seen[$1]++' | tac > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

log "Done. Manifest: $MANIFEST"
log "Installed files:"
find "$DEST_ROOT" -name '*.safetensors' -printf '  %p\t%s bytes\n' | sort