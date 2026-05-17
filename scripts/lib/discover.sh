#!/bin/bash
# Machine discovery: detect which node this machine is and export environment variables.
# Usage: source scripts/lib/discover.sh
#
# Exports:
#   FORGE_NODE_HOSTNAME   - hostname of this machine
#   FORGE_NODE_DIR        - absolute path to nodes/<hostname>/
#   FORGE_REPO_ROOT       - absolute path to server-forge repo root

set -euo pipefail

# Determine repo root (parent of the scripts/ directory).
FORGE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Detect hostname.
FORGE_NODE_HOSTNAME="$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "")"
if [[ -z "$FORGE_NODE_HOSTNAME" ]]; then
    echo "[discover] ERROR: Cannot determine hostname." >&2
    return 1 2>/dev/null || exit 1
fi

FORGE_NODE_DIR="${FORGE_REPO_ROOT}/nodes/${FORGE_NODE_HOSTNAME}"

if [[ -d "$FORGE_NODE_DIR" ]]; then
    echo "[discover] Found node directory: ${FORGE_NODE_DIR}"
    export FORGE_NODE_HOSTNAME FORGE_NODE_DIR FORGE_REPO_ROOT
    return 0 2>/dev/null || exit 0
fi

# Node directory not found.
echo "[discover] Node directory not found: ${FORGE_NODE_DIR}" >&2
echo "[discover] To create a new node configuration, copy an existing similar node:" >&2
echo "  cp -r ${FORGE_REPO_ROOT}/nodes/<existing-node> ${FORGE_NODE_DIR}" >&2
echo "  # edit ${FORGE_NODE_DIR}/README.md and run hardware-info.sh" >&2
echo "" >&2

export FORGE_NODE_HOSTNAME FORGE_NODE_DIR FORGE_REPO_ROOT
return 1 2>/dev/null || exit 1
