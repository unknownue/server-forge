# Multica agent runtime — daemon + DeepSeek Harness, containerised.
#
# Why the daemon lives in a container (and not on the host):
#   The daemon runs every task UNSANDBOXED — upstream is explicit that Multica
#   makes no filesystem guarantee, and that "if the daemon runs as your personal
#   user account, a run can read your SSH keys, edit your shell profile, and
#   delete your documents" (apps/docs/content/docs/security-model.mdx). The
#   container IS the isolation boundary, and this image is only half of it —
#   the mounts in docker-compose.yml are the other half.
#
# Why dsh is built here rather than installed from a registry:
#   Multica drives DSH over a versioned JSONL stdio protocol that is NOT part
#   of DSH itself. A bare `dsh` prints a version and still cannot run a task:
#   the protocol comes from the Multica runtime bundle, which is not published
#   to npm (multica#6936). So the bridge is built from source in this image.
#
# Layered so the expensive steps cache: system packages, then the two Node
# toolchains, then the bridge build, then the profiles.

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — fetch the Multica CLI
# ─────────────────────────────────────────────────────────────────────────────
# The CLI and the daemon are the same binary; `multica daemon start` is what
# this container exists to run. Pinned by tag so a rebuild is reproducible.
FROM debian:bookworm-slim AS cli

ARG TARGETARCH=arm64
ARG MULTICA_VERSION=v0.5.2
ARG GH_PROXY=""

# github.com is not reachable from every network this image is built on, while
# api.github.com usually is — measured on the machine that authored this file,
# `github.com:443` times out after 75s while `api.github.com` answers 200, so a
# plain releases/download URL fails every time.
#
# Three sources are therefore tried, cheapest and most portable first:
#   1. GH_PROXY + the normal release URL   — a mirror, for networks that have one
#   2. the Assets API, which redirects to a signed codeload URL and works when
#      github.com itself does not
#   3. the release URL directly            — for unrestricted networks
#
# The asset id is looked up from the tag at build time rather than hardcoded, so
# bumping MULTICA_VERSION does not also require editing an opaque number.
# fetch-cli.sh tries a mirror, then the GitHub Assets API, then the release URL
# directly — see that script for why each is needed.
#
# For a network with no GitHub access at all, pre-download the asset elsewhere
# and pass it in as a build context file:
#   docker compose build --build-arg LOCAL_CLI=multica-cli-0.5.2-linux-arm64.tar.gz
COPY fetch-cli.sh /usr/local/bin/fetch-cli.sh
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gzip; \
    rm -rf /var/lib/apt/lists/*; \
    chmod 0755 /usr/local/bin/fetch-cli.sh; \
    /usr/local/bin/fetch-cli.sh "${MULTICA_VERSION}" "${TARGETARCH}" /tmp/multica.tar.gz "${GH_PROXY}"; \
    gzip -t /tmp/multica.tar.gz; \
    tar -xzf /tmp/multica.tar.gz -C /tmp multica; \
    install -m 0755 /tmp/multica /usr/local/bin/multica; \
    /usr/local/bin/multica version

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — build the Multica DSH runtime bridge
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS bridge

RUN corepack enable && corepack prepare pnpm@latest --activate

WORKDIR /bridge

# Dependency manifests first: the lockfile is large and changes far less often
# than the sources, so this layer survives most edits.
COPY bridge/package.json bridge/pnpm-lock.yaml ./
COPY bridge/cordis.patch.yml ./
# package.json's "files" list names README.md, so npm pack fails without it and
# the runtime stage's COPY --from would miss it too.
COPY bridge/README.md ./
RUN pnpm install --frozen-lockfile

COPY bridge/tsconfig.json bridge/tsconfig.build.json ./
COPY bridge/src ./src
RUN pnpm build && test -f dist/index.js

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 — runtime
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim

# The bridge's engines field is ^22.19 || >=24, so bookworm's node:22 qualifies.

# Tools an agent actually needs when it runs a task. Deliberately includes git
# (the daemon creates a worktree per task and delivers results as a branch) and
# a compiler toolchain, because "install dependencies and run builds" is
# explicitly in scope for these agents.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssh-client \
        jq \
        less \
        procps \
        tini \
        ripgrep \
        build-essential \
        python3 \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    git config --system --add safe.directory '*'

RUN corepack enable && corepack prepare pnpm@latest --activate

# Global DSH, then the bridge installed into the `multica` profile below.
#
# The version is NOT free to bump. The bridge is validated against this exact
# DSH line, and its README says so:
#
#   "This checkout is currently validated against @deepseek-ai/dsh@0.1.0-rc.6
#    and its matching @deepseek-ai/dsh-* package family."
#
# Installing a NEWER dsh instead (0.1.5-rc.2, the version on the authoring
# machine) builds and probes fine but fails every task, because the bridge
# cannot acquire the session service across that API change:
#
#   multica-dsh-runtime: DSH session service is unavailable
#   {"type":"protocol_error","code":"STARTUP_FAILED", ...}
#
# The probe still reports protocol_version 1 in that state — it answers before
# boot completes — so a probe-only check does NOT catch it. See the smoke test
# at the end of this file, which is what actually does.
ARG DSH_VERSION=0.1.0-rc.6
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
 && dsh --version

# ── Multica CLI (also the daemon) ──
COPY --from=cli /usr/local/bin/multica /usr/local/bin/multica

# ── The bridge, as a packed tarball the profile can install ──
# `dsh plugin add` accepts a directory or a tarball. A packed tarball is used
# so the installed profile does not depend on /bridge existing at runtime.
COPY --from=bridge /bridge/dist /opt/multica-dsh-runtime/dist
COPY --from=bridge /bridge/package.json /bridge/cordis.patch.yml /bridge/README.md /opt/multica-dsh-runtime/
RUN cd /opt/multica-dsh-runtime \
 && npm pack --pack-destination /opt \
 && ls -l /opt/*.tgz

# ── Container-owned DSH_HOME ──
# This is the isolation mechanism. Multica resolves the profile store from
# DSH_HOME, falling back to ~/.dsh (server/internal/daemon/dsh_profile.go), and
# dsh uses the same variable. Pointing it at /dsh-home means everything this
# container does to DSH — profiles, plugins, sessions, skills — lands in the
# container filesystem and can never touch the developer's own ~/.dsh on the
# host, even when the repo is bind-mounted writable.
ENV DSH_HOME=/dsh-home
ENV MULTICA_HOME=/multica-home
ENV PATH="/dsh-home/bin:${PATH}"

# Install the Multica runtime profile into the container's DSH home at build
# time, so `dsh --profile multica --probe` succeeds on first start and the
# daemon registers the runtime without a provisioning round trip.
#
# Two things here are load-bearing and were both found by the smoke test below:
#
# 1. `@deepseek-ai/dsh-sandbox-local` is pinned to the SAME version as dsh.
#    dsh-base declares it as `^<version>`, so a floating range resolves to the
#    newest match — and newer releases of that package depend on
#    `@deepseek-ai/dsh-type-meta`, which is NOT published to npm (404). The
#    install then dies with ERR_PNPM_FETCH_404 and `dsh plugin add` rolls the
#    profile back, leaving a profile that probes fine and fails every task.
#    Pinning to the dsh version avoids that transitive edge entirely.
#
# 2. pnpm must be allowed to run koffi's build script. `dsh plugin add` shells
#    out to pnpm and a skipped build script makes pnpm exit non-zero
#    (ERR_PNPM_IGNORED_BUILDS), which rolls the install back the same way.
#
#    The key is `allowBuilds` as a MAPPING (`koffi: true`) in the profile's
#    pnpm-workspace.yaml — not `onlyBuiltDependencies`, and not a YAML list.
#    Both wrong forms fail differently and quietly: a list is rejected as
#    "unexpected event: expected mapping start", while the wrong key name is
#    simply ignored and the build stays blocked. DSH's own error text names the
#    right location: "add the exact key pnpm printed above under allowBuilds in
#    <profile>/pnpm-workspace.yaml".
ARG DSH_SANDBOX_VERSION=0.1.0-rc.6
RUN set -eux; \
    mkdir -p "$DSH_HOME" "$MULTICA_HOME"; \
    profile="${DSH_HOME}/profiles/multica"; \
    dsh plugin --profile multica --help >/dev/null 2>&1 || true; \
    mkdir -p "$profile"; \
    printf 'packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\nallowBuilds:\n  koffi: true\n' \
        > "${profile}/pnpm-workspace.yaml"; \
    bridge_tgz="$(ls /opt/multica-*.tgz | head -n1)"; \
    dsh plugin --profile multica add "$bridge_tgz"; \
    dsh plugin --profile multica add "@deepseek-ai/dsh-sandbox-local@${DSH_SANDBOX_VERSION}"; \
    test -d "${profile}/node_modules/@deepseek-ai/dsh-sandbox-local" \
      || { echo "ERROR: dsh-sandbox-local is missing from the profile"; exit 1; }; \
    dsh --profile multica --probe > /tmp/probe.jsonl 2>/dev/null || true; \
    grep -q '"protocol_version":1' /tmp/probe.jsonl \
      || { echo "ERROR: multica profile probe did not report protocol version 1"; cat /tmp/probe.jsonl; exit 1; }; \
    rm -f /tmp/probe.jsonl

# Smoke test — the check that actually matters.
#
# A profile that answers `--probe` has NOT necessarily booted: the bridge emits
# its probe frame before the plugin tree finishes loading, so `--probe` alone
# passes even when every task will fail. That is exactly how the sandbox
# problem above hid — `--probe` reported protocol_version 1 while `--stdio`
# answered STARTUP_FAILED.
#
# Driving one real stdio frame is what distinguishes the two. The prompt is
# never answered — there are no model credentials at build time and the run is
# expected to fail on that — so the assertion is narrow: the runtime must
# accept the frame, and must not answer STARTUP_FAILED.
RUN set -eux; \
    printf '%s\n' '{"v":1,"type":"execute","request_id":"smoke","cwd":"/tmp","prompt":"noop","mcp_servers":[]}' \
        | timeout 90 dsh --profile multica --stdio > /tmp/smoke.jsonl 2>/tmp/smoke.err || true; \
    cat /tmp/smoke.jsonl; \
    grep -q '"type":"ready"' /tmp/smoke.jsonl \
      || { echo "ERROR: the runtime never sent a ready frame"; cat /tmp/smoke.err; exit 1; }; \
    if grep -q 'STARTUP_FAILED' /tmp/smoke.jsonl; then \
        echo "ERROR: the runtime answered STARTUP_FAILED, so no task can run."; \
        echo "  This is the DSH version-mismatch signature: the bridge could not"; \
        echo "  acquire the session service. Check that DSH_VERSION matches the"; \
        echo "  version this bridge snapshot was validated against."; \
        grep -iE 'unavailable|failed to load' /tmp/smoke.err || true; \
        exit 1; \
    fi; \
    rm -f /tmp/smoke.jsonl /tmp/smoke.err

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# tini reaps the agent processes the daemon spawns. Without an init, finished
# agent CLIs accumulate as zombies and the daemon eventually refuses new work.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["daemon"]