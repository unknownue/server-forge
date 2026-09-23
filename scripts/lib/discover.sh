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

# A node directory may be named differently from the machine's reported
# hostname (e.g. macOS reports an mDNS name like `<host>.local` while the
# directory uses a short, human-chosen name). An alias file at
# nodes/<dirname>/.hostname records the hostname that maps to that directory:
#   nodes/mac-mini-m4/.hostname  ->  unknownue-servers-Mac-mini.local
# Resolve the alias when the direct hostname match does not exist.
if [[ ! -d "$FORGE_NODE_DIR" ]]; then
    for alias_file in "${FORGE_REPO_ROOT}"/nodes/*/.hostname; do
        [[ -f "$alias_file" ]] || continue
        if [[ "$(head -n1 "$alias_file" | tr -d '[:space:]')" == "$FORGE_NODE_HOSTNAME" ]]; then
            FORGE_NODE_DIR="$(dirname "$alias_file")"
            echo "[discover] Hostname '${FORGE_NODE_HOSTNAME}' aliased to node directory: ${FORGE_NODE_DIR}"
            break
        fi
    done
fi

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
