#!/bin/bash
# Configure Docker registry mirrors for Docker Desktop on macOS.
#
# Why this node needs a mirror: registry-1.docker.io is unreachable from this
# network. Measured here, `docker manifest inspect caddy:2-alpine` fails with
# `Get "https://auth.docker.io/token?...": EOF` — the token endpoint never
# completes, so every Docker Hub pull hangs or dies. The mirror hosts answer
# normally (401 on /v2/ is the expected response for a token-auth proxy).
#
# Scope — read this before assuming GHCR is covered:
#   registry-mirrors ONLY proxies Docker Hub (docker.io / library/*).
#   It does NOT proxy ghcr.io. The Multica images are pulled through a
#   prefix-rewrite in nodes/mac-mini-m4/multica/deploy.sh instead.
#   The two mechanisms are independent and both are required.
#
# Unlike the Linux nodes, this writes no root-owned file: Docker Desktop keeps
# its daemon configuration in ~/.docker/daemon.json and applies it from the
# app, so no sudo is involved. The trade-off is that the daemon cannot be
# restarted from the CLI — Docker Desktop must be restarted for the change to
# take effect, which this script asks for rather than doing silently.
#
# Usage:
#   bash nodes/mac-mini-m4/config/set-docker-mirror.sh              # verified defaults
#   bash nodes/mac-mini-m4/config/set-docker-mirror.sh host [host..] # explicit, priority order

set -euo pipefail

CONFIG="${HOME}/.docker/daemon.json"

# Verified reachable from this network (401 on /v2/ is the expected response for
# a token-auth proxy). Ordered: 1ms measured fastest here for large blobs.
DEFAULT_MIRRORS=(
    docker.1ms.run
    docker.m.daocloud.io
)

usage() {
    cat <<EOF
Configure Docker Desktop registry mirrors (Docker Hub only — not ghcr.io).

  bash $0                # use the verified default set:
                         #   ${DEFAULT_MIRRORS[*]}
  bash $0 host [host...] # explicit list, in priority order

Current state:
  config file : ${CONFIG}
  mirrors     : $(docker info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || echo n/a)

Notes:
  - Docker Desktop must be RESTARTED for changes to take effect.
  - This does not affect ghcr.io; see this script's header.
  - To revert, restore the .bak file this script leaves behind and restart.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

if [[ $# -gt 0 ]]; then
    MIRRORS=("$@")
else
    MIRRORS=("${DEFAULT_MIRRORS[@]}")
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required to merge ${CONFIG} without dropping other keys." >&2
    echo "  brew install jq" >&2
    exit 1
fi

# ── Reachability check (warn only; a mirror is an optimization, not the source
#    of truth, so one unreachable host must not abort the whole run) ──
echo "=== Checking mirror reachability ==="
reachable=()
for host in "${MIRRORS[@]}"; do
    # Any HTTP status counts as reachable — 401 is the normal token-auth answer.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${host}/v2/" || echo "000")
    if [[ "$code" == "000" ]]; then
        echo "  [WARN]  ${host} — no response"
    else
        echo "  [ OK ]  ${host} — HTTP ${code}"
        reachable+=("$host")
    fi
done

if [[ ${#reachable[@]} -eq 0 ]]; then
    echo "ERROR: none of the given mirrors responded. Not writing a config that" >&2
    echo "       would leave the daemon without a working registry path." >&2
    exit 1
fi

# ── Build the JSON array ──
URLS_JSON=$(printf '%s\n' "${reachable[@]}" | jq -R '"https://" + .' | jq -s .)

# ── Back up, then merge (preserving every unrelated key) ──
mkdir -p "$(dirname "$CONFIG")"
if [[ -f "$CONFIG" ]]; then
    BAK="${CONFIG}.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$CONFIG" "$BAK"
    echo "Backed up ${CONFIG} -> ${BAK}"
    TMP="$(mktemp)"
    jq --argjson urls "$URLS_JSON" '.["registry-mirrors"] = $urls' "$CONFIG" > "$TMP"
    mv "$TMP" "$CONFIG"
else
    jq -n --argjson urls "$URLS_JSON" '{"registry-mirrors": $urls}' > "$CONFIG"
fi

echo ""
echo "=== Wrote ${CONFIG} ==="
cat "$CONFIG"
echo ""
echo "Restart Docker Desktop to apply:"
echo "  osascript -e 'quit app \"Docker\"' && sleep 3 && open -a Docker"
echo ""
echo "Then verify:"
echo "  docker info --format '{{json .RegistryConfig.Mirrors}}'"