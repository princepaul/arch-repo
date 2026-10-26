# GitHub CI for this Arch package repo

Builds your `-git` packages on GitHub Actions whenever their upstream (Linux Mint
repos etc.) moves, publishes the built `.pkg.tar.zst` files to a rolling
`latest` GitHub Release **and** maintains a complete pacman repository
(packages + `prince.db` via `repo-add`) on the `packages` git branch, which you
serve through GitHub Pages and use directly in `/etc/pacman.conf`.

## Layout

```
github-ci/
├── (workflow copied to .github/workflows/build.yml at activation)
├── scripts/common.sh          -> shared PKGBUILD/URL/ref helpers
├── scripts/check_upstream.sh  -> upstream change detection + build list
├── scripts/build_ci.sh        -> CI variant of build_install.sh
├── scripts/publish_repo.sh    -> builds the pacman repo, commits the 'packages' branch
├── pull_release.sh            -> local mirror helper (optional, see below)
└── gitignore                  -> content for the repo root .gitignore
```

## Quick start (~5 min)

```bash
# From the repo root (this needs the directory to become a real git repo):
cp github-ci/gitignore .gitignore
mkdir -p .github/workflows
cp github-ci/workflows/build.yml .github/workflows/build.yml
git init && git add -A && git commit -m "Add GitHub Actions build workflow"
git remote add origin git@github.com:<user>/<repo>.git
git push -u origin main
```

Note: the currently-present `src/` dirs and built `*.pkg.tar.zst` files in the
package directories are ignored by the new `.gitignore`, so CI checkouts stay
clean.

## How it works

1. **check job** (every 6 h + manual dispatch): for each package in
   `build-order`, reads the upstream git URL from its PKGBUILD, compares the
   upstream `HEAD` with the ref stored in `.upstream/<pkg>` (an untracked-by-CI
   committed file that the build job updates only after a *successful* build,
   so failed packages are retried on the next run).
2. **build job** (`archlinux:base-devel` container): builds the changed package
   **plus its dependents** (everything after it in `build-order`), installs each
   built package into the container so later ones link against it, and runs
   `makepkg --force` so `dist/` always has fresh artifacts.
3. **publish** (two outputs from the same run):
   - `packages` git branch: a complete pacman repo (packages, `prince.db`,
     `prince.files`, purged of superseded versions). Served over GitHub Pages,
     this is what pacman consumes.
   - rolling `latest` release: packages + db files + `SHA256SUMS`, clobbered
     each successful run (backup/one-off download path).
4. **refs**: commits the new `.upstream/<pkg>` refs and pushes.

## Use the repo from pacman (recommended)

After the first successful build:

1. Enable Pages once: repo **Settings → Pages → Source: "Deploy from a
   branch" → Branch: `packages`, folder `/ (root)`**.
2. Add to `/etc/pacman.conf` (before the official cinnamon/kde entries if the
   order matters for you):

   ```
   [prince]
   SigLevel = Never
   Server = https://<your-user>.github.io/<repo-name>/
   ```

From then on this replaces the build half of `build_install.sh` completely —
new package versions show up with plain `pacman -Syu`. `build_install.sh`
(still fine for local building) and your existing `arch-repo/` repo are not
needed for these packages anymore; delete the `[prince]` local-repo entry only
if `arch-repo/` holds nothing else.

## Local one-off download (optional)

`pull_release.sh` mirrors the latest release into `arch-repo/` (moving previous
versions to `old_versions/`, verifying checksums, then running `repo_update`
and optionally `pacman -Syu`):

```bash
./github-ci/pull_release.sh --upgrade
```

Only useful if you prefer your existing `arch-repo/` over reaching GitHub
Pages directly.

## Manual triggers (Actions tab -> build-packages -> Run workflow)

- **package** = `nemo-git` -> builds that package + its build-order dependents.
- **force_all** = `true` -> full rebuild of the whole chain.
- Leave both empty -> normal upstream-change check.

## Notes / gotchas

- The **first run** has no stored refs in `.upstream/`, so every package is
  considered changed — expect one full build (~the whole chain) to bootstrap.
- A single `has_changes` run builds a *chain*, so an xapp change rebuilds the
  packages after xapp in build-order. True reverse-dependency tracking is more
  complexity than a cron workflow needs; build-order is your dependency policy.
- Packages using gpg-signed git sources or special keys may need keyring setup
  in the container — only relevant if one of these PKGBUILDs does.
- Large assets: mint-y-icons (~75 MB) etc. are fine as release assets (2 GB
  limit each) and as Pages blobs (100 MB Pages file limit; your largest is
  ~17 MB). Release storage is effectively unlimited; run artifacts expire.
- To stop the timer: Actions -> build-packages -> "..." -> Disable, and use
  manual dispatch while experimenting, so you don't trigger full runs.
- If a package's upstream repo URL can't be parsed from its PKGBUILD (check job
  prints a warning), add the URL explicitly to `scripts/common.sh:get_pkg_url`.
