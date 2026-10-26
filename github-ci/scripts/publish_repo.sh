#!/bin/bash
# Publishes freshly built packages (DIST_DIR/*.pkg.tar.zst) as a complete,
# self-contained pacman repository on the git branch $PACKAGES_BRANCH
# (served via GitHub Pages) and leaves the db files in DIST_DIR for the
# release-upload step.
#
# CI usage (inside the workflow):
#   GH_TOKEN=<token> GH_REPO=<owner>/<repo> ./publish_repo.sh
#
# Local test usage (no push):
#   DIST_DIR=... LOCAL_REPO_DIR=/path/to/existing/checkout ./publish_repo.sh --no-push

set -e -u -o pipefail

DIST_DIR="${DIST_DIR:-dist}"
BRANCH="${PACKAGES_BRANCH:-packages}"
REPO_NAME="${REPO_NAME:-prince}"
NO_PUSH=false
for arg in "$@"; do
    case "$arg" in
        --no-push) NO_PUSH=true ;;
        *) echo "Usage: $0 [--no-push]" >&2; exit 1 ;;
    esac
done

[[ -d "$DIST_DIR" ]] || { echo "DIST_DIR '$DIST_DIR' does not exist" >&2; exit 1; }
# Absolute DIST_DIR so later cd's cannot break it; DIST_DIR is relative to cwd
DIST_DIR_ABS="$(cd "$DIST_DIR" && pwd)"
shopt -s nullglob
# absolute paths: the script cd's into the clone later, relative paths would break
pkgs=("$DIST_DIR_ABS"/*.pkg.tar.zst)
shopt -u nullglob
[[ ${#pkgs[@]} -gt 0 ]] || { echo "ERROR: No packages in $DIST_DIR; refusing to publish (empty build?)" >&2; exit 1; }

# ---- 1. Get a checkout of the packages branch ----
work="${LOCAL_REPO_DIR:-}"
if [[ -z "$work" ]]; then
    [[ -n "${GH_TOKEN:-}" && -n "${GH_REPO:-}" ]] || { echo "GH_TOKEN/GH_REPO not set and no LOCAL_REPO_DIR given" >&2; exit 1; }
    url="https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git"
    work="$(mktemp -d)"
    git_branch_exists="$(git ls-remote --heads "$url" "$BRANCH" | head -n1 || true)"
    if [[ -n "$git_branch_exists" ]]; then
        git clone --branch "$BRANCH" --single-branch --depth 1 "$url" "$work"
    else
        # First publication: create the branch from the default branch,
        # then wipe it.
        git clone --depth 1 "$url" "$work"
        ( cd "$work" \
            && git checkout --orphan "$BRANCH" \
            && find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + )
    fi
elif [[ ! -d "$work/.git" ]]; then
    # Fresh/empty local dir: just init it (no upstream)
    mkdir -p "$work"
    git init -q -b "$BRANCH" "$work"
fi

cd "$work"
if [[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$BRANCH" ]]; then
    git checkout -B "$BRANCH"
fi

# ---- 2. Replace superseded versions of the built pkgbases ----
declare -A bases_seen=()
for pkg in "${pkgs[@]}"; do
    base="$(bsdtar -xOf "$pkg" .PKGINFO | awk '$1 == "pkgbase" {print $3}')" || {
        echo "ERROR: bsdtar -xOf failed on $pkg (is bsdtar installed?)" >&2; exit 1; }
    [[ -n "$base" ]] || { echo "ERROR: could not read pkgbase from $pkg" >&2; exit 1; }
    bases_seen["$base"]=1
done
for base in "${!bases_seen[@]}"; do
    for old in ./"${base}"-*.pkg.tar.zst; do
        [[ -e "$old" ]] || continue
        name="$(basename "$old")"
        skip=false
        for pkg in "${pkgs[@]}"; do
            [[ "$(basename "$pkg")" == "$name" ]] && skip=true
        done
        if [[ "$skip" == false ]]; then
            echo "Removing superseded $name"
            rm -f "$old"
        fi
    done
done

# ---- 3. Copy in the new packages and (re)build the repo db ----
for pkg in "${pkgs[@]}"; do
    cp -f "$pkg" ./
done

repo-add --remove --quiet "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst

# repo-add creates '<repo>.db' / '<repo>.files' as *symlinks* to the .tar.gz
# files; replace them with real files so the branch is safe to serve over Pages.
rm -f "$REPO_NAME.db" "$REPO_NAME.files"
cp -f "$REPO_NAME.db.tar.gz" "$REPO_NAME.db"
cp -f "$REPO_NAME.files.tar.gz" "$REPO_NAME.files"
touch .nojekyll


# ---- 4. Mirror db files + checksums back into DIST_DIR for the release ----
cp -f "$REPO_NAME.db.tar.gz" "$REPO_NAME.files.tar.gz" "$DIST_DIR_ABS/"

(
    cd "$DIST_DIR_ABS" \
        && sha256sum *.pkg.tar.zst "$REPO_NAME.db.tar.gz" "$REPO_NAME.files.tar.gz" \
        > SHA256SUMS
)

rm -f "$REPO_NAME.db.tar.gz.old" "$REPO_NAME.files.tar.gz.old"

# ---- 5. Commit and push ----
git add -A .
if [[ -z "$(git status --porcelain)" ]]; then
    echo "Packages branch already up to date."
else
    git -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -m "Publish packages [skip ci]"
    if [[ "$NO_PUSH" == true ]]; then
        echo "--no-push: skipping push."
    else
        git push origin "HEAD:refs/heads/$BRANCH"
    fi
fi

echo "Published packages: "
echo "- Branch: $BRANCH ($(git rev-parse --short HEAD))"
