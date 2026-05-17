#!/bin/bash
# Install Docker and write base daemon.json.
# Run as: sudo bash install-docker.sh

set -euo pipefail

DATA_ROOT="/data/docker"

echo "=== Installing Docker ==="
apt update
apt install -y docker.io

mkdir -p "$DATA_ROOT"
mkdir -p /etc/docker

cat > /etc/docker/daemon.json << EOF
{
  "data-root": "${DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

systemctl restart docker

if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER"
    echo "Added $SUDO_USER to docker group (re-login to take effect)."
fi

echo "Done. Docker installed: data-root=${DATA_ROOT}"
