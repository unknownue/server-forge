#!/bin/bash
# Install Docker with data-root and containerd root on the /data subvolume.
# Run as: sudo bash nodes/ubuntu-server-node-2/provision/install-docker.sh [registry-mirror]
#
# Prerequisite: /data must exist — run allocate-storage.sh first.

set -euo pipefail

DOCKER_DATA_ROOT="/data/docker"
CONTAINERD_ROOT="/data/containerd"
REGISTRY="${1:-}"

if ! mountpoint -q /data; then
    echo "ERROR: /data is not mounted." >&2
    echo "Run first: sudo bash nodes/ubuntu-server-node-2/provision/allocate-storage.sh" >&2
    exit 1
fi

echo "=== Installing Docker ==="
apt update
apt install -y docker.io

# ── Docker daemon config ──
mkdir -p "$DOCKER_DATA_ROOT"
mkdir -p /etc/docker

if [[ -n "$REGISTRY" ]]; then
    cat > /etc/docker/daemon.json << EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "registry-mirrors": ["https://${REGISTRY}"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    echo "Registry mirror: https://${REGISTRY}"
else
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
fi

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
    # AMD GPU access needs these groups too; ROCm containers mount /dev/kfd and /dev/dri.
    for grp in render video; do
        if getent group "$grp" >/dev/null; then
            usermod -aG "$grp" "$SUDO_USER"
        fi
    done
    echo "Added $SUDO_USER to docker, render, video groups (re-login to take effect)."
fi

echo "Done. Docker data-root=${DOCKER_DATA_ROOT}, containerd root=${CONTAINERD_ROOT}"