#!/bin/bash
# Download the Multica CLI release asset, from whichever source this network
# can actually reach.
#
# Why this is a script and not inline in the Dockerfile:
#   The source-selection logic needs an awk program, and a multi-line awk body
#   inside a `RUN` breaks Docker's line-continuation parser — it treats the
#   awk lines as Dockerfile instructions ("unknown instruction: match($0,").
#   Keeping it here also makes it runnable on its own when debugging a build.
#
# Sources, in order:
#   1. GH_PROXY + the normal release URL — a mirror, for restricted networks
#   2. the Assets API — works when api.github.com is reachable but github.com
#      is not, which is the case on the machine this was authored on
#   3. the release URL directly — for unrestricted networks
#
# Usage: fetch-cli.sh <version-tag> <arch> <dest.tar.gz> [proxy-prefix]

set -euo pipefail

VERSION="${1:?usage: fetch-cli.sh <version-tag> <arch> <dest> [proxy]}"
ARCH="${2:?arch required, e.g. arm64 or amd64}"
DEST="${3:?destination path required}"
GH_PROXY="${4:-}"

ver="${VERSION#v}"
asset="multica-cli-${ver}-linux-${ARCH}.tar.gz"
base="https://github.com/multica-ai/multica/releases/download/${VERSION}"
api="https://api.github.com/repos/multica-ai/multica/releases/tags/${VERSION}"

log() { echo "[fetch-cli] $*" >&2; }

# A curl that "succeeded" but produced something that is not a tarball is the
# failure mode worth guarding: downloading the wrong asset yields a 1 KB text
# file (`checksums.txt`) and only fails later at `tar -xzf`, with an error that
# points at gzip rather than at the real cause.
looks_like_tarball() {
    [ -s "$DEST" ] && gzip -t "$DEST" 2>/dev/null
}

# ── 1. mirror ───────────────────────────────────────────────────────────────
if [ -n "$GH_PROXY" ]; then
    log "trying mirror: ${GH_PROXY}${base}/${asset}"
    if curl -fsSL --retry 2 --connect-timeout 15 "${GH_PROXY}${base}/${asset}" -o "$DEST" \
        && looks_like_tarball; then
        log "ok (mirror)"
        exit 0
    fi
    log "mirror attempt failed"
fi

# ── 2. Assets API ───────────────────────────────────────────────────────────
# Resolve the asset id by NAME, not by position. The release lists ~38 assets
# with checksums.txt first, so "the first url field" is the wrong answer.
log "resolving asset id via ${api}"
asset_id="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$api" 2>/dev/null \
    | awk -v want="$asset" '
        # The id appears ~160 bytes before the name, so a fixed look-back
        # window is fragile; remember the last id seen and emit it when the
        # wanted name goes past. "releases/assets/" is 16 characters.
        match($0, /releases\/assets\/[0-9]+/) { id = substr($0, RSTART + 16, RLENGTH - 16) }
        index($0, "\"name\": \"" want "\"") { print id; exit }
    ' || true)"

if [ -n "${asset_id:-}" ]; then
    log "asset id for ${asset}: ${asset_id}"
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
            -H "Accept: application/octet-stream" \
            "https://api.github.com/repos/multica-ai/multica/releases/assets/${asset_id}" \
            -o "$DEST" \
        && looks_like_tarball; then
        log "ok (assets API)"
        exit 0
    fi
    log "assets API download failed or returned a non-tarball"
else
    log "could not resolve an asset id for ${asset}"
fi

# ── 3. direct release URL ───────────────────────────────────────────────────
log "trying direct: ${base}/${asset}"
if curl -fsSL --retry 2 --connect-timeout 15 "${base}/${asset}" -o "$DEST" \
    && looks_like_tarball; then
    log "ok (direct)"
    exit 0
fi

cat >&2 <<EOF
[fetch-cli] ERROR: could not download ${asset} from any source.

  This network reaches neither github.com nor a usable mirror. Options:
    - set GH_PROXY to a mirror prefix in .env (see .env.example)
    - download the asset elsewhere and copy it into the build context
      (see the LOCAL_CLI section of the Dockerfile)
EOF
exit 1