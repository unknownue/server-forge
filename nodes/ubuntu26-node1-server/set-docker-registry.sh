#!/bin/bash
# Configure Docker registry mirror in daemon.json.
# Usage:
#   sudo bash set-docker-registry.sh               # Show available options
#   sudo bash set-docker-registry.sh <registry-host>
#   e.g. sudo bash set-docker-registry.sh registry.cn-hangzhou.aliyuncs.com

set -euo pipefail

CONFIG="/etc/docker/daemon.json"

# Common registry mirrors (sourced from submodules/LinuxMirrors).
show_options() {
    echo "Available Docker registry mirrors:"
    echo ""
    echo "  Public proxies:"
    echo "    docker.1ms.run"
    echo "    dockerproxy.net"
    echo "    docker.m.daocloud.io"
    echo "    docker.1panel.live"
    echo ""
    echo "  Aliyun ACR:"
    echo "    registry.cn-hangzhou.aliyuncs.com"
    echo "    registry.cn-shanghai.aliyuncs.com"
    echo "    registry.cn-beijing.aliyuncs.com"
    echo "    registry.cn-guangzhou.aliyuncs.com"
    echo ""
    echo "  Tencent Cloud:"
    echo "    mirror.ccs.tencentyun.com"
    echo ""
    echo "Usage: sudo bash set-docker-registry.sh <host>"
}

if [[ "${1:-}" == "" ]]; then
    show_options
    exit 0
fi

REGISTRY="$1"
TMP="$(mktemp)"

if [[ ! -f "$CONFIG" ]]; then
    echo "{\"registry-mirrors\": [\"https://${REGISTRY}\"]}" > "$CONFIG"
else
    jq --arg r "https://${REGISTRY}" '.["registry-mirrors"] = [$r]' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
fi

systemctl restart docker

echo "Done. Registry mirror: https://${REGISTRY}"
docker info --format '{{json .RegistryConfig.Mirrors}}'
