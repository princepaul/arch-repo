#!/bin/bash
# Shared helpers for the CI scripts (sourced by check_upstream.sh and build_ci.sh).

# Read package directories from build-order, skipping blanks and comments.
read_build_order() {
    local file="${1:-build-order}"
    local line dir
    while IFS= read -r line || [[ -n "$line" ]]; do
        dir="$(echo "$line" | sed 's/#.*//' | xargs 2>/dev/null || true)"
        [[ -z "$dir" ]] && continue
        printf '%s\n' "$dir"
    done < "$file"
}

# Extract the upstream git URL for a package directory by parsing its PKGBUILD.
get_pkg_url() {
    local dir="$1"
    local url=""
    if [[ -f "$dir/PKGBUILD" ]]; then
        url="$(grep -m1 '^url=' "$dir/PKGBUILD" | cut -d= -f2- || true)"
        # Strip quotes and whitespace
        url="${url//\"/}"; url="${url//\'/}"; url="${url//[[:space:]]/}"
    fi
    # Fallback: look for a git+ source URL in the PKGBUILD
    if [[ -z "$url" ]]; then
        url="$(grep -m1 -o 'git+[^ ".][^ "#]*' "$dir/PKGBUILD" 2>/dev/null | sed 's/^git+//;s/\.git$//' || true)"
    fi
    # Expand bash variables like ${pkgname} / ${_pkgname} that some PKGBUILDs
    # leave unexpanded in the url= line.
    if [[ "$url" == *'$'* ]]; then
        local var_name
        var_name="$(echo "$url" | grep -oP '\$\{\K[A-Za-z_][A-Za-z0-9_]*(?=\})' | head -n1)"
        if [[ -n "$var_name" ]]; then
            local var_value
            var_value="$(grep -m1 "^${var_name}=" "$dir/PKGBUILD" | cut -d= -f2-)"
            var_value="${var_value//\"/}"; var_value="${var_value//\'/}"; var_value="${var_value//[[:space:]]/}"
            url="${var_value:+${url//\$\{${var_name}\}/${var_value}}}"
        fi
    fi

    printf '%s' "$url"
}

# Current HEAD commit hash of an upstream git repository.
get_head_ref() {
    local url="$1"
    git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}' | head -n1
}

# Last ref recorded for a package (empty if never built).
get_stored_ref() {
    local dir="$1"
    local file=".upstream/$(echo "$dir" | sed 's#/#_#g')"
    [[ -f "$file" ]] && cat "$file"
    true
}

# Record the current upstream ref for a package.
store_ref() {
    local dir="$1" ref="$2"
    mkdir -p .upstream
    echo "$ref" > ".upstream/$(echo "$dir" | sed 's#/#_#g')"
}
