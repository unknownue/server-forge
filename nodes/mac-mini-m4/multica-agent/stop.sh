#!/bin/bash
# Stop the Multica agent runtime.
#
# Usage:
#   bash stop.sh
#
# Containers are removed; the dsh and multica state volumes are kept, so a
# restart does not require re-authenticating or rebuilding the DSH profile.
#
# To also destroy that state (the runtime re-provisions the DSH profile from
# the image on next start, but the stored PAT is lost):
#   docker compose down -v

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Stopping the Multica agent runtime..."
docker compose down

echo ""
echo "Stopped. State volumes preserved:"
docker volume ls --filter "name=multica-agent-" --format '  {{.Name}}'
echo ""
echo "The runtime will show as offline in the web UI within about 3 minutes."