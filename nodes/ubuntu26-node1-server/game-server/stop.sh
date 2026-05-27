#!/bin/bash
echo "Stopping Game Studio Server..."
for cid in $(docker ps -q --filter "name=gs-"); do
    docker stop "$cid" 2>/dev/null || true
done
echo "All stopped."
