#!/bin/bash
# CI change detection: compares each build-order package's upstream git HEAD
# with the ref recorded in .upstream/<pkg>, then computes the build list.
#
# "Changed package + its dependents": everything from the earliest changed
# package onward in build-order is included (packages later in build-order
# depend on earlier ones).
#
# Inputs (env):
#   FORCE_ALL=true        -> include every build-order package
#   SINGLE_PACKAGE=<dir>  -> include that package plus its dependents
#   EVENT_NAME / GITHUB_EVENT_NAME + (push) BEFORE_SHA/CURRENT_SHA ->
#                           rebuild from the earliest locally-changed
#                           package's position on push commits.
#   CHANGED_PATHS (optional, newline list) -> override push diff paths.
#
# Outputs:
#   stdout: build list (one dir per line), or "all" when building everything,
#           or nothing when there is nothing to do.
#   $GITHUB_OUTPUT: has_changes / packages (heredoc)
#   $GITHUB_STEP_SUMMARY: human-readable summary

set -e -u -o pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

[[ -f "build-order" ]] || { echo "build-order not found; run from repo root" >&2; exit 1; }

mapfile -t all_pkgs < <(read_build_order)
[[ ${#all_pkgs[@]} -gt 0 ]] || { echo "No packages in build-order" >&2; exit 1; }

# ---- Local (push-driven) changes: package directories touched in this push ----
local_changed_dirs=()
local_force_all=false
_event="${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
_paths="${CHANGED_PATHS:-}"

if [[ -z "$_paths" && "$_event" == "push" ]]; then
    _before="${BEFORE_SHA:-${GITHUB_EVENT_BEFORE:-}}"
    _cur="${CURRENT_SHA:-${GITHUB_SHA:-HEAD}}"
    if [[ -n "$_before" && "$_before" != "0000000000000000000000000000000000000000" ]]; then
        _paths="$(git diff --name-only "$_before" "$_cur" 2>/dev/null || true)"
    elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        _paths="$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)"
    fi
fi

if [[ -n "$_paths" ]]; then
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        case "$p" in
            build-order) local_force_all=true ;;
            github-ci/scripts/*|github-ci/common.sh|github-ci/shims/*) local_force_all=true ;;
            .upstream/*) ;;  # ref bookkeeping, never a reason to rebuild
            *)
                dir="${p%%/*}"
                if [[ -d "$dir" && -f "$dir/PKGBUILD" ]]; then
                    local_changed_dirs+=("$dir")
                fi
                ;;
        esac
    done <<< "$_paths"
fi

changed=()
declared_ref=""
for dir in "${all_pkgs[@]}"; do
    [[ -f "$dir/PKGBUILD" ]] || { echo "Warning: $dir in build-order has no PKGBUILD, skipping" >&2; continue; }
    url="$(get_pkg_url "$dir")"
    if [[ -z "$url" ]]; then
        echo "Warning: could not determine upstream URL for $dir" >&2
        continue
    fi
    declared_ref="$(get_head_ref "$url")"
    [[ -n "$declared_ref" ]] || { echo "Warning: git ls-remote failed for $dir ($url)" >&2; continue; }

    stored="$(get_stored_ref "$dir")"
    if [[ -z "$stored" || "$stored" != "$declared_ref" ]]; then
        changed+=("$dir")
    fi
done

# ---- Combine FORCE_ALL ----
force_all=false
[[ "${FORCE_ALL:-false}" == "true" ]] && force_all=true
[[ "$local_force_all" == "true" ]] && force_all=true

# ---- Compute the include list ----
include=()
if [[ "$force_all" == "true" ]]; then
    include=("${all_pkgs[@]}")
elif [[ -n "${SINGLE_PACKAGE:-}" ]]; then
    # Manual dispatch: comma/space separated package list -> build exactly
    # these (the old single-name behavior of including the whole build-order
    # tail can still be had by using force_all or by passing one name while
    # the others are considered done).
    declare -A wanted=()
    for w in ${SINGLE_PACKAGE//,/ }; do
        wanted["$w"]=1
    done
    for dir in "${all_pkgs[@]}"; do
        [[ -n "${wanted[$dir]:-}" ]] && include+=("$dir")
    done
    if [[ ${#include[@]} -ne ${#wanted[@]} ]]; then
        for w in "${!wanted[@]}"; do
            known=false
            for dir in "${all_pkgs[@]}"; do [[ "$dir" == "$w" ]] && known=true && break; done
            [[ "$known" == false ]] && { echo "Package '$w' not found in build-order" >&2; exit 1; }
        done
    fi
elif [[ ${#changed[@]} -gt 0 || ${#local_changed_dirs[@]} -gt 0 ]]; then
    # Build only the packages that actually changed. Ordering is still taken
    # from build-order, so dependencies are processed in the correct sequence.
    for dir in "${all_pkgs[@]}"; do
        is_changed=false
        for c in "${changed[@]:-}"; do
            [[ "$dir" == "$c" ]] && is_changed=true && break
        done
        if [[ "$is_changed" == false ]]; then
            for d in "${local_changed_dirs[@]:-}"; do
                [[ "$dir" == "$d" ]] && is_changed=true && break
            done
        fi
        [[ "$is_changed" == true ]] && include+=("$dir")
    done
fi

# ---- Emit outputs ----
has_changes=false
[[ ${#include[@]} -gt 0 ]] && has_changes=true

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "has_changes=$has_changes"
        if [[ ${#include[@]} -gt 0 ]]; then
            if [[ "$force_all" == "true" ]]; then
                echo "packages=all"
            else
                echo "packages<<EOF"
                printf '%s\n' "${include[@]}"
                echo "EOF"
            fi
        fi
    } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Upstream check"
        echo ""
        if [[ ${#changed[@]} -eq 0 ]]; then
            echo "- No upstream repositories changed."
        else
            echo "- Upstream changed:"
            for c in "${changed[@]}"; do echo "  - \`$c\`"; done
        fi
        if [[ ${#local_changed_dirs[@]} -gt 0 ]]; then
            echo "- Local push changed:"
            printf '  - `%s`\n' "${local_changed_dirs[@]}"
        fi
        if [[ "$local_force_all" == "true" ]]; then
            echo "- Local infra/build-order change -> full rebuild."
        fi
        if [[ ${#include[@]} -gt 0 ]]; then
            echo "- Build list (${#include[@]}):"
            for d in "${include[@]}"; do echo "  - \`$d\`"; done
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi

# stdout for humans / local use
if [[ "$force_all" == "true" ]]; then
    echo "all"
else
    for d in "${include[@]:-}"; do echo "$d"; done
fi
