#!/bin/bash
# Download datasets from HuggingFace to /data/work/datasets/.
# Dataset files are version-pinned for reproducibility.
#
# Usage:
#   bash scripts/lib/download-dataset.sh                            # download all registered datasets
#   bash scripts/lib/download-dataset.sh [DATASET_ID]               # download a specific dataset
#   bash scripts/lib/download-dataset.sh [DATASET_ID] [REV] [FORMAT]
#   bash scripts/lib/download-dataset.sh [DATASET_ID] [REV] files "[FILES]"
#
# Datasets are stored at /data/work/datasets/<dataset>/ with
# .dataset_id, .revision, .downloaded_at files for reproducibility.
#
# Format (3rd field, defaults to full):
#   full              — no filtering, download everything (default)
#   "-"               — explicit default (same as full)
#   <glob> ...        — custom allow_patterns (space-separated)
#   parquet           — only *.parquet + common configs
#   json              — only *.json + common configs
#   files             — download an explicit filename list via direct /resolve
#                       URLs (no repo-tree listing). Use for datasets with a
#                       huge file count where the /api tree pagination stalls.
#                       Filenames come from the 4th arg: space-separated, or
#                       @/path/to/filelist (one filename per line).

set -euo pipefail

# ── Discover current node ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$FORGE_REPO_ROOT/scripts/lib/discover.sh"

# ── Use project venv Python (has hf_xet for large file downloads) ──
VENV_PYTHON="$FORGE_REPO_ROOT/.venv/bin/python3"
if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "ERROR: Project venv not found at $FORGE_REPO_ROOT/.venv" >&2
    echo "Run: python3 -m venv $FORGE_REPO_ROOT/.venv && $FORGE_REPO_ROOT/.venv/bin/pip install huggingface_hub hf_xet" >&2
    exit 1
fi

# ── Load per-node dataset registry ──
DATASETS_CONF="$FORGE_NODE_DIR/config/datasets.conf"
if [[ ! -f "$DATASETS_CONF" ]]; then
    echo "ERROR: Dataset config not found: $DATASETS_CONF" >&2
    echo "Create it with a DATASETS array to register datasets for this node." >&2
    exit 1
fi
source "$DATASETS_CONF"

export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

# ── Base directory for datasets ──
DATASETS_BASE="/data/work/datasets"

# ── File patterns by format ──
COMMON_PATTERNS=(
    "README.md"
    "*.txt"
    "*.csv"
)

PARQUET_PATTERNS=(
    "*.parquet"
)

JSON_PATTERNS=(
    "*.json"
    "*.jsonl"
)

# ── Ensure huggingface_hub is available ──
if ! "$VENV_PYTHON" -c "import huggingface_hub" 2>/dev/null; then
    echo "ERROR: huggingface_hub not installed in project venv." >&2
    echo "Run: $FORGE_REPO_ROOT/.venv/bin/pip install huggingface_hub hf_xet" >&2
    exit 1
fi

# ── Resolve target list ──
if [[ $# -ge 1 ]]; then
    FORMAT="${3:-full}"
    FILES_ARG="${4:-}"
    TARGETS=("${1}|${2:-main}|${FORMAT}|${FILES_ARG}")
else
    TARGETS=("${DATASETS[@]}")
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
# Remove dataset directories that exist on disk but are not in the registry.
if $SYNC_MODE; then
    declare -A EXPECTED
    for entry in "${TARGETS[@]}"; do
        IFS='|' read -r DID _ _ <<< "$entry"
        DS_NAME="$(echo "$DID" | cut -d/ -f2)"
        EXPECTED["$DATASETS_BASE/$DS_NAME"]=1
    done

    while IFS= read -r -d '' ds_dir; do
        if [[ -z "${EXPECTED[$ds_dir]:-}" ]]; then
            ORPHAN_ID="$(cat "$ds_dir/.dataset_id" 2>/dev/null || echo "unknown")"
            echo "  Removing orphaned dataset: $ds_dir ($ORPHAN_ID)"
            rm -rf "$ds_dir"
            ORPHANS=$((ORPHANS + 1))
        fi
    done < <(find "$DATASETS_BASE" -type f -name .dataset_id -printf '%h\0' 2>/dev/null || true)
fi

for entry in "${TARGETS[@]}"; do
    # Parse fields: DATASET_ID|REVISION|FORMAT|FILES
    IFS='|' read -r DATASET_ID REVISION FORMAT FILES_ARG <<< "$entry"
    FORMAT="${FORMAT:-full}"

    DS_NAME="$(echo "$DATASET_ID" | cut -d/ -f2)"
    DS_DIR="$DATASETS_BASE/$DS_NAME"

    echo ""
    echo "── $DATASET_ID ──"

    # ── Resolve allow_patterns from format ──
    case "$FORMAT" in
        full|"-")
            ALLOW_PATTERNS=()
            FORMAT_LABEL="full"
            ;;
        parquet)
            ALLOW_PATTERNS=("${COMMON_PATTERNS[@]}" "${PARQUET_PATTERNS[@]}")
            FORMAT_LABEL="parquet"
            ;;
        json)
            ALLOW_PATTERNS=("${COMMON_PATTERNS[@]}" "${JSON_PATTERNS[@]}")
            FORMAT_LABEL="json"
            ;;
        files)
            FORMAT_LABEL="files"
            ;;
        *)
            # Custom glob patterns (space-separated)
            read -r -a ALLOW_PATTERNS <<< "$FORMAT"
            FORMAT_LABEL="custom"
            ;;
    esac

    # ── files format: expand the explicit filename list (no tree listing) ──
    FILES_LIST=""
    if [[ "$FORMAT_LABEL" == "files" ]]; then
        if [[ -z "${FILES_ARG:-}" ]]; then
            echo "ERROR: 'files' format requires a 4th argument: space-separated filenames or @file" >&2
            exit 1
        fi
        if [[ "$FILES_ARG" == @* ]]; then
            # one filename per line; skip blank / whitespace-only lines
            mapfile -t FILE_NAMES < <(grep -vE '^[[:space:]]*$' "${FILES_ARG#@}" || true)
        else
            read -r -a FILE_NAMES <<< "$FILES_ARG"
        fi
        if [[ ${#FILE_NAMES[@]} -eq 0 ]]; then
            echo "ERROR: 'files' format got an empty filename list" >&2
            exit 1
        fi
        FILES_LIST="[$(printf "'%s'," "${FILE_NAMES[@]}")]"
    fi

    # ── Skip if already downloaded ──
    if [[ -f "$DS_DIR/.revision" ]]; then
        CURRENT_REV="$(cat "$DS_DIR/.revision")"
        echo "  Already at $DS_DIR (revision: $CURRENT_REV)"
        if [[ "$CURRENT_REV" == "$REVISION" ]]; then
            echo "  Revision matches. Skipping."
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        echo "  Revision mismatch (wanted $REVISION). Cleaning and re-downloading..."
        rm -rf "$DS_DIR"
    fi

    echo "  Revision : $REVISION"
    echo "  Format   : $FORMAT_LABEL"
    echo "  Target   : $DS_DIR"

    mkdir -p "$DS_DIR"

    # ── Build Python filter arguments ──
    PY_FILTER=""
    if [[ "$FORMAT_LABEL" != "full" ]] && [[ ${#ALLOW_PATTERNS[@]} -gt 0 ]]; then
        PY_FILTER="allow_patterns=[$(printf "'%s'," "${ALLOW_PATTERNS[@]}")],"
    fi

    if "$VENV_PYTHON" -c "
from huggingface_hub import snapshot_download, hf_hub_download, constants

# Disable Xet: mirrors (hf-mirror.com) issue tokens that the Xet CAS
# server (cas-server.xethub.hf.co) rejects with 401.
constants.HF_HUB_DISABLE_XET = True

if '$FORMAT_LABEL' == 'files':
    # Explicit filename list: download each file directly via /resolve URLs,
    # avoiding snapshot_download's full repo-tree listing (which can stall on
    # the /api tree endpoint for datasets with thousands of files).
    for fn in $FILES_LIST:
        print(f'Downloading {fn}...', flush=True)
        hf_hub_download(
            '$DATASET_ID',
            filename=fn,
            revision='$REVISION',
            repo_type='dataset',
            local_dir='$DS_DIR',
        )
else:
    path = snapshot_download(
        '$DATASET_ID',
        revision='$REVISION',
        local_dir='$DS_DIR',
        repo_type='dataset',
        $PY_FILTER
    )
    print(f'Downloaded to {path}')
"; then
        echo "$REVISION" > "$DS_DIR/.revision"
        echo "$DATASET_ID" > "$DS_DIR/.dataset_id"
        date -u +%Y-%m-%dT%H:%M:%SZ > "$DS_DIR/.downloaded_at"
        echo "  Done ($(du -sh "$DS_DIR" | cut -f1))"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "  ERROR: Download failed for $DATASET_ID" >&2
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=== Summary: $DOWNLOADED downloaded, $SKIPPED skipped, $ORPHANS removed, $FAILED failed ==="
