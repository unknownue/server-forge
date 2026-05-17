#!/bin/bash
# Network bandwidth test using iperf3.
# Run server on one node, client on another.
# Requires: iperf3.

set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/utils.sh"

MODE="${1:-server}"
SERVER_IP="${2:-}"

case "$MODE" in
    server)
        log_info "Starting iperf3 server..."
        iperf3 -s
        ;;
    client)
        if [[ -z "$SERVER_IP" ]]; then
            die "Usage: $0 client <server-ip>"
        fi
        log_info "Running iperf3 client -> ${SERVER_IP}..."
        iperf3 -c "$SERVER_IP"
        ;;
    *)
        die "Usage: $0 {server|client <ip>}"
        ;;
esac
