#!/bin/bash
# Diagnose the Sunshine headless streaming setup on this node.
#
# Read-only: changes nothing, safe to run any time, no root needed.
#
# Usage:
#   bash nodes/ubuntu-server-node-2/sunshine/sunshine-status.sh
#
# Exit codes:
#   0 = every check passed, KMS capture should work
#   1 = one or more checks failed (each failure is printed with a fix)
#   2 = sunshine not installed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HOME/.config/sunshine/sunshine.conf"
UNIT="sunshine.service"

FAILED=0
pass() { printf '  [ OK ]   %s\n' "$*"; }
fail() { printf '  [FAIL]   %s\n' "$*"; FAILED=1; }
warn() { printf '  [WARN]   %s\n' "$*"; }
info() { printf '  [info]   %s\n' "$*"; }
hr()   { printf '\n== %s ==\n' "$*"; }

command -v sunshine >/dev/null 2>&1 || { echo "sunshine is not installed."; exit 2; }

hr "Version"
info "$(sunshine --version 2>/dev/null | grep -o 'Sunshine version: .*' | head -1)"

# ---------------------------------------------------------------------------
hr "Service"
if systemctl --user is-active --quiet "$UNIT"; then
    pass "$UNIT is active (pid $(systemctl --user show -p MainPID --value "$UNIT"))"
else
    fail "$UNIT is not active"
    echo "         fix: systemctl --user start $UNIT"
    echo "         log: journalctl --user -u $UNIT -n 30 --no-pager"
fi

linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)
if [[ "$linger" == "yes" ]]; then
    pass "Linger=yes (survives logout — required for headless)"
else
    fail "Linger=$linger (service dies at logout)"
    echo "         fix: sudo loginctl enable-linger $USER"
fi

# ---------------------------------------------------------------------------
hr "Configuration"
if [[ -f "$CONF" ]]; then
    pass "config present: $CONF"
    for key in encoder output_name adapter_name; do
        val=$(grep -E "^\s*$key\s*=" "$CONF" 2>/dev/null | tail -1 | sed 's/.*=\s*//')
        if [[ -n "$val" ]]; then
            info "$key = $val"
        else
            warn "$key not set in $CONF"
        fi
    done
else
    fail "no config at $CONF"
    echo "         fix: bash $SCRIPT_DIR/install.sh"
fi

# ---------------------------------------------------------------------------
hr "GPU / DRM nodes"
if [[ -d /dev/dri ]]; then
    pass "/dev/dri present"
    for n in /dev/dri/renderD* /dev/dri/card*; do
        [[ -e "$n" ]] || continue
        info "$n ($(stat -c '%U:%G %a' "$n"))"
    done
else
    fail "/dev/dri missing — amdgpu not bound?"
fi

# Membership in render/video is what grants access to /dev/dri/* without root.
for g in render video input; do
    if id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
        pass "user in group: $g"
    else
        fail "user NOT in group: $g"
        echo "         fix: sudo usermod -aG $g $USER   (then re-login)"
    fi
done

# ---------------------------------------------------------------------------
hr "Target GPU connector state (KMS needs a connected connector)"
# The target is derived from the config, not hardcoded: this node has moved
# between card0 (physical monitor, the interim setup) and card1 (dummy plug,
# the headless end state), and a hardcoded card silently reports the wrong GPU.
adapter=$(grep -E '^\s*adapter_name\s*=' "$CONF" 2>/dev/null | tail -1 | sed 's/.*=\s*//' | tr -d ' ')
cfg_out=$(grep -E '^\s*output_name\s*=' "$CONF" 2>/dev/null | tail -1 | sed 's/.*=\s*//' | tr -d ' ')
TARGET_CARD=""

# Map the configured render node back to its card by resolving the DRM device
# symlinks, which is the only reliable card<->renderD association.
if [[ -n "$adapter" && -e "$adapter" ]]; then
    want=$(readlink -f "/sys/class/drm/$(basename "$adapter")/device" 2>/dev/null)
    for c in /sys/class/drm/card[0-9]*; do
        [[ -e "$c/device" ]] || continue
        [[ "$(basename "$c")" == *-* ]] && continue
        if [[ "$(readlink -f "$c/device")" == "$want" ]]; then
            TARGET_CARD=$(basename "$c")
            break
        fi
    done
fi
# Fall back to the card owning the configured connector if the render node
# could not be resolved.
if [[ -z "$TARGET_CARD" && -n "$cfg_out" ]]; then
    for c in /sys/class/drm/card[0-9]*-"$cfg_out"; do
        [[ -e "$c" ]] || continue
        TARGET_CARD=$(basename "$c" | sed 's/-.*//')
        break
    done
fi
TARGET_CARD="${TARGET_CARD:-card0}"

# Fetch the journal once; later sections (capture backend, encoders) read it.
log=$(journalctl --user -u "$UNIT" -n 200 --no-pager 2>/dev/null || true)

info "from config: adapter_name=$adapter, output_name=$cfg_out"
if [[ -d /sys/class/drm/$TARGET_CARD ]]; then
    pci=$(grep -oP 'PCI_SLOT_NAME=\K.*' /sys/class/drm/$TARGET_CARD/device/uevent 2>/dev/null)
    info "resolved target: $TARGET_CARD (PCI $pci)"

    # Verify the configured connector actually belongs to the resolved card.
    if [[ -n "$cfg_out" && ! -e "/sys/class/drm/$TARGET_CARD-$cfg_out/status" ]]; then
        other=$(ls -d /sys/class/drm/card[0-9]*-"$cfg_out" 2>/dev/null | head -1 | xargs -r basename)
        fail "connector '$cfg_out' does not exist on $TARGET_CARD"
        [[ -n "$other" ]] && info "it belongs to: $other — adapter_name/output_name disagree"
    fi

    connected_any=0
    for c in /sys/class/drm/${TARGET_CARD}-*; do
        [[ -e "$c/status" ]] || continue
        name=$(basename "$c")
        st=$(cat "$c/status" 2>/dev/null)
        en=$(cat "$c/enabled" 2>/dev/null)
        nm=$(cat "$c/modes" 2>/dev/null | wc -l)
        if [[ "$st" == "connected" ]]; then
            pass "$name: $st, enabled=$en, $nm modes  <-- KMS capture candidate"
            connected_any=1
        else
            info "$name: $st, enabled=$en"
        fi
    done

    if [[ $connected_any -eq 1 ]]; then
        pass "at least one connector on $TARGET_CARD is connected"
    else
        fail "no connector on $TARGET_CARD is connected"
        echo "         fix: plug an HDMI dummy plug into $TARGET_CARD, or point"
        echo "              output_name/adapter_name at a card that has a display."
        echo "              Without a connected connector KMS has no framebuffer"
        echo "              to capture and the stream will fail to start."
    fi
else
    fail "/sys/class/drm/$TARGET_CARD not found"
fi

# Cross-check the connector named in the config really exists and is connected.
if [[ -n "$cfg_out" ]]; then
    if [[ -e "/sys/class/drm/$TARGET_CARD-$cfg_out/status" ]]; then
        st=$(cat "/sys/class/drm/$TARGET_CARD-$cfg_out/status")
        if [[ "$st" == "connected" ]]; then
            pass "configured output_name=$cfg_out exists and is connected"
        else
            fail "configured output_name=$cfg_out is '$st', not connected"
            echo "         A dummy plug may be on a different port. Pick the"
            echo "         connected one above and update output_name in:"
            echo "             $CONF"
        fi
    else
        fail "configured output_name=$cfg_out does not exist on $TARGET_CARD"
        echo "         Valid names: $(ls -d /sys/class/drm/${TARGET_CARD}-* 2>/dev/null | xargs -n1 basename | sed "s/${TARGET_CARD}-//" | tr '\n' ' ')"
    fi
fi

# ---------------------------------------------------------------------------
hr "Capture backend"
# With output_name set to a DRM connector name, Sunshine captures via KMS rather
# than the Wayland portal. Confirm that is what actually happened, because the
# two paths behave differently (see the encoder note below).
#
# Only the CURRENT service run is examined: the journal may still hold an older
# run that used the portal (e.g. from before output_name was set), and matching
# across runs would report the wrong backend.
runlog=$(journalctl --user -u "$UNIT" --since "$(systemctl --user show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null)" --no-pager 2>/dev/null || true)
[[ -n "$runlog" ]] || runlog="$log"
kms_ok=0
if [[ -n "$runlog" ]]; then
    # Authoritative success signals, all emitted at the default `info` level.
    # NOTE: do NOT key off "Final KMS display_names return list" — that one is
    # debug-level only and is absent when the service runs at info, which made
    # an earlier version of this script report a false warning.
    if grep -q "Mapped '.*' to kmsgrab monitor index" <<<"$runlog"; then
        mapped=$(grep -oP "Mapped '\K[^']+(?=' to kmsgrab)" <<<"$runlog" | tail -1)
        if grep -q "Found connector ID" <<<"$runlog" && grep -q "Found monitor for DRM screencasting" <<<"$runlog"; then
            kms_ok=1
            pass "KMS resolved a capturable output: $mapped (connector + monitor found)"
        else
            info "kmsgrab mapped '$mapped', but no connector/monitor was resolved"
        fi
        if [[ -n "$cfg_out" && "$mapped" != "$cfg_out" ]]; then
            warn "KMS captured '$mapped' but config says output_name=$cfg_out"
        fi
    fi
    if grep -q "Screencasting with KMS" <<<"$runlog"; then
        pass "KMS capture backend in use (not the Wayland portal)"
    elif grep -q "portalgrab" <<<"$runlog"; then
        warn "portal capture in use, not KMS"
        info "set output_name to a DRM connector (e.g. HDMI-A-1), not a Wayland name"
    else
        warn "no capture-backend line found in the current service run"
    fi

    # 'Couldn't find monitor [0]' is NOT a failure signal on its own: Sunshine
    # emits it during the startup encoder sweep, which probes monitors in an
    # order that need not match the configured connector. It appears even on a
    # fully working setup, so only flag it when KMS never resolved a target.
    if grep -q "Couldn't find monitor \[0\]" <<<"$runlog"; then
        if [[ $kms_ok -eq 1 ]]; then
            info "startup sweep logged 'Couldn't find monitor [0]' — harmless here,"
            info "KMS resolved a target anyway (see above)."
        else
            warn "'Couldn't find monitor [0]' and no KMS target resolved"
            info "usually means no connected connector / active CRTC on $TARGET_CARD"
        fi
    fi
fi

# ---------------------------------------------------------------------------
hr "Encoders reported by Sunshine"
# Sunshine validates a *named* encoder with a real test encode against the
# active capture surface, during a startup sweep that intentionally generates
# errors ("you can safely ignore those errors"). Only the post-sweep conclusion
# is meaningful, so look for the 'Found ... encoder' lines, not the failures.
if [[ -n "$runlog" ]]; then
    encs=$(grep -oE 'Found (H\.264|HEVC|AV1) encoder: [a-z0-9_]+ \[[a-z]+\]' <<<"$runlog" | sort -u)
    if [[ -n "$encs" ]]; then
        while read -r e; do pass "$e"; done <<< "$encs"
    else
        warn "no encoder passed validation in the current service run"
        info "run: journalctl --user -u $UNIT -f   then reconnect a client"
    fi
else
    warn "no journal available for $UNIT"
fi

# ---------------------------------------------------------------------------
hr "Network"
ip=$(hostname -I | awk '{print $1}')
info "host address: $ip"
for p in 47984 47989 47990 48010; do
    if ss -tln 2>/dev/null | grep -q ":$p "; then
        pass "tcp/$p listening"
    else
        warn "tcp/$p not listening"
    fi
done
info "Web UI: https://$ip:47990"

# ---------------------------------------------------------------------------
hr "Recent log (last 15 lines)"
journalctl --user -u "$UNIT" -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || warn "journal unavailable"

# ---------------------------------------------------------------------------
echo
if [[ $FAILED -eq 0 ]]; then
    echo "RESULT: all checks passed — KMS headless capture should work."
    exit 0
else
    echo "RESULT: failures above must be fixed before streaming will work."
    exit 1
fi