#!/bin/bash
# Stop the Caddy reverse proxy.
#
# Usage:
#   bash nodes/mac-mini-m4/caddy/stop.sh
#
# Removes the container and network membership. The multica-net network itself
# and the caddy volumes (certs/state) are left alone — the network belongs to
# the Multica stack, and `docker compose down` on this project must not touch
# resources another stack owns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Stopping Caddy..."
docker compose down

echo ""
echo "Caddy stopped. The multica-net network is untouched; the Multica stack"
echo "(and its LAN-unreachable frontend) is still running."