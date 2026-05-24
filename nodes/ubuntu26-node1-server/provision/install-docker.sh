#!/bin/bash
# Install Docker with data-root and containerd root on /data partition.
# Run as: sudo bash install-docker.sh

set -euo pipefail

DOCKER_DATA_ROOT="/data/docker"
CONTAINERD_ROOT="/data/containerd"

echo "=== Installing Docker ==="
apt update
apt install -y docker.io

# ── Docker daemon config ──
mkdir -p "$DOCKER_DATA_ROOT"
mkdir -p /etc/docker

cat > /etc/docker/daemon.json << EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# ── Containerd config (independent from Docker daemon.json) ──
mkdir -p "$CONTAINERD_ROOT"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i "s|^root = .*|root = \"${CONTAINERD_ROOT}\"|" /etc/containerd/config.toml
echo "Containerd root: $(grep '^root = ' /etc/containerd/config.toml)"

# ── Restart both ──
systemctl restart containerd docker

if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER"
    echo "Added $SUDO_USER to docker group (re-login to take effect)."
fi

echo "Done. Docker data-root=${DOCKER_DATA_ROOT}, containerd root=${CONTAINERD_ROOT}"
