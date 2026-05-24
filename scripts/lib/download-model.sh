#!/bin/bash
# Download LLM models from HuggingFace to /data/work/models/.
# Model files are version-pinned for reproducibility.
#
# Usage:
#   bash scripts/lib/download-model.sh                    # download all registered models
#   bash scripts/lib/download-model.sh [MODEL_ID]         # download a specific model
#   bash scripts/lib/download-model.sh [MODEL_ID] [REV] [FORMAT]
#
# Models are stored at /data/work/models/<org>/<model>/ with
# .model_id, .revision, .downloaded_at files for reproducibility.
#
# Format (3rd field, defaults to safetensors):
#   safetensors       — safetensors weights + common configs/tokenizer
#   gguf              — all GGUF files + common configs/tokenizer
#   gguf:<quant>      — GGUF files matching <quant> + common  (e.g. gguf:Q4_K_M)
#   full              — no filtering, download everything
#   <glob> ...        — custom allow_patterns (space-separated, e.g. "*.safetensors *.json")

set -euo pipefail

# ── Discover current node ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$FORGE_REPO_ROOT/scripts/lib/discover.sh"

# ── Load per-node model registry ──
MODELS_CONF="$FORGE_NODE_DIR/config/models.conf"
if [[ ! -f "$MODELS_CONF" ]]; then
    echo "ERROR: Model config not found: $MODELS_CONF" >&2
    echo "Create it with a MODELS array to register models for this node." >&2
    exit 1
fi
source "$MODELS_CONF"

export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

# ── File patterns by weight format ──
# Common patterns (configs + tokenizer) are always included unless format=full.
# Explicit file names are used instead of broad "*.json" to avoid pulling in
# training artifacts (training_args.json, etc.).
COMMON_PATTERNS=(
    "config.json"
    "generation_config.json"
    "tokenizer.json"
    "tokenizer_config.json"
    "special_tokens_map.json"
    "vocab.json"
    "merges.txt"
    "added_tokens.json"
    "tokenizer.model"
    "chat_template.jinja"
    "preprocessor_config.json"
)

SAFETENSORS_PATTERNS=(
    "*.safetensors"
    "model.safetensors.index.json"
)

GGUF_PATTERNS=(
    "*.gguf"
)

# ── Ensure huggingface_hub is available ──
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "ERROR: huggingface_hub not installed." >&2
    echo "Run: sudo bash $FORGE_NODE_DIR/provision/install-packages.sh" >&2
    exit 1
fi

# ── Resolve target list ──
if [[ $# -ge 1 ]]; then
    FORMAT="${3:-safetensors}"
    TARGETS=("${1}|${2:-main}|${FORMAT}")
else
    TARGETS=("${MODELS[@]}")
fi

SYNC_MODE=false
if [[ $# -eq 0 ]]; then
    SYNC_MODE=true
fi

if [[ -n "${HF_ENDPOINT:-}" ]]; then
    echo "HF_ENDPOINT: $HF_ENDPOINT"
fi

DOWNLOADED=0
SKIPPED=0
FAILED=0
ORPHANS=0

# ── Orphan cleanup (full-sync only) ──
# Remove model directories that exist on disk but are not in the registry.
if $SYNC_MODE; then
    declare -A EXPECTED
    for entry in "${TARGETS[@]}"; do
        IFS='|' read -r MID _ _ <<< "$entry"
        ORG="$(echo "$MID" | cut -d/ -f1)"
        NAME="$(echo "$MID" | cut -d/ -f2)"
        EXPECTED["/data/work/models/$ORG/$NAME"]=1
    done

    while IFS= read -r -d '' model_dir; do
        if [[ -z "${EXPECTED[$model_dir]:-}" ]]; then
            ORPHAN_ID="$(cat "$model_dir/.model_id" 2>/dev/null || echo "unknown")"
            echo "  Removing orphaned model: $model_dir ($ORPHAN_ID)"
            rm -rf "$model_dir"
            ORPHANS=$((ORPHANS + 1))
        fi
    done < <(find /data/work/models -type f -name .model_id -printf '%h\0' 2>/dev/null || true)
fi

for entry in "${TARGETS[@]}"; do
    # Parse fields: MODEL_ID|REVISION|FORMAT
    IFS='|' read -r MODEL_ID REVISION FORMAT <<< "$entry"
    FORMAT="${FORMAT:-safetensors}"

    ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
    MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
    MODEL_DIR="/data/work/models/$ORG/$MODEL_NAME"

    echo ""
    echo "── $MODEL_ID ──"

    # ── Resolve allow_patterns from format ──
    case "$FORMAT" in
        safetensors|"-")
            ALLOW_PATTERNS=("${COMMON_PATTERNS[@]}" "${SAFETENSORS_PATTERNS[@]}")
            FORMAT_LABEL="safetensors"
            ;;
        gguf)
            ALLOW_PATTERNS=("${COMMON_PATTERNS[@]}" "${GGUF_PATTERNS[@]}")
            FORMAT_LABEL="gguf"
            ;;
        gguf:*)
            QUANT="${FORMAT#gguf:}"
            ALLOW_PATTERNS=("${COMMON_PATTERNS[@]}" "*${QUANT}*")
            FORMAT_LABEL="gguf:$QUANT"
            ;;
        full)
            ALLOW_PATTERNS=()
            FORMAT_LABEL="full"
            ;;
        *)
            # Custom glob patterns (space-separated)
            read -r -a ALLOW_PATTERNS <<< "$FORMAT"
            FORMAT_LABEL="custom"
            ;;
    esac

    # ── Skip if already downloaded ──
    if [[ -f "$MODEL_DIR/.revision" ]]; then
        CURRENT_REV="$(cat "$MODEL_DIR/.revision")"
        echo "  Already at $MODEL_DIR (revision: $CURRENT_REV)"
        if [[ "$CURRENT_REV" == "$REVISION" ]]; then
            echo "  Revision matches. Skipping."
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        echo "  Revision mismatch (wanted $REVISION). Cleaning and re-downloading..."
        rm -rf "$MODEL_DIR"
    fi

    echo "  Revision : $REVISION"
    echo "  Format   : $FORMAT_LABEL"
    echo "  Target   : $MODEL_DIR"

    mkdir -p "$MODEL_DIR"

    # ── Build Python filter arguments ──
    PY_FILTER=""
    if [[ "$FORMAT_LABEL" != "full" ]] && [[ ${#ALLOW_PATTERNS[@]} -gt 0 ]]; then
        PY_FILTER="allow_patterns=[$(printf "'%s'," "${ALLOW_PATTERNS[@]}")],"
    fi

    if python3 -c "
from huggingface_hub import snapshot_download
path = snapshot_download(
    '$MODEL_ID',
    revision='$REVISION',
    local_dir='$MODEL_DIR',
    $PY_FILTER
)
print(f'Downloaded to {path}')
"; then
        echo "$REVISION" > "$MODEL_DIR/.revision"
        echo "$MODEL_ID" > "$MODEL_DIR/.model_id"
        date -u +%Y-%m-%dT%H:%M:%SZ > "$MODEL_DIR/.downloaded_at"
        echo "  Done ($(du -sh "$MODEL_DIR" | cut -f1))"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "  ERROR: Download failed for $MODEL_ID" >&2
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=== Summary: $DOWNLOADED downloaded, $SKIPPED skipped, $ORPHANS removed, $FAILED failed ==="
