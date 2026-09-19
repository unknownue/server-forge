#!/bin/bash
# Service Hub launcher — double-click to open the GPU/service dashboard.
#
# The hub already runs as a systemd --user service (install-service.sh), and
# lingering is on, so it is normally serving before anyone logs in. This script
# therefore does NOT start a second instance: it makes sure the service is up
# and then opens the browser. Starting a bare `deploy.sh` here would collide
# with the service on port 9090.
#
# If the service is not installed at all, it falls back to deploy.sh.

set -uo pipefail

PORT="${SERVICE_HUB_PORT:-9090}"
URL="http://localhost:$PORT/"
UNIT="service-hub.service"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# The desktop copy lives in ~/Desktop, so the repo path is resolved explicitly.
# Keep this in sync if the repository moves.
REPO_DIR="$HOME/Workspace/server-forge"
HUB_DIR="$REPO_DIR/nodes/ubuntu-server-node-2/service-hub"

notify() {
    # Desktop-friendly feedback; falls back to stdout when no notifier exists.
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Service Hub" "$1" "${2:-}" 2>/dev/null || true
    fi
    echo "$1${2:+ — $2}"
}

is_up() {
    curl -s -o /dev/null --max-time 3 "http://localhost:$PORT/api/health"
}

open_browser() {
    # Try a browser that opens a NEW window/tab rather than reusing the session.
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL" >/dev/null 2>&1 &
    elif command -v firefox >/dev/null 2>&1; then
        firefox --new-tab "$URL" >/dev/null 2>&1 &
    else
        notify "Service Hub is running" "Open $URL in a browser"
    fi
}

# ── 1. Already serving? Just open it. ──
if is_up; then
    notify "Service Hub is already running" "$URL"
    open_browser
    exit 0
fi

# ── 2. Service exists but is stopped -> start it. ──
if systemctl --user list-unit-files "$UNIT" 2>/dev/null | grep -q "$UNIT"; then
    notify "Starting Service Hub…" "waiting for :$PORT"
    # Reload first: once the repo copy of the unit is newer than the installed
    # one, systemd prints "unit file changed on disk" on every start.
    systemctl --user daemon-reload
    systemctl --user start "$UNIT"

    for _ in $(seq 1 60); do
        if is_up; then
            notify "Service Hub is ready" "$URL"
            open_browser
            exit 0
        fi
        sleep 1
    done

    notify "Service Hub failed to start" "Check: journalctl --user -u $UNIT -n 50"
    exit 1
fi

# ── 3. No service installed -> check for a terminal first. ──
if [[ ! -f "$HUB_DIR/deploy.sh" ]]; then
    notify "Service Hub not found" "Expected at: $HUB_DIR"
    exit 1
fi

# ── 4. Endpoint answers but not from our service -> do not fight over the port. ──
if ss -tln 2>/dev/null | grep -q ":$PORT "; then
    notify "Port $PORT is in use by something else" "Not starting a second instance"
    open_browser
    exit 0
fi

# ── 5. Fall back to a foreground deploy in a terminal window. ──
notify "Service Hub service not installed" "Starting temporarily via deploy.sh"
for term in gnome-terminal kgx xfce4-terminal konsole xterm; do
    if command -v "$term" >/dev/null 2>&1; then
        case "$term" in
            gnome-terminal) exec "$term" -- bash -c "cd '$HUB_DIR' && bash deploy.sh $PORT" ;;
            kgx)            exec "$term" -- bash -c "cd '$HUB_DIR' && bash deploy.sh $PORT" ;;
            xfce4-terminal) exec "$term" -e "bash -c \"cd '$HUB_DIR' && bash deploy.sh $PORT\"" ;;
            konsole)        exec "$term" -e bash -c "cd '$HUB_DIR' && bash deploy.sh $PORT" ;;
            xterm)          exec "$term" -e bash -c "cd '$HUB_DIR' && bash deploy.sh $PORT" ;;
        esac
    fi
done

# No terminal emulator: run detached, then open the browser once it answers.
nohup bash "$HUB_DIR/deploy.sh" "$PORT" >/dev/null 2>&1 &
for _ in $(seq 1 60); do
    is_up && { notify "Service Hub is ready" "$URL"; open_browser; exit 0; }
    sleep 1
done
notify "Service Hub did not come up" "Run manually: bash $HUB_DIR/deploy.sh"
exit 1