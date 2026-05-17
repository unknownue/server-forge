#!/bin/bash
# Download LLM model from HuggingFace to /data/work/models/.
# Model files are version-pinned for reproducibility.
#
# Usage:
#   bash benchmark/llm/download-model.sh [MODEL_ID] [REVISION]
#
# Default: Qwen/Qwen3.6-27B (dense)
#
# Models are stored at /data/work/models/<org>/<model>/ with a
# .revision file recording the exact commit for reproducibility.

set -euo pipefail

export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

MODEL_ID="${1:-Qwen/Qwen3.6-27B}"
REVISION="${2:-main}"

ORG="$(echo "$MODEL_ID" | cut -d/ -f1)"
MODEL_NAME="$(echo "$MODEL_ID" | cut -d/ -f2)"
MODEL_DIR="/data/work/models/$ORG/$MODEL_NAME"

# ── Ensure huggingface_hub is available ──
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "ERROR: huggingface_hub not installed." >&2
    echo "Run: sudo bash nodes/ubuntu26-node1-server/install-packages.sh" >&2
    exit 1
fi

# ── Skip if already downloaded ──
if [[ -f "$MODEL_DIR/.revision" ]]; then
    CURRENT_REV="$(cat "$MODEL_DIR/.revision")"
    echo "Model already downloaded at $MODEL_DIR (revision: $CURRENT_REV)"
    if [[ "$CURRENT_REV" == "$REVISION" ]]; then
        echo "Revision matches. Skipping download."
        exit 0
    fi
    echo "Revision mismatch (wanted $REVISION). Re-downloading..."
fi

# ── Show mirror config ──
if [[ -n "${HF_ENDPOINT:-}" ]]; then
    echo "HF_ENDPOINT: $HF_ENDPOINT"
fi

echo "=== Downloading $MODEL_ID ==="
echo "  Revision : $REVISION"
echo "  Target   : $MODEL_DIR"
echo ""

mkdir -p "$MODEL_DIR"

python3 -c "
from huggingface_hub import snapshot_download
path = snapshot_download(
    '$MODEL_ID',
    revision='$REVISION',
    local_dir='$MODEL_DIR',
)
print(f'Downloaded to {path}')
"

# ── Record revision for reproducibility ──
echo "$REVISION" > "$MODEL_DIR/.revision"
echo "$MODEL_ID" > "$MODEL_DIR/.model_id"
date -u +%Y-%m-%dT%H:%M:%SZ > "$MODEL_DIR/.downloaded_at"

echo ""
echo "=== Done ==="
echo "Model : $MODEL_ID"
echo "Path  : $MODEL_DIR"
du -sh "$MODEL_DIR"
