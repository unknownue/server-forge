#!/bin/bash
echo "Stopping Web Studio Server..."
for cid in $(docker ps -q --filter "name=ws-"); do
    docker stop "$cid" 2>/dev/null || true
done
echo "All stopped."
