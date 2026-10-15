#!/bin/bash
# Disable (or restore) automatic software-update detection on this node.
#
# Scope: apt + snap. Firmware updates (fwupd-refresh.timer / fwupd.service) are
# deliberately LEFT ENABLED — firmware is driver-level and rare, and this node
# runs a locally built kernel where fwupd metadata costs nothing.
#
# What gets disabled and why each one is on the list:
#   apt-daily.timer              refreshes the apt package index twice a day
#                                (this is the "software update detection" itself)
#   apt-daily-upgrade.timer      downloads + installs upgrades daily, via
#                                /usr/lib/apt/apt.systemd.daily
#   unattended-upgrades.service  installs security upgrades in the background
#                                and at shutdown (unattended-upgrade-shutdown)
#   update-notifier-download.timer  re-downloads metadata for failed packages
#   update-notifier-motd.timer   weekly check for a NEW UBUNTU RELEASE and the
#                                "N updates available" MOTD banner
#   /etc/apt/apt.conf.d/99disable-auto-updates
#                                belt-and-braces APT::Periodic::* "0" override;
#                                even if a timer is ever re-enabled, the daily
#                                script exits without doing anything
#   /etc/update-manager/release-upgrades
#                                Prompt=never — no new-release upgrade checks
#   snap auto-refresh            `snap refresh --hold` (snapd >= 2.58 holds
#                                indefinitely; manual `snap refresh` still works)
#
# Why this needs root: every target is a system unit or an /etc config file.
#
# Usage (run from the repo root):
#   sudo bash nodes/ubuntu-server-node-2/config/disable-update-checks.sh            # disable (default)
#   sudo bash nodes/ubuntu-server-node-2/config/disable-update-checks.sh enable     # restore Ubuntu defaults
#   sudo bash nodes/ubuntu-server-node-2/config/disable-update-checks.sh status     # read-only report
#
# Idempotent: re-running `disable` on an already-disabled system is a no-op.

set -euo pipefail

APT_OVERRIDE="/etc/apt/apt.conf.d/99disable-auto-updates"
RELEASE_UPGRADES="/etc/update-manager/release-upgrades"

# Timers: scheduled update checks. Disabled (not masked) — `enable` re-enables.
TIMERS=(
    apt-daily.timer
    apt-daily-upgrade.timer
    update-notifier-download.timer
    update-notifier-motd.timer
)

# Services: static or triggered units that must not start even on a manual
# `systemctl start` or through some other unit. Masked on disable.
SERVICES=(
    apt-daily.service
    apt-daily-upgrade.service
    unattended-upgrades.service
)

# Ubuntu's stock value of /etc/update-manager/release-upgrades Prompt=.
DEFAULT_RELEASE_PROMPT="lts"

usage() {
    cat <<EOF
Disable or restore automatic software-update detection (apt + snap; fwupd kept).

  sudo bash $0            # disable (default)
  sudo bash $0 enable     # restore Ubuntu defaults
  sudo bash $0 status     # read-only report
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[FAIL] root required — run: sudo bash $0 $*" >&2
        exit 1
    fi
}

do_disable() {
    local t s

    for t in "${TIMERS[@]}"; do
        systemctl disable --now "$t" 2>/dev/null || true
        echo "[ ok ] timer disabled: $t"
    done

    for s in "${SERVICES[@]}"; do
        systemctl disable --now "$s" 2>/dev/null || true
        systemctl mask "$s" 2>/dev/null || true
        echo "[ ok ] service masked: $s"
    done

    # Override wins over 10periodic / 20auto-upgrades (later file, apt reads
    # apt.conf.d in lexical order). A drop-in, not an edit of a dpkg conffile,
    # so a package upgrade can never resurrect the checks behind our back.
    cat > "$APT_OVERRIDE" <<'EOF'
// Managed by server-forge (nodes/ubuntu-server-node-2/config/disable-update-checks.sh).
// Disables ALL APT::Periodic activity — apt-daily* becomes a no-op even if its
// timer is re-enabled. Remove this file (or run the script with `enable`) to
// restore automatic update checks.
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    echo "[ ok ] wrote $APT_OVERRIDE"

    if [ -f "$RELEASE_UPGRADES" ]; then
        sed -i "s/^Prompt=.*/Prompt=never/" "$RELEASE_UPGRADES"
        echo "[ ok ] $RELEASE_UPGRADES: Prompt=never (no new-release checks)"
    else
        echo "[warn] $RELEASE_UPGRADES missing — skipped"
    fi

    if [ -x /usr/bin/snap ]; then
        # Holds auto-refreshes indefinitely (snapd >= 2.58). Manual
        # `snap refresh` and `snap refresh <snap>` still work.
        snap refresh --hold
        echo "[ ok ] snap auto-refresh held"
    else
        echo "[warn] snap not installed — skipped"
    fi

    echo
    echo "Done. Software update detection is disabled (fwupd kept)."
}

do_enable() {
    local t s

    for t in "${TIMERS[@]}"; do
        systemctl enable --now "$t" 2>/dev/null || true
        echo "[ ok ] timer enabled: $t"
    done

    for s in "${SERVICES[@]}"; do
        systemctl unmask "$s" 2>/dev/null || true
        systemctl enable "$s" 2>/dev/null || true
        echo "[ ok ] service unmasked: $s"
    done

    rm -f "$APT_OVERRIDE"
    echo "[ ok ] removed $APT_OVERRIDE"

    if [ -f "$RELEASE_UPGRADES" ]; then
        sed -i "s/^Prompt=.*/Prompt=${DEFAULT_RELEASE_PROMPT}/" "$RELEASE_UPGRADES"
        echo "[ ok ] $RELEASE_UPGRADES: Prompt=${DEFAULT_RELEASE_PROMPT}"
    fi

    if [ -x /usr/bin/snap ]; then
        snap refresh --unhold
        echo "[ ok ] snap auto-refresh unheld"
    fi

    echo
    echo "Done. Ubuntu's default update checks are restored."
}

do_status() {
    local t s

    echo "== Timers (disabled is what this script wants) =="
    for t in "${TIMERS[@]}"; do
        printf '  %-32s %s / %s\n' "$t" "$(systemctl is-enabled "$t" 2>&1)" "$(systemctl is-active "$t" 2>&1)"
    done
    printf '  %-32s %s / %s   <- kept on purpose\n' "fwupd-refresh.timer" \
        "$(systemctl is-enabled fwupd-refresh.timer 2>&1)" "$(systemctl is-active fwupd-refresh.timer 2>&1)"

    echo "== Services (masked is what this script wants) =="
    for s in "${SERVICES[@]}"; do
        printf '  %-32s %s / %s\n' "$s" "$(systemctl is-enabled "$s" 2>&1)" "$(systemctl is-active "$s" 2>&1)"
    done

    echo "== APT periodic config =="
    if [ -f "$APT_OVERRIDE" ]; then
        echo "  override present: $APT_OVERRIDE"
    else
        echo "  override ABSENT: $APT_OVERRIDE  (checks run on the timer schedule)"
    fi
    apt-config dump | grep -E '^APT::Periodic::(Enable|Update-Package-Lists|Unattended-Upgrade)' | sed 's/^/  /'

    echo "== New-release upgrade check =="
    if [ -f "$RELEASE_UPGRADES" ]; then
        grep -E '^Prompt=' "$RELEASE_UPGRADES" | sed 's/^/  /'
    else
        echo "  (no $RELEASE_UPGRADES)"
    fi

    echo "== snap auto-refresh =="
    if [ -x /usr/bin/snap ]; then
        echo "  refresh.hold: $(snap get system refresh.hold 2>&1)"
    else
        echo "  (snap not installed)"
    fi
}

case "${1:-disable}" in
    disable) require_root "$@"; do_disable ;;
    enable)  require_root "$@"; do_enable ;;
    status)  do_status ;;
    -h|--help|help) usage ;;
    *) echo "[FAIL] unknown argument: $1" >&2; usage >&2; exit 1 ;;
esac
