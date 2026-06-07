#!/bin/bash
# Stop the Service Hub.
#
# Usage:
#   bash nodes/ubuntu26-node1-server/service-hub/stop.sh

set -euo pipefail

echo "Stopping Service Hub..."

PIDS=$(pgrep -f "uvicorn service_hub.server" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    echo "Killing uvicorn processes: $PIDS"
    kill $PIDS 2>/dev/null || true
    sleep 1
fi

echo "Service Hub stopped."
