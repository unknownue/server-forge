#!/bin/bash
# Install the Service Hub as a systemd **user** service.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/service-hub/install-service.sh          # install + start
#   bash nodes/ubuntu-server-node-2/service-hub/install-service.sh --remove # uninstall
#
# The unit is a user service (not system) because the hub needs no privileges:
# it shells out to docker via the user's `docker` group membership and reads
# sysfs. It also needs `%h` expansion and the user's PATH, both of which are
# simpler in the user manager.
#
# NOTE: `enable` only starts the service at login. To keep it running with no
# session (i.e. survive logout / reboot-then-no-login), lingering must be on:
#     sudo loginctl enable-linger $USER
# That command needs root, so it is reported here rather than run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_NAME="service-hub.service"
UNIT_SRC="$SCRIPT_DIR/systemd/$UNIT_NAME"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_DST="$UNIT_DIR/$UNIT_NAME"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [[ "${1:-}" == "--remove" ]]; then
    log "Stopping and removing $UNIT_NAME…"
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT_DST"
    systemctl --user daemon-reload
    log "Removed. (Containers the hub launched are left running.)"
    exit 0
fi

if [[ ! -f "$UNIT_SRC" ]]; then
    echo "ERROR: unit file not found: $UNIT_SRC" >&2
    exit 1
fi

# Ensure the frontend is built before the service starts, so the first UI load
# is not a blank "frontend not built" page.
if [[ ! -f "$SCRIPT_DIR/static/index.html" ]]; then
    log "Frontend not built — building it first…"
    ( cd "$SCRIPT_DIR/frontend" && { [[ -d node_modules ]] || npm install; } && npm run build )
fi

mkdir -p "$UNIT_DIR"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
log "Installed $UNIT_DST"

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME"
log "Enabled and started."

sleep 5
echo ""
systemctl --user status "$UNIT_NAME" --no-pager 2>&1 | head -8

echo ""
if [[ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" != "yes" ]]; then
    echo "──────────────────────────────────────────────────────────────"
    echo "Lingering is OFF. The hub will stop when you log out."
    echo "To keep it running with no active session, run (needs root):"
    echo ""
    echo "    sudo loginctl enable-linger $USER"
    echo "──────────────────────────────────────────────────────────────"
else
    log "Lingering is enabled — the hub survives logout."
fi

echo ""
log "UI: http://localhost:9090/  ·  manage with: systemctl --user {status,restart,stop} $UNIT_NAME"