#!/bin/bash
# Thin wrapper — delegates to the shared download script.
# Usage:
#   bash nodes/unknownue-manjaro/download-model.sh [MODEL_ID] [REV] [FORMAT]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/discover.sh"
exec bash "$REPO_ROOT/scripts/lib/download-model.sh" "$@"
