#!/bin/bash
# Install packages for mac-mini-m4 (macOS / Apple Silicon).
#
# Append new dependencies as needed. Run as the normal user (Homebrew refuses to
# run as root):
#   bash nodes/mac-mini-m4/provision/install-packages.sh
#
# Homebrew must already be installed at /opt/homebrew (see README.md).

set -euo pipefail

BREW_PREFIX="/opt/homebrew"

if ! command -v brew &>/dev/null; then
    if [[ -x "${BREW_PREFIX}/bin/brew" ]]; then
        eval "$("${BREW_PREFIX}/bin/brew" shellenv)"
    else
        echo "ERROR: Homebrew not found. Install it first:" >&2
        echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
        exit 1
    fi
fi

echo "Installing formulae..."
brew install \
    git \
    node \
    uv \
    ripgrep \
    jq \
    direnv \
    ffmpeg

echo ""
echo "Installed. Run 'brew bundle dump' from this node's directory to refresh"
echo "a Brewfile if one is added later."
echo ""
echo "Done."