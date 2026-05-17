#!/bin/bash
# Common utility functions for server-forge scripts.

set -euo pipefail

log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

die() {
    log_error "$@"
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root."
    fi
}

require_var() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        die "Required variable \$${var_name} is not set."
    fi
}

backup_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        local bak="${src}.bak.$(date '+%Y%m%d%H%M%S')"
        cp "$src" "$bak"
        log_info "Backed up $src -> $bak"
    fi
}
