#!/bin/bash
# Configure git user.name and user.email on this machine.
# Usage:
#   bash nodes/mac-mini-m4/config/set-git-config.sh <name> <email>
#   e.g. bash nodes/mac-mini-m4/config/set-git-config.sh "unknownue" "unknownue@outlook.com"

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: bash set-git-config.sh <name> <email>"
    echo ""
    echo "Current git config:"
    git config --global user.name 2>/dev/null || echo "  user.name: (not set)"
    git config --global user.email 2>/dev/null || echo "  user.email: (not set)"
    exit 1
fi

NAME="$1"
EMAIL="$2"

git config --global user.name "$NAME"
git config --global user.email "$EMAIL"

echo "Git config set:"
echo "  user.name  = $(git config --global user.name)"
echo "  user.email = $(git config --global user.email)"