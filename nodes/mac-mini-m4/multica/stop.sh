#!/bin/bash
# Stop the Multica self-host stack.
#
# Usage:
#   bash nodes/mac-mini-m4/multica/stop.sh
#
# Containers and the network are removed; the named volumes are NOT. That is
# deliberate: pgdata and backend_uploads hold the database and uploaded files,
# and this project's convention is that data is rebuildable from configuration
# but should not be discarded as a side effect of stopping a service.
#
# To also destroy the data (irreversible — you lose all issues, accounts and
# uploads), run explicitly:
#   docker compose -f <this dir>/docker-compose.yml down -v

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f .env ]]; then
    echo "ERROR: .env not found in ${SCRIPT_DIR}. Nothing to stop." >&2
    exit 1
fi

echo "Stopping Multica..."
docker compose down

echo ""
echo "Stopped. Volumes preserved:"
docker volume ls --filter "name=multica_" --format '  {{.Name}}'
echo ""
echo "Note: the caddy container (../caddy) may still be running and will now"
echo "      fail to reach its upstream. Stop it with ../caddy/stop.sh."