#!/bin/bash
# Download nvidia-container-toolkit .deb packages.
# Sources from raw.githubusercontent.com fallback to listing URL if unreachable.
# Usage: bash download-nvidia-ctk-debs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_DIR="$SCRIPT_DIR/nvidia-ctk-debs"
BASE_URL="https://raw.githubusercontent.com/NVIDIA/libnvidia-container/gh-pages/stable/deb/amd64"
PACKAGES=(
    "libnvidia-container1"
    "libnvidia-container-tools"
    "nvidia-container-toolkit-base"
    "nvidia-container-toolkit"
)

echo "=== Downloading nvidia-container-toolkit .deb packages ==="
echo "Target directory: $DEB_DIR"
echo ""

mkdir -p "$DEB_DIR"

download_url() {
    local url="$1" out="$2"
    echo "  GET $url"
    curl -fSL --connect-timeout 15 --retry 3 --retry-delay 5 \
        -o "$out" "$url"
}

# Fetch Packages file to get latest versions
echo "[1/2] Fetching package versions..."
PACKAGES_RAW="$(mktemp)"

if ! curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 5 \
    "$BASE_URL/Packages" -o "$PACKAGES_RAW" 2>/dev/null; then
    rm -f "$PACKAGES_RAW"
    echo "" >&2
    echo "ERROR: $BASE_URL unreachable." >&2
    echo "" >&2
    echo "Manual download required — open in browser:" >&2
    echo "  https://github.com/NVIDIA/libnvidia-container/tree/gh-pages/stable/deb/amd64" >&2
    echo "" >&2
    echo "Download these 4 files into: $DEB_DIR" >&2
    echo "" >&2
    for pkg in "${PACKAGES[@]}"; do
        echo "  ${pkg}_<version>_amd64.deb" >&2
    done
    exit 1
fi

declare -A VERSIONS
for pkg in "${PACKAGES[@]}"; do
    ver=$(awk -v pkg="$pkg" '
        /^Package: / { found = ($2 == pkg) }
        found && /^Version: / { print $2; found = 0 }
    ' "$PACKAGES_RAW" | sort -V | tail -1)
    if [[ -z "$ver" ]]; then
        echo "ERROR: Failed to find version for $pkg" >&2
        rm -f "$PACKAGES_RAW"
        exit 1
    fi
    VERSIONS[$pkg]="$ver"
    echo "  $pkg -> $ver"
done
rm -f "$PACKAGES_RAW"

# Download .deb files
echo ""
echo "[2/2] Downloading .deb packages..."

ok=true
for pkg in "${PACKAGES[@]}"; do
    ver="${VERSIONS[$pkg]}"
    deb="${pkg}_${ver}_amd64.deb"
    dest="$DEB_DIR/$deb"

    if [[ -f "$dest" ]]; then
        echo "  $deb (already exists, skip)"
        continue
    fi

    if download_url "$BASE_URL/$deb" "$dest"; then
        echo "    -> downloaded"
    else
        echo "    -> FAILED" >&2
        ok=false
    fi
done

if $ok; then
    echo ""
    echo "All packages downloaded. Run:"
    echo "  sudo bash install-nvidia-ctk.sh"
else
    echo "" >&2
    echo "Some downloads failed. Retry, or download the missing files from:" >&2
    echo "  https://github.com/NVIDIA/libnvidia-container/tree/gh-pages/stable/deb/amd64" >&2
    exit 1
fi
