#!/bin/bash
# Stop the Service Hub web UI.
#
# This only stops the hub itself — containers it launched keep running. Use the
# UI's "Stop all" button (or POST /api/stop) to stop managed services.

set -euo pipefail

PORT="${1:-9090}"
# The bracket in "[s]ervice_hub" stops pgrep from matching its own command line,
# which would otherwise make this script report a stop that never happened.
PATTERN="uvicorn [s]ervice_hub.server:app.*--port $PORT"

pids="$(pgrep -f "$PATTERN" || true)"
if [[ -z "$pids" ]]; then
    echo "Service Hub is not running on port $PORT."
    exit 0
fi

echo "Stopping Service Hub (pid: $pids)…"
kill $pids 2>/dev/null || true

for _ in $(seq 1 10); do
    sleep 1
    if ! pgrep -f "$PATTERN" >/dev/null; then
        echo "Stopped."
        exit 0
    fi
done

echo "Still running; sending SIGKILL." >&2
pkill -9 -f "$PATTERN" || true
echo "Stopped."