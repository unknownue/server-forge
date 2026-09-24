#!/bin/bash
# Put the dsh Web GUI into permanent LAN mode — mac-mini-m4.
#
# Usage:
#   bash nodes/mac-mini-m4/config/install-dsh-lan.sh
#
# Copies the tracked profile patch layer into the dsh web profile, so that a
# plain `dsh web` (no flags, no wrapper) already binds all interfaces. Run once
# per machine; re-run after editing the tracked patch.
#
# Tracking vs. live copies — the same split this repo uses everywhere else:
#   tracked : nodes/mac-mini-m4/config/dsh-web-lan.patch.yml
#   live    : $DSH_HOME/profiles/web/cordis.patch.yml
# The live copy is the file dsh actually reads. It is NOT version-controlled
# (~/.dsh is user state), so this script is what makes the setting reproducible:
# the machine's LAN posture lives in git and is re-applied by running this.
#
# A timestamped backup of the previous live file is kept beside it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PATCH="${SCRIPT_DIR}/dsh-web-lan.patch.yml"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
PROFILE_DIR="${DSH_HOME_DIR}/profiles/web"
LIVE_PATCH="${PROFILE_DIR}/cordis.patch.yml"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [[ ! -f "$SOURCE_PATCH" ]]; then
    echo "ERROR: tracked patch not found: ${SOURCE_PATCH}" >&2
    exit 1
fi

# The profile is created on first `dsh web` run; without it there is nowhere to
# install the patch, and a silent "success" would be misleading.
if [[ ! -d "$PROFILE_DIR" ]]; then
    echo "ERROR: dsh web profile not found at ${PROFILE_DIR}" >&2
    echo "       Run 'dsh web' once to create it, then re-run this script." >&2
    exit 1
fi

# ── Back up the current live layer ──────────────────────────────────────────
if [[ -f "$LIVE_PATCH" ]]; then
    BACKUP="${LIVE_PATCH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$LIVE_PATCH" "$BACKUP"
    log "backed up existing layer -> ${BACKUP}"
else
    log "no existing cordis.patch.yml; creating one"
fi

# ── Install ─────────────────────────────────────────────────────────────────
cp "$SOURCE_PATCH" "$LIVE_PATCH"
log "installed -> ${LIVE_PATCH}"

# ── Validate against the real composer, before claiming success ─────────────
# `--dump-config` runs the actual loader composition (including the `!!js`
# expressions), so a schema or syntax mistake surfaces here rather than as a
# broken GUI on the next start. This is the check that catches the trap this
# patch is built around: a patch replaces the row's whole config, so a missing
# required key fails the load.
LAUNCHER=""
for candidate in \
    "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" \
    "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"; do
    [[ -f "$candidate" ]] && { LAUNCHER="$candidate"; break; }
done

if [[ -z "$LAUNCHER" ]]; then
    echo "" >&2
    echo "WARN: could not locate dsh to validate the composed config." >&2
    echo "      The patch is installed but was NOT verified. Check by running:" >&2
    echo "        dsh web --dump-config | grep -A6 'id: webserver'" >&2
    exit 1
fi

DUMP="$(node "$LAUNCHER" web --dump-config 2>&1 || true)"
if ! grep -q "^    host: 0.0.0.0$" <<<"$DUMP"; then
    echo "" >&2
    echo "ERROR: the composed config does not show host 0.0.0.0 — the patch did not take." >&2
    echo "       Composed webserver row was:" >&2
    grep -A 8 "id: webserver" <<<"$DUMP" >&2 || echo "       (webserver row not found)" >&2
    exit 1
fi
log "validated: composed config resolves the webserver row to 0.0.0.0"

cat <<EOF

=== dsh Web GUI: permanent LAN mode installed ===
  Live layer : ${LIVE_PATCH}
  Tracked    : nodes/mac-mini-m4/config/dsh-web-lan.patch.yml

Start (or restart) the GUI — no special flags needed:
  dsh web

dsh prints a tokenised URL whose LAN form other machines can open:
  http://<this-host-ip>:3080/?token=...

Notes:
  - The default port is 3080; override per run with: dsh web --port 13080
  - Restarting is required for the change to take effect.
  - To revert: restore the newest .bak.* beside the live layer, or delete it.
  - SECURITY: this exposes the /api endpoint and the shell tool behind it to
    the whole subnet over plain HTTP. Trusted networks only.
EOF