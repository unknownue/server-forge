#!/bin/bash
# Stop and remove DeepSeek-V4-Flash vLLM server and CLASP proxy containers.
set -euo pipefail

echo "Stopping DeepSeek-V4-Flash Server..."

# vLLM inference server
for cid in $(docker ps -a -q --filter "name=dsv4-flash" 2>/dev/null); do
    echo "  Removing dsv4-flash ($cid)..."
    docker rm -f "$cid" 2>/dev/null || true
done

# CLASP proxy (if deployed alongside)
for cid in $(docker ps -a -q --filter "name=dsv4-clasp" 2>/dev/null); do
    echo "  Removing dsv4-clasp ($cid)..."
    docker rm -f "$cid" 2>/dev/null || true
done

echo "All stopped and removed."
