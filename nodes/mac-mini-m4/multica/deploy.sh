#!/bin/bash
# Deploy the Multica self-host stack (PostgreSQL + backend + frontend).
#
# Usage:
#   bash nodes/mac-mini-m4/multica/deploy.sh              # normal deploy / restart
#   bash nodes/mac-mini-m4/multica/deploy.sh --no-pull    # skip the image pull
#   bash nodes/mac-mini-m4/multica/deploy.sh --build      # build from the submodule
#
# What it does:
#   1. Checks docker / docker compose and host port availability
#   2. Creates .env from .env.example on first run, with random secrets
#   3. Pulls the arm64 Multica images, through a GHCR mirror when configured
#   4. Starts the stack and waits for the backend health endpoint
#
# Image pulling, and why it is not just `docker compose pull`:
#   registry-mirrors in ~/.docker/daemon.json covers Docker Hub ONLY. It does
#   not proxy ghcr.io, where the Multica images live. So the images are pulled
#   under a mirror-prefixed name and then re-tagged to their real ghcr.io name,
#   which is what the Compose file references. Once re-tagged, Compose finds
#   them locally and does not reach the network at all.
#
#   If the mirror does not carry ghcr.io, the script falls back to pulling from
#   ghcr.io directly. If both fail it stops and says so — it does not silently
#   continue into a half-deployed stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"

DO_PULL=1
DO_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --no-pull) DO_PULL=0 ;;
        --build)   DO_BUILD=1; DO_PULL=0 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "ERROR: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }

# ── 1. Prerequisites ────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' not found. Install Docker Desktop." >&2
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' (v2) not available. Legacy docker-compose v1 is not supported." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon not reachable. Start Docker Desktop first." >&2
    exit 1
fi

# ── 2. Port check ───────────────────────────────────────────────────────────
# Host ports this stack publishes. Postgres deliberately publishes none.
BACKEND_PORT_DEFAULT=8080
FRONTEND_PORT_DEFAULT=3001

check_port() {
    local port=$1 label=$2
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        # Our own containers from a previous run are not a conflict.
        if docker ps --format '{{.Names}}' | grep -q '^multica-'; then
            return 0
        fi
        warn "port ${port} (${label}) is already in use:"
        lsof -nP -iTCP:"$port" -sTCP:LISTEN | tail -n +2 | sed 's/^/       /' >&2
        warn "free it, or change ${label} in .env, then re-run."
        return 1
    fi
    return 0
}

check_port "$BACKEND_PORT_DEFAULT"  "BACKEND_PORT"  || exit 1
check_port "$FRONTEND_PORT_DEFAULT" "FRONTEND_PORT" || exit 1

# ── 3. .env ─────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    log "Creating ${ENV_FILE} from ${ENV_EXAMPLE} with random secrets..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"

    JWT=$(openssl rand -hex 32)
    PGPASS=$(openssl rand -hex 24)
    VCSKEY=$(openssl rand -base64 32)

    # BSD sed (macOS) needs the empty -i argument; GNU sed must not have it.
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s#^JWT_SECRET=.*#JWT_SECRET=${JWT}#" "$ENV_FILE"
        sed -i '' "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${PGPASS}#" "$ENV_FILE"
        sed -i '' "s#^MULTICA_VCS_SECRET_KEY=.*#MULTICA_VCS_SECRET_KEY=${VCSKEY}#" "$ENV_FILE"
    else
        sed -i "s#^JWT_SECRET=.*#JWT_SECRET=${JWT}#" "$ENV_FILE"
        sed -i "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${PGPASS}#" "$ENV_FILE"
        sed -i "s#^MULTICA_VCS_SECRET_KEY=.*#MULTICA_VCS_SECRET_KEY=${VCSKEY}#" "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE"
    log "Generated JWT_SECRET, POSTGRES_PASSWORD, MULTICA_VCS_SECRET_KEY (mode 600)"
else
    log "Using existing ${ENV_FILE} (secrets are not regenerated)"
fi

# Read a value from .env without sourcing it — a stray line must not be able to
# execute, and Compose-style ${VAR} references are not shell-expanded here.
env_val() {
    local key=$1
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

TAG=$(env_val MULTICA_IMAGE_TAG); TAG=${TAG:-latest}
GHCR_MIRROR=$(env_val GHCR_MIRROR)

# ── 4. Images ───────────────────────────────────────────────────────────────
pull_with_mirror() {
    local img=$1 target="ghcr.io/multica-ai/${img}:${TAG}"
    # A local image is enough when the caller only wants a restart.
    if [[ "${DO_PULL}" -eq 0 ]]; then
        docker image inspect "$target" >/dev/null 2>&1 && return 0
    fi

    if [[ -n "$GHCR_MIRROR" ]]; then
        local src="${GHCR_MIRROR}/ghcr.io/multica-ai/${img}:${TAG}"
        log "Pulling ${src}"
        if docker pull "$src"; then
            docker tag "$src" "$target"
            return 0
        fi
        warn "mirror pull failed for ${img}; falling back to ghcr.io directly"
    fi

    log "Pulling ${target}"
    docker pull "$target"
}

if [[ "$DO_BUILD" -eq 1 ]]; then
    SUBMODULE_DIR="$SCRIPT_DIR/../../submodules/multica"
    if [[ ! -f "$SUBMODULE_DIR/docker-compose.selfhost.build.yml" ]]; then
        echo "ERROR: --build needs the multica submodule (and its build override) at:" >&2
        echo "  ${SUBMODULE_DIR}" >&2
        echo "  Run: bash scripts/setup-submodules.sh" >&2
        exit 1
    fi
    log "Building from source at ${SUBMODULE_DIR} (slow: Go + pnpm toolchain)"
    cp "$ENV_FILE" "$SUBMODULE_DIR/.env"
    docker compose -f "$SUBMODULE_DIR/docker-compose.selfhost.yml" \
                   -f "$SUBMODULE_DIR/docker-compose.selfhost.build.yml" build
    for img in multica-backend multica-web; do
        docker tag "${img}:dev" "ghcr.io/multica-ai/${img}:${TAG}" 2>/dev/null || true
    done
fi

if [[ "$DO_PULL" -eq 1 || "$DO_BUILD" -eq 0 ]]; then
    for img in multica-backend multica-web; do
        if ! pull_with_mirror "$img"; then
            echo "" >&2
            echo "ERROR: could not obtain ghcr.io/multica-ai/${img}:${TAG}" >&2
            echo "  Options:" >&2
            echo "    1. Set a working GHCR proxy in .env:  GHCR_MIRROR=<host>" >&2
            echo "    2. Pull from ghcr.io directly:        GHCR_MIRROR=" >&2
            echo "    3. Build from source:                 bash $0 --build" >&2
            exit 1
        fi
    done
fi

# ── 5. Start ────────────────────────────────────────────────────────────────
log "Starting the stack..."
docker compose up -d --remove-orphans

# ── 6. Health check ─────────────────────────────────────────────────────────
# Reads the published port back from Compose rather than assuming .env and the
# compose file agree — the same reasoning as upstream's scripts/selfhost-wait.sh.
backend_port=$(docker compose port backend 8080 2>/dev/null | tail -n 1)
backend_port=${backend_port##*:}
[[ "$backend_port" =~ ^[0-9]+$ ]] || backend_port=$BACKEND_PORT_DEFAULT
backend_url="http://localhost:${backend_port}"

log "Waiting for the backend to answer /health ..."
# --noproxy '*': a host-level http_proxy (e.g. a local Clash/Surge proxy) would
# otherwise intercept this loopback call and answer 502, making a healthy stack
# look broken. Scoped to this call; the caller's environment is not modified.
ok=0
for _ in $(seq 1 45); do
    if curl -sf --noproxy '*' "${backend_url}/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
done

echo ""
if [[ "$ok" -eq 1 ]]; then
    log "✓ Multica backend is up"
    if curl -sf --noproxy '*' "${backend_url}/readyz" 2>/dev/null; then
        echo ""
    else
        warn "/readyz did not answer yet (migrations may still be running)"
    fi
else
    warn "backend did not answer /health within 90s. Recent logs:"
    echo ""
    docker compose logs --tail 40 backend
    echo ""
    echo "Inspect with:  docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs -f backend"
fi

FRONTEND_PORT_VAL=$(env_val FRONTEND_PORT); FRONTEND_PORT_VAL=${FRONTEND_PORT_VAL:-3001}

cat <<EOF

=== Multica ===
  Frontend (direct) : http://localhost:${FRONTEND_PORT_VAL}
  Backend API       : ${backend_url}
  LAN entry point   : $(env_val FRONTEND_ORIGIN)   ← requires ../caddy to be running

Next steps:
  1. Start the reverse proxy (required for LAN + daemon API + WebSocket):
       bash ${SCRIPT_DIR}/../caddy/deploy.sh
  2. Log in — see README.md ("First login")
  3. On each DEVELOPMENT machine, install the multica CLI and point it here:
       multica setup self-host --server-url $(env_val MULTICA_DAEMON_SERVER_URL)
     This host runs no daemon by design; see README.md ("拓扑").
EOF