#!/bin/bash
# Open firewall ports for Unsloth Studio and Jupyter.
# Run as: pkexec bash nodes/unknownue-manjaro/config/open-unsloth-ports.sh
#
# iptables rules are ephemeral — re-run after reboot unless you
# persist them with iptables-save or enable the systemd service.

set -euo pipefail

PORTS=(8000 8888)

echo "Opening firewall ports for Unsloth Studio..."
for port in "${PORTS[@]}"; do
    if iptables -C INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        echo "  Port $port already open, skipping."
    else
        iptables -I INPUT 1 -p tcp -m tcp --dport "$port" -j ACCEPT
        echo "  Port $port opened."
    fi
done
echo "Done."

echo ""
echo "Current INPUT rules:"
iptables -L INPUT -n -v --line-numbers
