#!/bin/bash
# Deploy the Multica agent runtime on a development machine.
#
# Run this on the machine that holds the repositories and runs the models, NOT
# on the Multica server host.
#
# Usage:
#   bash deploy.sh              # build if needed, then start
#   bash deploy.sh --build      # force a rebuild of the image
#   bash deploy.sh --no-build   # start without building (image must exist)
#
# What it does:
#   1. Checks docker, compose, and the two required .env values
#   2. Creates .env from .env.example on first run
#   3. Builds the image (Multica CLI + DSH + the Multica DSH runtime bridge)
#   4. Verifies the server is reachable and the dsh profile probes clean
#   5. Starts the daemon and reports what the server sees

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
DO_BUILD=auto

for arg in "$@"; do
    case "$arg" in
        --build)    DO_BUILD=yes ;;
        --no-build) DO_BUILD=no ;;
        -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

# ── 1. Prerequisites ────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "'docker' not found."
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) not available."
docker info >/dev/null 2>&1 || die "Docker daemon not reachable."

# ── 2. .env ─────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    log "Creating ${ENV_FILE} from .env.example"
    cp .env.example "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo ""
    echo "Before continuing, fill in the two required values in ${SCRIPT_DIR}/${ENV_FILE}:"
    echo "  MULTICA_SERVER_URL   the Multica server on the LAN (e.g. http://192.168.50.248:3000)"
    echo "  MULTICA_TOKEN        a mul_… personal access token from Settings → API Token"
    echo "  REPOS_DIR            the directory holding the repositories agents should work on"
    echo ""
    echo "Then re-run: bash $0"
    exit 0
fi

env_val() { sed -n "s/^${1}=//p" "$ENV_FILE" | tail -n 1; }

SERVER_URL="$(env_val MULTICA_SERVER_URL)"
TOKEN="$(env_val MULTICA_TOKEN)"
REPOS_DIR_VAL="$(env_val REPOS_DIR)"

[[ -n "$SERVER_URL" ]] || die "MULTICA_SERVER_URL is empty in ${ENV_FILE}."
[[ -n "$TOKEN" ]]      || die "MULTICA_TOKEN is empty in ${ENV_FILE}.
  Create one in the Multica web UI: ${SERVER_URL:-<server>} → Settings → API Token."
[[ -n "$REPOS_DIR_VAL" ]] || die "REPOS_DIR is empty in ${ENV_FILE}.
  Set it to the directory holding the repositories, e.g. /home/you/projects"

[[ "$TOKEN" == mul_* ]] || warn "MULTICA_TOKEN does not start with 'mul_' — expected for a personal access token."

if [[ ! -d "$REPOS_DIR_VAL" ]]; then
    die "REPOS_DIR does not exist: ${REPOS_DIR_VAL}"
fi
log "repos: ${REPOS_DIR_VAL} (-> /repos, read-write)"

# A home-wide mount would defeat the container boundary this whole setup exists
# to provide, so it is refused rather than merely discouraged.
case "$REPOS_DIR_VAL" in
    /|"$HOME"|"$HOME"/*)
        if [[ "$REPOS_DIR_VAL" == "$HOME" || "$REPOS_DIR_VAL" == "/" ]]; then
            die "REPOS_DIR must not be ${REPOS_DIR_VAL}.
  Mounting a home directory or / would expose SSH keys and credentials to every
  agent run. Point it at a directory that holds only the repositories."
        fi
        ;;
esac

# ── 3. Server reachability ──────────────────────────────────────────────────
# Checked before building: a 20-minute image build that ends in "server
# unreachable" is a bad way to learn the URL is wrong.
log "checking ${SERVER_URL}/health ..."
# --noproxy '*': a host-level HTTP proxy would intercept this and answer for a
# hostname it cannot resolve, turning a reachability check into a false failure.
if curl -sf --noproxy '*' --max-time 10 "${SERVER_URL}/health" >/dev/null 2>&1; then
    log "✓ server reachable"
else
    die "cannot reach ${SERVER_URL}/health
  Check that:
    - the Multica stack is running on that host (multica/deploy.sh, then caddy/deploy.sh)
    - MULTICA_SERVER_URL points at the Caddy entry point, not the backend's port 8080
    - this machine can route to it:  curl -v ${SERVER_URL}/health"
fi

# The daemon API must reach the BACKEND. If Caddy is missing its
# /api/daemon/* route, requests fall through to the frontend and the daemon
# registers against the wrong surface — so probe the real endpoint here.
daemon_code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 \
    "${SERVER_URL}/api/daemon/runtimes" || echo 000)
case "$daemon_code" in
    401|403) log "✓ daemon API reachable (HTTP ${daemon_code} = auth required, as expected)" ;;
    404)     die "daemon API returned 404.
  ${SERVER_URL}/api/daemon/* is not being routed to the backend.
  On the Multica host, update caddy/Caddyfile with the /api/daemon block and
  re-run caddy/deploy.sh." ;;
    000)     die "daemon API unreachable at ${SERVER_URL}/api/daemon/runtimes" ;;
    *)       warn "daemon API returned HTTP ${daemon_code} (expected 401) — continuing" ;;
esac

# ── 4. Build ────────────────────────────────────────────────────────────────
if [[ "$DO_BUILD" == "no" ]]; then
    docker image inspect multica-agent:local >/dev/null 2>&1 \
        || die "--no-build given but image multica-agent:local does not exist."
    log "using existing image multica-agent:local"
else
    log "building multica-agent:local (first build compiles the DSH bridge; expect several minutes)"
    docker compose build
fi

# ── 5. Verify the DSH profile inside the built image ────────────────────────
# The bridge is what turns `dsh` into something Multica can drive. Checking it
# here, with the real image, catches a bad build now instead of as an agent
# that registers and then never receives work.
log "verifying the dsh multica profile in the image ..."
if docker compose run --rm --no-deps --entrypoint sh agent -c \
        'dsh --profile multica --probe 2>/dev/null | grep -q "\"protocol_version\":1"' ; then
    log "✓ dsh multica profile reports protocol version 1"
else
    die "the dsh multica profile did not probe successfully.
  Inspect it interactively:
    docker compose run --rm --entrypoint sh agent
    dsh --profile multica --probe
  If the profile is missing, the bridge failed to build or install — check the
  build output for the pnpm build step."
fi

# ── 6. Start ────────────────────────────────────────────────────────────────
log "starting the agent daemon ..."
docker compose up -d

# Give it long enough to authenticate and register before reporting, because
# the failure mode this guards against is a container that is "up" but idle.
log "waiting for the daemon to authenticate and register ..."
ok=0
for _ in $(seq 1 30); do
    if docker compose logs agent 2>&1 | grep -qiE "daemon (started|running)|registered"; then
        ok=1; break
    fi
    if ! docker compose ps --status running --quiet agent | grep -q .; then
        break
    fi
    sleep 4
done

echo ""
if [[ "$ok" -eq 1 ]]; then
    log "✓ agent runtime is running"
else
    warn "could not confirm registration from the logs. Recent output:"
    echo ""
    docker compose logs --tail 40 agent
    echo ""
fi

cat <<EOF

=== Multica agent runtime ===
  Server     : ${SERVER_URL}
  Repos      : ${REPOS_DIR_VAL} -> /repos   (read-write)
  DSH home   : volume multica-agent-dsh-home  (isolated from your ~/.dsh)
  Container  : multica-agent

Check status:
  docker compose logs -f agent
  docker compose exec agent multica daemon status

The runtime appears in the web UI under Settings -> Runtimes once registered.
Create an agent there, point it at this runtime, and assign it an issue.

Stop:
  docker compose down          # keeps the dsh/multica volumes
EOF