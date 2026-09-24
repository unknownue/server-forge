#!/bin/bash
# Entrypoint for the containerised Multica agent runtime.
#
# Two problems this solves that a plain `multica daemon start` CMD cannot:
#
# 1. Authentication. `multica login` completes in a BROWSER, which a container
#    does not have. The supported path for a headless machine is a personal
#    access token (mul_…) created in the web UI, which the CLI then stores in
#    the profile config — see apps/docs/content/docs/auth-tokens.mdx.
#
# 2. Runnability. The container's DSH_HOME and repo mount must be writable and
#    the profile present before the daemon probes for tools, otherwise the
#    daemon starts, registers nothing, and reports a healthy process.

set -euo pipefail

DSH_HOME="${DSH_HOME:-/dsh-home}"
MULTICA_HOME="${MULTICA_HOME:-/multica-home}"
export DSH_HOME MULTICA_HOME

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ── Preconditions ───────────────────────────────────────────────────────────
[[ -n "${MULTICA_TOKEN:-}" ]] || die "MULTICA_TOKEN is not set.
  Create a personal access token in the Multica web UI
  (Settings → API Token), then put it in .env as MULTICA_TOKEN=mul_..."
[[ -n "${MULTICA_SERVER_URL:-}" ]] || die "MULTICA_SERVER_URL is not set (e.g. http://192.168.50.248:3000)."

log "server: ${MULTICA_SERVER_URL}"
log "dsh home: ${DSH_HOME}  multica home: ${MULTICA_HOME}"

# The DSH profile is baked into the image, but DSH_HOME may be a mounted volume
# that masks it. Re-provision rather than failing, so a persist-ent state
# volume that predates the bridge does not leave the runtime unusable.
if ! dsh --profile multica --probe >/dev/null 2>&1; then
    log "multica profile not usable in ${DSH_HOME}; installing the bridge into it"
    bridge_tgz="$(ls /opt/multica-*.tgz 2>/dev/null | head -n1)" \
        || die "bridge tarball missing from the image"
    dsh plugin --profile multica add "$bridge_tgz"
fi

# Gate on BOTH the probe and a real stdio handshake.
#
# The probe alone is not sufficient, which is the single most misleading thing
# about this integration: the bridge emits its probe frame before the plugin
# tree finishes loading, so `--probe` reports protocol_version 1 even when the
# runtime cannot boot and every task will fail with STARTUP_FAILED. The
# Dockerfile's smoke test covers this at build time; repeating a cheap version
# of it here catches a profile that a stale state volume has clobbered.
#
# A bare `dsh` prints a version and still cannot run a task, so the probe is
# still worth asserting first — it gives a clearer message for the common case
# of a missing profile.
if ! dsh --profile multica --probe 2>/dev/null | grep -q '"protocol_version":1'; then
    die "dsh --profile multica --probe did not report protocol_version 1.
  The Multica runtime profile is not working. Inspect it directly:
    docker compose run --rm --entrypoint sh agent
    dsh --profile multica --probe"
fi

if printf '%s\n' '{"v":1,"type":"execute","request_id":"gate","cwd":"/tmp","prompt":"noop","mcp_servers":[]}' \
        | timeout 60 dsh --profile multica --stdio 2>/dev/null | grep -q 'STARTUP_FAILED'; then
    die "the runtime starts but cannot serve tasks (STARTUP_FAILED).
  This usually means the DSH version and the runtime profile disagree. Check
  that DSH_VERSION matches the release the vendored bridge was built for —
  see the DSH version note in Dockerfile. Rebuild with: bash deploy.sh --build"
fi
log "dsh multica profile OK (probe + stdio handshake)"

# ── Git identity ────────────────────────────────────────────────────────────
# Agents commit to a branch per task. Without an identity, git refuses the
# commit and the run fails at the delivery step, long after it did real work.
if [[ -n "${GIT_AUTHOR_NAME:-}" ]]; then
    git config --global user.name  "${GIT_AUTHOR_NAME}"
    git config --global user.email "${GIT_AUTHOR_EMAIL:-${GIT_AUTHOR_NAME}@localhost}"
    log "git identity: ${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL:-${GIT_AUTHOR_NAME}@localhost}>"
fi

# ── CLI configuration ───────────────────────────────────────────────────────
mkdir -p "$MULTICA_HOME/dsh-sessions" "$MULTICA_HOME/work"

# --token is used rather than `multica login` because there is no browser here.
# Re-running it is how a rotated or expired PAT gets picked up.
log "configuring CLI for ${MULTICA_SERVER_URL}"
multica config set server_url "$MULTICA_SERVER_URL"
[[ -n "${MULTICA_APP_URL:-}" ]] && multica config set app_url "$MULTICA_APP_URL"
multica login --token "${MULTICA_TOKEN}"

# A daemon cannot start without at least one detected agent CLI. Failing here
# with the actual reason beats a container that runs but claims no runtimes.
log "detected agents:"
multica daemon status 2>&1 | sed 's/^/  /' || true

case "${1:-daemon}" in
    daemon)
        log "starting daemon (foreground)"
        # --foreground keeps the daemon as PID 1's child so tini reaps it and
        # `docker logs` streams the real output instead of an empty file.
        exec multica daemon start --foreground
        ;;
    shell)
        log "dropping to a shell"
        exec bash
        ;;
    *)
        log "exec: $*"
        exec "$@"
        ;;
esac