#!/bin/bash
# Install the Service Hub desktop launcher (GNOME/Wayland).
#
# Usage:
#   bash nodes/ubuntu-server-node-2/service-hub/install-desktop.sh [--remove]
#
# Creates two files on the desktop:
#   service-hub.desktop — what to double-click (GNOME reliably honours this and
#                         marks it trusted; double-clicking a bare .sh commonly
#                         just opens a text editor instead)
#   service-hub.sh      — the actual launcher, also directly runnable
#
# The script is generated with this checkout's path baked in, so re-run this
# installer after moving the repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# XDG_DESKTOP_DIR is authoritative; fall back to ~/Desktop.
DESKTOP="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
if [[ -f "$HOME/.config/user-dirs.dirs" ]]; then
    # shellcheck disable=SC1090
    . "$HOME/.config/user-dirs.dirs"
    DESKTOP="${XDG_DESKTOP_DIR:-$DESKTOP}"
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [[ "${1:-}" == "--remove" ]]; then
    rm -f "$DESKTOP/service-hub.desktop" "$DESKTOP/service-hub.sh"
    log "Removed desktop launchers from $DESKTOP"
    exit 0
fi

if [[ ! -d "$DESKTOP" ]]; then
    echo "ERROR: desktop directory not found: $DESKTOP" >&2
    exit 1
fi

# ── Launcher script ──
# Rendered from the template so the repo path always matches this checkout.
install -m 0755 "$SCRIPT_DIR/desktop/service-hub.sh" "$DESKTOP/service-hub.sh"
sed -i "s|^REPO_DIR=.*|REPO_DIR=\"$(cd "$SCRIPT_DIR/../../.." && pwd)\"|" \
    "$DESKTOP/service-hub.sh"
log "Installed $DESKTOP/service-hub.sh"

# ── .desktop entry ──
install -m 0755 "$SCRIPT_DIR/desktop/service-hub.desktop" "$DESKTOP/service-hub.desktop"
sed -i "s|^Exec=.*|Exec=$DESKTOP/service-hub.sh|" "$DESKTOP/service-hub.desktop"
log "Installed $DESKTOP/service-hub.desktop"

# GNOME will not run a desktop file until it is marked trusted.
if command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP/service-hub.desktop" metadata::trusted true 2>/dev/null \
        && log "Marked trusted (GNOME)"
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$DESKTOP/service-hub.desktop" 2>&1 | grep -v '^$' || true
fi

echo ""
log "Done. Double-click 'Service Hub' on the desktop, or run:"
log "  bash $DESKTOP/service-hub.sh"
echo ""
log "Remove with: bash $SCRIPT_DIR/install-desktop.sh --remove"