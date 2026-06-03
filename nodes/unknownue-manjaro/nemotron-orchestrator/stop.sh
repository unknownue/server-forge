#!/bin/bash
# Stop and remove the Nemotron-Orchestrator vLLM container.
set -euo pipefail

CONTAINER_NAME="nemotron-orchestrator"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "Stopping and removing container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
    echo "Done."
else
    echo "Container '$CONTAINER_NAME' is not running."
fi
