#!/bin/bash
# Configure Docker registry mirrors in /etc/docker/daemon.json, preserving
# existing keys (data-root, log-driver, ...).
#
# Why this needs root: /etc/docker/daemon.json is root-owned, and applying it
# requires restarting the system-wide dockerd. Everything else in this node's
# workflow runs as the regular user (the account is in the `docker` group), so
# this is the ONE remaining privileged step.
#
# Usage:
#   sudo bash config/set-docker-registry.sh              # use the verified default set
#   sudo bash config/set-docker-registry.sh a b c        # explicit mirror hosts
#
# Note on scope: with the root daemon, registry mirrors are the convenient way
# to reach Docker Hub through a proxy. Alternatively you can keep the daemon
# unconfigured and name the mirror explicitly on each pull
# (`docker pull docker.m.daocloud.io/library/<image>`), which needs no root at
# all — see the Mirror notes in the node README.

set -euo pipefail

CONFIG="/etc/docker/daemon.json"

# Verified reachable from this network (401 on /v2/ is the expected response for
# a token-auth proxy). Ordered: daocloud measured fastest for large blobs here.
DEFAULT_MIRRORS=(
    docker.m.daocloud.io
    docker.1ms.run
    docker.xuanyuan.me
)

usage() {
    cat <<EOF
Configure Docker registry mirrors.

  sudo bash $0                # use the verified default set:
                              #   ${DEFAULT_MIRRORS[*]}
  sudo bash $0 host [host...] # explicit list, in priority order

Current state:
  config file : ${CONFIG}
  mirrors     : $(docker info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || echo n/a)

To revert, restore the .bak file this script leaves behind and restart docker.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: must run as root (writes ${CONFIG} and restarts dockerd)." >&2
    echo "  sudo bash $0 ${*:-}" >&2
    exit 1
fi

if [[ $# -gt 0 ]]; then
    MIRRORS=("$@")
else
    MIRRORS=("${DEFAULT_MIRRORS[@]}")
fi

# ── Reachability check (warn only; it is a mirror, not the source of truth) ──
echo "=== Checking mirror reachability ==="
for m in "${MIRRORS[@]}"; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://${m}/v2/" || echo 000)"
    case "$code" in
        200|401) echo "  OK    ${m} (${code})" ;;
        000)     echo "  UNREACHABLE ${m}" >&2 ;;
        *)       echo "  odd   ${m} (${code})" ;;
    esac
done

mkdir -p /etc/docker

# jq keeps this robust against future keys; fall back to python3 if absent.
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found; using python3 to merge JSON."
    MERGE_TOOL=python3
else
    MERGE_TOOL=jq
fi

# Build the JSON array of mirror URLs.
URLS_JSON="$(printf 'https://%s\n' "${MIRRORS[@]}" | \
    if [[ "$MERGE_TOOL" == jq ]]; then jq -R . | jq -s .; else python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'; fi)"

if [[ ! -f "$CONFIG" ]]; then
    printf '{"registry-mirrors": %s}\n' "$URLS_JSON" > "$CONFIG"
else
    BAK="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG" "$BAK"
    echo "Backup: $BAK"
    TMP="$(mktemp)"
    if [[ "$MERGE_TOOL" == jq ]]; then
        jq --argjson urls "$URLS_JSON" '.["registry-mirrors"] = $urls' "$CONFIG" > "$TMP"
    else
        python3 - "$CONFIG" "$TMP" "$URLS_JSON" <<'PY'
import json, sys
cfg, out, urls = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
d = json.load(open(cfg))
d["registry-mirrors"] = urls
json.dump(d, open(out, "w"), indent=2)
PY
    fi
    mv "$TMP" "$CONFIG"
fi

echo ""
echo "=== ${CONFIG} ==="
cat "$CONFIG"

echo ""
echo "=== Restarting Docker ==="
systemctl restart docker
sleep 2
systemctl is-active docker

echo ""
echo "=== Active mirrors ==="
docker info --format '{{json .RegistryConfig.Mirrors}}'

echo ""
echo "Done. Pulls of unqualified images (e.g. 'docker pull rocm/pytorch') will"
echo "now be tried through these mirrors. To revert: restore the .bak above and"
echo "restart docker."