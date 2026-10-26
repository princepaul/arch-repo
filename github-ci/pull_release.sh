#!/bin/bash
# Local helper: download packages from the rolling 'latest' GitHub release of
# your repo into arch-repo/ (replacing older versions), refresh the pacman db
# via repo_update, and optionally upgrade the system.
#
# Usage:  ./pull_release.sh [--upgrade]
# Requires: gh CLI, or curl+jq (fallback). Repo public => no token needed.

set -e -u -o pipefail

REPO_DIR="$(pwd)/arch-repo"
UPGRADE=false
for arg in "$@"; do
    case "$arg" in
        --upgrade) UPGRADE=true ;;
        *) echo "Usage: $0 [--upgrade]" >&2; exit 1 ;;
    esac
done

# Determine the GitHub repo slug from the origin remote (or GH_REPO env).
SLUG="${GH_REPO:-}"
if [[ -z "$SLUG" ]]; then
    SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@|https://)github.com[:/]##; s#\.git$##')"
fi
[[ -n "$SLUG" ]] || { echo "Could not determine GitHub repo (set GH_REPO or add an origin remote)" >&2; exit 1; }
echo "Pulling latest release from $SLUG ..."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if command -v gh >/dev/null 2>&1; then
    gh release download latest --repo "$SLUG" --dir "$tmp" --clobber --pattern '*.pkg.tar.zst' --pattern 'SHA256SUMS'
else
    echo "gh not found; falling back to curl+jq"
    api="https://api.github.com/repos/$SLUG/releases/latest"
    mapfile -t urls < <(curl -fsSL "$api" | jq -r '.assets[] | select(.name | test("\\.(pkg.tar.zst|SHA256SUMS)$")) | .browser_download_url')
    for u in "${urls[@]}"; do
        echo "Downloading $(basename "$u") ..."
        curl -fL -o "$tmp/$(basename "$u")" "$u"
    done
fi

# Verify checksums when present
if [[ -f "$tmp/SHA256SUMS" ]]; then
    echo "Verifying SHA256 checksums ..."
    (cd "$tmp" && sha256sum -c --ignore-missing SHA256SUMS)
fi

# Install into the local repo (same old_versions logic as build_install.sh)
if [[ ! -d "$REPO_DIR" ]]; then
    echo "Error: $REPO_DIR not found. Run this from the repo root." >&2
    exit 1
fi
mkdir -p "$REPO_DIR/old_versions"
for pkg in "$tmp"/*.pkg.tar.zst; do
    [[ -e "$pkg" ]] || { echo "No packages found in the latest release." >&2; exit 0; }
    name="$(basename "$pkg")"
    if [[ -f "$REPO_DIR/$name" ]]; then
        echo "Moving existing $name to old_versions/"
        mv "$REPO_DIR/$name" "$REPO_DIR/old_versions/"
    fi
    echo "Adding $name"
    cp -p "$pkg" "$REPO_DIR/"
done

# Refresh the pacman database
if [[ -x "$REPO_DIR/repo_update" ]]; then
    (cd "$REPO_DIR" && ./repo_update)
else
    echo "Warning: repo_update not found or not executable in $REPO_DIR."
fi

if [[ "$UPGRADE" == true ]]; then
    echo "Upgrading system packages ..."
    sudo pacman --noconfirm -Syu
fi

echo "pull_release.sh finished."
