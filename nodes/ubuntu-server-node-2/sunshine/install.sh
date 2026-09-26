#!/bin/bash
# Install / apply the Sunshine headless streaming configuration on this node.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/sunshine/install.sh           # apply config + enable service
#   bash nodes/ubuntu-server-node-2/sunshine/install.sh --no-start # apply config only
#   bash nodes/ubuntu-server-node-2/sunshine/install.sh --remove   # disable + remove service
#
# What this does, and why each piece is safe to run repeatedly:
#   1. Copies sunshine.conf into ~/.config/sunshine/ (idempotent overwrite of a
#      config file this repo owns — the package-generated one is empty).
#   2. Installs this repo's systemd *user* unit under ~/.config/systemd/user/
#      so it can be enabled, restarted and edited without root. The unit is
#      repo-owned (systemd/sunshine.service), NOT a copy of the packaged one —
#      see the comment in that file for why (headless host + boot autostart).
#   3. Enables + (re)starts it.
#
# Everything here is unprivileged. The account is already in the `render`,
# `video` and `input` groups, which is what Sunshine needs to open
# /dev/dri/renderD* and to inject input via uhid/uinput.
#
# NOTE on lingering: `enable` only starts the service at login. To keep it
# running with no session at all (reboot, nobody logs in — the whole point of a
# headless stream host), the user manager must linger:
#     sudo loginctl enable-linger $USER
# This machine already has Linger=yes; the script reports if that changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NODE_DIR/../.." && pwd)"

CONF_SRC="$SCRIPT_DIR/sunshine.conf"
CONF_DIR="$HOME/.config/sunshine"
CONF_DST="$CONF_DIR/sunshine.conf"

UNIT_NAME="sunshine.service"
# The unit is owned by this repo, not by the package. The packaged unit
# (/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service) is written for
# a desktop session: it is WantedBy=graphical-session.target, a target that only
# a *desktop login* reaches. This machine is a headless stream host that must
# come up at boot with nobody logged in, so the repo unit anchors on
# default.target instead. Installing a copy under the alias name lets us manage
# it as `sunshine.service` without depending on the package's path.
UNIT_SRC="$SCRIPT_DIR/systemd/sunshine.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_DST="$UNIT_DIR/$UNIT_NAME"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# --remove
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
    log "Stopping and disabling $UNIT_NAME…"
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
    rm -f "$UNIT_DST"
    systemctl --user daemon-reload
    log "Removed. Config left in place at $CONF_DST (delete manually if unwanted)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight: is the package present, and can we actually encode?
# ---------------------------------------------------------------------------
if ! command -v sunshine >/dev/null 2>&1; then
    warn "sunshine is not installed."
    echo "Install it from the LizardByte apt repository:"
    echo "    sudo apt install -y sunshine"
    echo "(The repo is already configured at /etc/apt/sources.list.d/lizardbyte-stable.list)"
    exit 1
fi

log "Sunshine: $(sunshine --version 2>/dev/null | grep -o 'Sunshine version: .*' | head -1)"

# ---------------------------------------------------------------------------
# Apply configuration
# ---------------------------------------------------------------------------
mkdir -p "$CONF_DIR"

# Back up a pre-existing config once, so a hand-tuned value is never silently
# lost on the first run of this script.
if [[ -f "$CONF_DST" && ! -f "$CONF_DST.pre-repo.bak" ]]; then
    cp "$CONF_DST" "$CONF_DST.pre-repo.bak"
    log "Backed up existing config -> $CONF_DST.pre-repo.bak"
fi

cp "$CONF_SRC" "$CONF_DST"
log "Applied config -> $CONF_DST"

# apps.json is package-generated on first run and contains the "Desktop" /
# "Steam Big Picture" entries. Only seed it if absent; never clobber a user's
# own application list.
if [[ ! -f "$CONF_DIR/apps.json" ]]; then
    log "Note: apps.json not present yet; Sunshine will generate it on first start."
fi

# ---------------------------------------------------------------------------
# Install the user unit
# ---------------------------------------------------------------------------
mkdir -p "$UNIT_DIR"
if [[ ! -f "$UNIT_SRC" ]]; then
    warn "Repo unit not found at $UNIT_SRC — cannot install a boot-starting service."
    exit 1
fi
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
log "Installed unit -> $UNIT_DST"

# Drop a stale enable symlink under graphical-session.target. Older revisions of
# this script copied the packaged unit, which enabled itself into that target;
# leaving the link behind keeps a second, desktop-only start path alive.
STALE_WANT="$UNIT_DIR/graphical-session.target.wants/$UNIT_NAME"
if [[ -L "$STALE_WANT" ]]; then
    rm -f "$STALE_WANT"
    log "Removed stale $(basename "$(dirname "$STALE_WANT")")/$UNIT_NAME symlink"
fi

systemctl --user daemon-reload
log "Reloaded user systemd"

# ---------------------------------------------------------------------------
# Enable + start
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--no-start" ]]; then
    log "--no-start given; skipping enable/start."
else
    systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || true
    log "Enabled $UNIT_NAME"

    # restart (not start) so re-running picks up config edits
    systemctl --user restart "$UNIT_NAME"
    log "Started $UNIT_NAME"

    sleep 3
    if systemctl --user is-active --quiet "$UNIT_NAME"; then
        log "Service is active."
    else
        warn "Service is not active. Recent log:"
        journalctl --user -u "$UNIT_NAME" -n 20 --no-pager 2>/dev/null || true
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Report state that the operator needs to act on
# ---------------------------------------------------------------------------
echo
log "Linger check (needed for streaming with nobody logged in):"
linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)
if [[ "$linger" == "yes" ]]; then
    log "  Linger=yes — the service survives logout. Good."
else
    warn "  Linger=$linger — the service will STOP when you log out."
    echo "  Fix with:  sudo loginctl enable-linger $USER"
fi

echo
# Boot persistence is the whole point of this unit, and it is easy to get wrong
# in a way that still looks fine interactively (`enable` + a manual start). Check
# the two things that actually decide whether it comes up unattended:
#   - the enable symlink must hang off default.target, not graphical-session.target
#   - linger must be on, or the user manager never starts at boot at all
log "Boot-autostart check (starts with nobody logged in):"
if [[ "$linger" != "yes" ]]; then
    warn "  WILL NOT START AT BOOT: lingering is off, so user@$(id -u).service"
    echo "         (and everything wanted by default.target) never runs."
    echo "         Fix with:  sudo loginctl enable-linger $USER"
elif [[ -L "$UNIT_DIR/default.target.wants/$UNIT_NAME" ]]; then
    log "  enable symlink -> default.target.wants: OK"
    log "  Linger=yes: OK — Sunshine will start on boot with no login."
else
    warn "  WILL NOT START AT BOOT: no default.target.wants/$UNIT_NAME symlink."
    echo "         Fix with:  systemctl --user enable $UNIT_NAME"
fi

echo
# Resolve the target card from the config rather than assuming one: this node
# has run on card0 (physical monitor) and card1 (dummy plug), and a hardcoded
# card would report the wrong GPU's connectors.
adapter=$(grep -E '^\s*adapter_name\s*=' "$CONF_SRC" 2>/dev/null | tail -1 | sed 's/.*=\s*//' | tr -d ' ')
cfg_out=$(grep -E '^\s*output_name\s*=' "$CONF_SRC" 2>/dev/null | tail -1 | sed 's/.*=\s*//' | tr -d ' ')
tcard=""
if [[ -n "$adapter" && -e "$adapter" ]]; then
    want=$(readlink -f "/sys/class/drm/$(basename "$adapter")/device" 2>/dev/null)
    for c in /sys/class/drm/card[0-9]*; do
        [[ -e "$c/device" && "$(basename "$c")" != *-* ]] || continue
        if [[ "$(readlink -f "$c/device")" == "$want" ]]; then tcard=$(basename "$c"); break; fi
    done
fi
tcard="${tcard:-card0}"

log "Connector state on the configured target ($tcard from adapter_name=$adapter):"
connected=0
for c in /sys/class/drm/${tcard}-*; do
    [[ -e "$c/status" ]] || continue
    st=$(cat "$c/status" 2>/dev/null)
    mark=""
    if [[ "$st" == "connected" ]]; then mark="<-- usable for KMS capture"; connected=1; fi
    printf '  %-20s %s %s\n' "$(basename "$c")" "$st" "$mark"
done

cat <<EOF

Next steps:
  1. At least one connector above should read "connected", and it should match
     output_name=$cfg_out. For the headless (dummy plug) target, that connector
     must be on card1 and adapter_name must be /dev/dri/renderD129.
  2. Open the Web UI to pair a client:
         https://$(hostname -I | awk '{print $1}'):47990
  3. Verify capture end-to-end:
         bash $SCRIPT_DIR/sunshine-status.sh

EOF