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

# ---- 0. Stray-package guard ----
# Only packages produced by the build-order sources may ever enter the repo.
# Any .pkg.tar.zst not belonging to a build-order PKGBUILD (e.g. dropped on
# the packages branch by hand) must not silently reach pacman users.
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
[[ -f "$REPO_ROOT/build-order" ]] || { echo "ERROR: build-order not found at $REPO_ROOT" >&2; exit 1; }
declare -A allowed_base=()
while IFS= read -r dir; do
    [[ -f "$REPO_ROOT/$dir/PKGBUILD" ]] || continue
    # PKGBUILDs are sourced in a subshell exactly like makepkg does; only the
    # variable definitions are needed (pkgname may be a scalar or an array).
    for bn in $( (source "$REPO_ROOT/$dir/PKGBUILD" \
                  && echo "${pkgname[*]}") 2>/dev/null ); do
        allowed_base["$bn"]=1
    done
done < <(while IFS= read -r bl; do
             d="$(echo "$bl" | sed 's/#.*//' | xargs 2>/dev/null || true)"
             [[ -n "$d" ]] && printf '%s\n' "$d"
         done < "$REPO_ROOT/build-order")
strays=()
for pkg in "${pkgs[@]}"; do
    base="$(bsdtar -xOf "$pkg" .PKGINFO | awk '$1 == "pkgbase" {print $3}')" || base=""
    if [[ -z "$base" ]]; then
        strays+=("$(basename "$pkg") (unreadable/empty pkgbase - not a valid package?)")
    elif [[ -z "${allowed_base[$base]:-}" ]]; then
        strays+=("$(basename "$pkg") (pkgbase='$base')")
    fi
done
if [[ ${#strays[@]} -gt 0 ]]; then
    echo "ERROR: refusing to publish unapproved package file(s) in $DIST_DIR:" >&2
    printf '  %s\n' "${strays[@]}" >&2
    echo "These bases are not produced by any build-order PKGBUILD. A stray/" >&2
    echo "tampered artifact found its way into the DIST_DIR or DIST_DIR itself" >&2
    echo "was pointed at the wrong directory. Aborting (nothing published)." >&2
    exit 1
fi

# ---- 1. Get a checkout of the packages branch ----
work="${LOCAL_REPO_DIR:-}"
if [[ -z "$work" ]]; then
    [[ -n "${GH_TOKEN:-}" && -n "${GH_REPO:-}" ]] || { echo "GH_TOKEN/GH_REPO not set and no LOCAL_REPO_DIR given" >&2; exit 1; }
    # Clone anonymously: the repo is public, and the read side needs no
    # credentials. Auth is applied per-push (below) via a one-shot header so
    # the token is never written to disk in the clone's .git/config.
    anon="https://github.com/${GH_REPO}.git"
    work="$(mktemp -d)"
    git_branch_exists="$(git ls-remote --heads "$anon" "$BRANCH" | head -n1 || true)"
    if [[ -n "$git_branch_exists" ]]; then
        git clone --branch "$BRANCH" --single-branch --depth 1 "$anon" "$work"
    else
        # First publication: create the branch from the default branch,
        # then wipe it.
        git clone --depth 1 "$anon" "$work"
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

# (Re)build the repo db from scratch: the db is a pure projection of the
# package files present, so this is rename-safe (a renamed pkgbase leaves no
# ghost entry) and removal-safe (a package dropped from build-order vanishes).
rm -f "$REPO_NAME.db.tar.gz" "$REPO_NAME.files.tar.gz"
repo-add --quiet "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst

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

# ---- 4b. Generate index.html (human-readable repo landing page) ----
rows_tmp="$(mktemp)"
for pkgfile in ./*.pkg.tar.zst; do
    bsdtar -xOf "$pkgfile" .PKGINFO \
        | awk -F' = ' '
            $1=="pkgname"    {name=$2}
            $1=="pkgver"     {ver=$2}
            $1=="pkgdesc"    {desc=$2}
            $1=="pkgbase"    {base=$2}
            END {
                printf "%s\t%s\t%s\n",
                    name, ver, (desc=="" ? (base=="" ? name : base) : desc)
            }' \
        >> "$rows_tmp"
done
sort -u "$rows_tmp" -o "$rows_tmp"

{
    printf '%s\n' \
        '<!DOCTYPE html>' \
        '<html lang="en"><head><meta charset="utf-8">' \
        '<meta name="viewport" content="width=device-width, initial-scale=1">' \
        '<title>[prince] pacman repository</title>' \
        '<style>' \
        'body{font-family:ui-monospace,Menlo,Consolas,monospace;max-width:960px;margin:2rem auto;padding:0 1rem;color:#1b1f24;background:#f6f8fa}' \
        'h1{font-size:1.3rem}h1 code{background:#dbe5f2;padding:.2em .4em;border-radius:4px}' \
        'code,pre{background:#eff2f5;border-radius:4px;padding:.15em .35em}' \
        'pre{padding:1em;overflow-x:auto;line-height:1.45}' \
        'table{border-collapse:collapse;width:100%;background:#fff;font-size:.9rem}' \
        'th,td{border:1px solid #d0d7de;padding:.35rem .6rem;text-align:left}' \
        'th{background:#dbe5f2}td:nth-child(2){white-space:nowrap}' \
        'footer{margin-top:1.5rem;color:#57606a;font-size:.8rem}' \
        '</style></head><body>' \
        '<h1>Arch user repository <code>[prince]</code></h1>' \
        '<p>Personal pacman repository (git/AUR-style builds of the Cinnamon stack and friends), served via GitHub Pages.</p>' \
        '<h2>Usage</h2>' \
        '<p>Add the following to <code>/etc/pacman.conf</code>:</p>' \
        '<pre>[prince]' \
        'SigLevel = Never' \
        'Server = https://princepaul.github.io/arch-repo/</pre>' \
        '<p>Then run <code>pacman -Syu</code> and install packages as usual.</p>' \
        '<h2>Packages</h2>'
    } > index.html

awk -F'\t' '
    BEGIN {
        print "<table><tr><th>#</th><th>Package</th><th>Version</th><th>Description</th></tr>"
        n=0
    }
    {
        n++
        printf "<tr><td>%d</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", n, $1, $2, $3
    }
    END {
        print "</table>"
        printf "<footer>Generated %s UTC &middot; %d packages &middot; repository db: <a href=\"prince.db\">prince.db</a></footer>\n", strftime("%Y-%m-%d %H:%M"), n
    }' "$rows_tmp" >> index.html

if grep -q '<table>' index.html && grep -q '</table>' index.html; then
    echo "index.html generated: $(grep -c '<tr>' index.html) rows"
else
    echo "ERROR: index.html generation failed" >&2
    exit 1
fi
rm -f "$rows_tmp"

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
        # Auth per-command via header: the token never lands in .git/config
        # (the clone was done anonymously; this remote carries no credentials).
        AUTH="$(printf 'x-access-token:%s' "${GH_TOKEN:-}" | base64 -w0)"
        git -c "http.extraHeader=Authorization: Basic $AUTH" \
            push origin "HEAD:refs/heads/$BRANCH"
    fi
fi

echo "Published packages: "
echo "- Branch: $BRANCH ($(git rev-parse --short HEAD))"
