#!/bin/bash
# Stop and remove Unsloth Studio container.
set -euo pipefail

echo "Stopping Unsloth Studio..."

for cid in $(docker ps -a -q --filter "name=unsloth" 2>/dev/null); do
    echo "  Removing unsloth ($cid)..."
    docker rm -f "$cid" 2>/dev/null || true
done

echo "Stopped and removed."
