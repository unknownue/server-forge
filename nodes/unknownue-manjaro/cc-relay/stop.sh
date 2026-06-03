#!/bin/bash
# Stop and remove cc-relay container.
set -euo pipefail

echo "Stopping cc-relay..."

for cid in $(docker ps -a -q --filter "name=cc-relay" 2>/dev/null); do
    echo "  Removing cc-relay ($cid)..."
    docker rm -f "$cid" 2>/dev/null || true
done

echo "cc-relay stopped and removed."
