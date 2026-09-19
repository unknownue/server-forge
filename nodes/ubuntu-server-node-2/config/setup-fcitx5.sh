#!/bin/bash
# Configure fcitx5 as the input method framework on this GNOME/Wayland node and
# make it survive reboots.
#
# Background (why the "config keeps disappearing" myth):
#   The fcitx5 settings in ~/.config/fcitx5/ were NEVER lost — they live on the
#   persistent btrfs root and survived every reboot intact. Two real problems
#   produced the symptom:
#
#   1. Nothing started fcitx5 at login. Opening fcitx5-configtool was what
#      spawned the daemon (its cgroup was app-gnome-fcitx5-configtool-*.scope),
#      so the GUI showed defaults until you visited it.
#   2. GTK/Qt apps were told to use ibus, so even a running fcitx5 received no
#      keystrokes. On this node the session is Wayland, where im-config is a
#      DEAD END: /etc/X11/Xsession.d/70im-config_launch bails out when
#      XDG_SESSION_TYPE=wayland, and the only Wayland hook,
#      /etc/profile.d/im-config_wayland.sh, has its entire body commented out
#      (`if false && ...`). So `im-config -n fcitx5` writes ~/.xinputrc and
#      nothing ever reads it.
#
#   The supported Wayland mechanism is systemd's user environment
#   (~/.config/environment.d/*.conf), which is imported by
#   systemd --user before the graphical session starts. This script uses that.
#
# Usage: sudo bash config/setup-fcitx5.sh [username]
#   username defaults to the invoking sudo user. Pass it explicitly if you run
#   this script in a context where sudo cannot tell (e.g. from a root shell).
# Then log out and log back in (a full reboot is not required).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root:  sudo bash $0" >&2
    exit 1
fi

# The desktop user to configure. Resolved so that we never silently configure
# root's session: prefer an explicit argument, then the invoking sudo user, then
# the first regular login user on the box.
if [[ -n "${1:-}" ]]; then
    TARGET_USER="$1"
elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')"
fi

if [[ -z "${TARGET_USER:-}" ]]; then
    echo "[ERROR] Could not determine the desktop user." >&2
    echo "        Re-run with an explicit user:  sudo bash $0 <username>" >&2
    exit 1
fi

if [[ "$TARGET_USER" == "root" ]]; then
    echo "[ERROR] Refusing to configure fcitx5 for root." >&2
    echo "        Specify the desktop user:  sudo bash $0 <username>" >&2
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "[ERROR] Cannot resolve home directory for user '$TARGET_USER'." >&2
    exit 1
fi

# Run a command as the target user, optionally with its session D-Bus address.
as_user() {
    sudo -u "$TARGET_USER" "$@"
}

echo "=== Configuring fcitx5 for user '$TARGET_USER' (home: $TARGET_HOME) ==="

# ---------------------------------------------------------------------------
# 0. Sanity check: fcitx5 must actually be installed.
# ---------------------------------------------------------------------------
if ! command -v fcitx5 >/dev/null 2>&1; then
    echo "[ERROR] fcitx5 is not installed. Install it first:" >&2
    echo "        sudo apt install fcitx5 fcitx5-chinese-addons fcitx5-frontend-all" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Back up the current configuration before touching anything.
# ---------------------------------------------------------------------------
BACKUP_DIR="$TARGET_HOME/fcitx5-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo ""
echo "=== [1/7] Backing up existing configuration to $BACKUP_DIR ==="
for item in ".config/fcitx5" ".config/environment.d" ".config/autostart" ".xinputrc"; do
    if [[ -e "$TARGET_HOME/$item" ]]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$item")"
        cp -a "$TARGET_HOME/$item" "$BACKUP_DIR/$item" 2>/dev/null || true
    fi
done
echo "Backup complete."

# ---------------------------------------------------------------------------
# 2. THE FIX: inject the IM environment via systemd's user environment.
#    environment.d is read by systemd --user, which on this node already holds
#    QT_IM_MODULE=ibus / XMODIFIERS=@im=ibus imported from the GNOME session.
#    Entries here take precedence for everything systemd spawns, which in a
#    modern GNOME session is the whole app tree.
# ---------------------------------------------------------------------------
echo ""
echo "=== [2/7] Writing systemd user environment (~/.config/environment.d/) ==="
ENV_DIR="$TARGET_HOME/.config/environment.d"
mkdir -p "$ENV_DIR"

cat > "$ENV_DIR/90-fcitx5.conf" <<'EOF'
# Select fcitx5 as the input method framework on Wayland.
# Managed by server-forge: nodes/ubuntu-server-node-2/config/setup-fcitx5.sh
#
# On Wayland im-config is bypassed entirely, so these must be set here.
# Start with "wayland;" so native Wayland apps use the Wayland IM protocol,
# then fall back to the fcitx IM modules for XWayland / GTK / Qt / SDL apps.
QT_IM_MODULES=wayland;fcitx
QT_IM_MODULE=fcitx
GTK_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
CLUTTER_IM_MODULE=fcitx
SDL_IM_MODULE=fcitx
EOF

chown -R "$TARGET_USER:$TARGET_GID" "$ENV_DIR"
chmod 755 "$ENV_DIR"
chmod 644 "$ENV_DIR/90-fcitx5.conf"
echo "Wrote $ENV_DIR/90-fcitx5.conf"

# ---------------------------------------------------------------------------
# 3. Install the XDG autostart entry so fcitx5 launches on every login.
#    NOTE: the DIRECTORY must be user-owned too. A root-owned ~/.config/autostart
#    CRITICAL: do NOT set X-GNOME-Autostart-Phase here.
#    On gnome-session 50 the phase mechanism was removed ("gnome-session no
#    longer manages session services"), and systemd's
#    systemd-xdg-autostart-generator treats that key as a signal to bail out:
#        "<entry>: GNOME startup phases are handled separately,
#         marking as NotShowIn=GNOME."
#    It then emits an ExecCondition that FAILS under GNOME, so the generated
#    service is permanently blocked. With the key present NEITHER launcher
#    starts the app — the entry is dead on both sides. Verified empirically:
#        systemd-xdg-autostart-condition "" "GNOME"   -> exit 1 (blocked)
#        same entry without the key                   -> unit runs normally
#
#    The DIRECTORY must also be user-owned: GNOME reads it as the desktop user.
# ---------------------------------------------------------------------------
echo ""
echo "=== [3/7] Installing XDG autostart entry ==="
AUTOSTART_DIR="$TARGET_HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
GenericName=Input Method
Comment=Start Input Method
Exec=/usr/bin/fcitx5
Icon=fcitx
Terminal=false
Categories=System;Utility;
StartupNotify=false
# NOTE: deliberately NO X-GNOME-Autostart-Phase. On gnome-session 50 that key
# makes systemd's xdg-autostart generator disable this entry under GNOME,
# so fcitx5 would never start. See setup-fcitx5.sh for the full explanation.
X-GNOME-Autostart-Notify=false
X-GNOME-AutoRestart=true
X-KDE-autostart-after=panel
EOF

# Fix ownership of the whole directory tree, not just the file.
chown -R "$TARGET_USER:$TARGET_GID" "$AUTOSTART_DIR"
chmod 700 "$AUTOSTART_DIR"
chmod 644 "$AUTOSTART_DIR/fcitx5.desktop"
echo "Installed $AUTOSTART_DIR/fcitx5.desktop"

# ---------------------------------------------------------------------------
# 4. Best-effort: also select fcitx5 in im-config and ~/.xinputrc.
#    This does NOT work under Wayland (see header) but is harmless and makes
#    the node behave correctly if it is ever switched to an X11 session.
# ---------------------------------------------------------------------------
echo ""
echo "=== [4/7] Setting im-config selection (for X11 sessions) ==="
if [[ -x /usr/bin/im-config ]]; then
    as_user im-config -n fcitx5 >/dev/null 2>&1 && echo "im-config set to fcitx5 (used only in X11 sessions)." \
        || echo "[WARN] im-config -n failed; continuing (not needed on Wayland)."
else
    echo "[WARN] im-config not found; skipping."
fi

# ---------------------------------------------------------------------------
# 5. Normalize ownership/permissions of ~/.config/fcitx5.
#    fcitx5 silently ignores a config directory it cannot write to.
# ---------------------------------------------------------------------------
echo ""
echo "=== [5/7] Fixing ownership/permissions of ~/.config/fcitx5 ==="
mkdir -p "$TARGET_HOME/.config/fcitx5/conf"
chown -R "$TARGET_USER:$TARGET_GID" "$TARGET_HOME/.config/fcitx5"
chmod 700 "$TARGET_HOME/.config/fcitx5" "$TARGET_HOME/.config/fcitx5/conf"
find "$TARGET_HOME/.config/fcitx5" -type f -exec chmod 600 {} +
echo "Ownership and permissions normalized."

# ---------------------------------------------------------------------------
# 6. Import the new environment into the running user manager and restart
#    fcitx5 so the current session picks it up without a logout.
# ---------------------------------------------------------------------------
echo ""
echo "=== [6/7] Reloading systemd user environment and restarting fcitx5 ==="
USER_BUS="unix:path=/run/user/$TARGET_UID/bus"

if [[ -S "/run/user/$TARGET_UID/bus" ]]; then
    as_user env DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
        systemctl --user import-environment \
        QT_IM_MODULES QT_IM_MODULE GTK_IM_MODULE XMODIFIERS CLUTTER_IM_MODULE SDL_IM_MODULE \
        2>/dev/null || true
    echo "Imported IM variables into the running user manager."
else
    echo "[WARN] No D-Bus session for $TARGET_USER; environment applies at next login."
fi

pkill -x fcitx5 2>/dev/null || true
sleep 1
as_user env DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
    QT_IM_MODULES='wayland;fcitx' QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx \
    nohup /usr/bin/fcitx5 -d >/dev/null 2>&1 || true
sleep 2

# ---------------------------------------------------------------------------
# 7. Verification
# ---------------------------------------------------------------------------
echo ""
echo "=== [7/7] Verification ==="

if pgrep -x fcitx5 >/dev/null; then
    echo "[OK]   fcitx5 running (pid: $(pgrep -x fcitx5 | tr '\n' ' '))"
else
    echo "[FAIL] fcitx5 is not running."
fi

for f in "$ENV_DIR/90-fcitx5.conf" "$AUTOSTART_DIR/fcitx5.desktop"; do
    if [[ -f "$f" ]]; then
        echo "[OK]   present: ${f/#$TARGET_HOME/\~}"
    else
        echo "[FAIL] missing: $f"
    fi
done

echo -n "[INFO] autostart dir writable by user: "
if as_user test -w "$AUTOSTART_DIR"; then echo "yes"; else echo "NO (problem)"; fi

# Guard against the gnome-session 50 trap described in step 3.
if grep -qi '^X-GNOME-Autostart-Phase' "$AUTOSTART_DIR/fcitx5.desktop" 2>/dev/null; then
    echo "[FAIL] autostart entry still has X-GNOME-Autostart-Phase — GNOME will NOT start fcitx5."
else
    echo "[OK]   no X-GNOME-Autostart-Phase (GNOME-compatible)"
fi

# Confirm systemd can actually build a runnable unit from the entry.
GEN_UNIT="$(find /run/user/$TARGET_UID/systemd/generator* -name 'app-fcitx5*.service' 2>/dev/null | head -1)"
if [[ -n "$GEN_UNIT" ]]; then
    if grep -q 'systemd-xdg-autostart-condition' "$GEN_UNIT"; then
        echo "[WARN] generated unit has an ExecCondition that may block GNOME; re-login to refresh."
    else
        echo "[OK]   systemd generated an unblocked autostart unit."
    fi
else
    echo "[INFO] no generated unit yet — it appears after the next login."
fi

echo -n "[INFO] ~/.xinputrc: "
grep -h '^run_im' "$TARGET_HOME/.xinputrc" 2>/dev/null || echo "(none)"

echo "[INFO] systemd user environment now reports:"
as_user env DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
    systemctl --user show-environment 2>/dev/null \
    | grep -E '^(QT_IM_MODULE|QT_IM_MODULES|GTK_IM_MODULE|XMODIFIERS)=' \
    | sed 's/^/       /' || echo "       (unavailable)"

echo ""
echo "=== Done ==="
echo "Log out and log back in for the graphical session to pick this up."
echo "After re-login, verify with:"
echo "    env | grep -i im_module     # should show fcitx, not ibus"
echo "    pgrep -x fcitx5             # should print a pid WITHOUT opening the config tool"
echo ""
echo "Backup of previous config: $BACKUP_DIR"