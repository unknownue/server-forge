#!/bin/bash
# Stop and remove Web Studio Server containers.
set -euo pipefail

echo "Stopping Web Studio Server..."

for cid in $(docker ps -a -q --filter "name=ws-" 2>/dev/null); do
    echo "  Removing $cid..."
    docker rm -f "$cid" 2>/dev/null || true
done

echo "All stopped and removed."
