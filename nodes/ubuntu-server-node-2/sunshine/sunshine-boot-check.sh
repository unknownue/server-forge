#!/bin/bash
# Check whether Sunshine ACTUALLY started unattended at boot on this node.
#
# Read-only: changes nothing, safe to run any time, no root needed.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/sunshine/sunshine-boot-check.sh
#
# Why this exists separately from sunshine-status.sh:
# sunshine-status.sh answers "is the setup correct right now", which stays green
# whether Sunshine was started by systemd at boot or by hand a minute ago. The
# only way to know that boot autostart works is to ask "did it come up in THIS
# boot, before anyone logged in" — so this script compares the service's start
# time against the boot time and against the graphical login.
#
# Exit codes:
#   0 = Sunshine started at boot, unattended
#   1 = it did not (or cannot be told), with the reason printed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="sunshine.service"

pass() { printf '  [ OK ]   %s\n' "$*"; }
fail() { printf '  [FAIL]   %s\n' "$*"; }
info() { printf '  [info]   %s\n' "$*"; }

echo
echo "== Did Sunshine start unattended at this boot? =="

# 1. Boot start time for the current boot.
boot_epoch=$(date -d "$(uptime -s)" +%s 2>/dev/null || echo "")
if [[ -z "$boot_epoch" ]]; then
    fail "cannot determine boot time from 'uptime -s'"
    exit 1
fi
info "boot at: $(uptime -s)"

# 2. When the service was FIRST started in this boot, per the user manager's
#    journal. This must be the first start, not the latest: any later restart
#    (a hand restart, or a fix applied after boot) would otherwise mask a boot
#    autostart failure — or, equally misleadingly, make a healthy boot start look
#    like a late manual one. Only the earliest start in this boot says whether
#    systemd pulled the unit in on its own.
first_line=$(journalctl --user -b --no-pager 2>/dev/null \
             | grep -m1 "Started $UNIT" || true)
if [[ -z "$first_line" ]]; then
    fail "$UNIT was never started in this boot"
    echo "         fix: systemctl --user start $UNIT  (then re-run this script)"
    exit 1
fi
enter_time="${first_line:0:15}"
enter_epoch=$(date -d "$enter_time" +%s 2>/dev/null || echo "")
info "service first started: $enter_time"

# systemd's own view of the current instance, reported for context only — a
# restart after boot legitimately moves this without meaning autostart failed.
cur_enter=$(systemctl --user show "$UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)
if [[ -n "$cur_enter" && "$cur_enter" != "n/a" ]]; then
    info "current instance started: $cur_enter"
fi

# 3. When a graphical session became active this boot, if it did at all.
gfx_line=$(journalctl --user -u graphical-session.target -b --no-pager 2>/dev/null \
           | grep -m1 "Reached target graphical-session" || true)
if [[ -n "$gfx_line" ]]; then
    gfx_time=${gfx_line%% *}
    gfx_time="${gfx_line:0:15}"
    gfx_epoch=$(date -d "$gfx_time" +%s 2>/dev/null || echo "")
    info "graphical session reached: $gfx_time"
else
    gfx_epoch=""
    info "graphical session: not reached in this boot"
fi

echo

# The decisive test: did the FIRST start of this boot land with the boot
# transaction, rather than at/after a desktop login? A service pulled in by
# default.target starts within a few seconds of boot; one that only started
# because somebody logged in lands at or after the graphical session.
if [[ -z "$enter_epoch" ]]; then
    fail "cannot parse the service start time; inspect manually:"
    echo "         systemctl --user status $UNIT --no-pager"
    exit 1
fi

delta=$(( enter_epoch - boot_epoch ))
info "service started ${delta}s after boot"

if [[ -n "$gfx_epoch" ]]; then
    gfx_delta=$(( gfx_epoch - boot_epoch ))
    info "graphical session started ${gfx_delta}s after boot"
fi

if (( delta < 0 )); then
    fail "service start time precedes boot — clock or unit confusion"
    exit 1
fi

# Threshold: a boot-time start lands well before a human login. 120s is generous
# even for a slow boot, while a login-triggered start on this host has been
# observed ~25 min after boot.
if (( delta <= 120 )); then
    pass "started ${delta}s after boot — consistent with boot autostart, not a login"
else
    # Distinguish "later than a login" from "a login never happened".
    if [[ -n "$gfx_epoch" ]] && (( enter_epoch >= gfx_epoch )); then
        fail "started ${delta}s after boot, at/after the graphical session"
        echo "         This is the login-triggered pattern: autostart did NOT work."
    else
        fail "started ${delta}s after boot — far too late for a boot start"
        echo "         (no graphical session this boot, so this looks like a manual start)"
    fi
    echo "         Check: systemctl --user is-enabled $UNIT"
    echo "                ls -l ~/.config/systemd/user/default.target.wants/$UNIT"
    echo "                loginctl show-user \$USER -p Linger"
    exit 1
fi

# Capture must also be alive, or "started at boot" is only half the story.
pid=$(systemctl --user show -p MainPID --value "$UNIT")
if journalctl --user -u "$UNIT" _PID="$pid" --no-pager 2>/dev/null \
   | grep -q "Found monitor for DRM screencasting"; then
    pass "and KMS capture resolved in this boot (pid $pid)"
else
    fail "started at boot, but KMS capture did NOT resolve (pid $pid)"
    echo "         This is the CAP_SYS_ADMIN / NoNewPrivileges pattern."
    echo "         Check: bash $SCRIPT_DIR/sunshine-status.sh"
    exit 1
fi

echo
pass "boot autostart confirmed for this boot."
exit 0