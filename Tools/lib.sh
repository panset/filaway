#!/usr/bin/env bash
# Shared helpers for Tools/*.sh — version numbers, release.env, Sparkle paths,
# signing identity. Sourced, never executed:
#
#     ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#     . "${ROOT}/Tools/lib.sh"
#
# Nothing here echoes to stdout unless asked; helpers print to stderr so a
# `$(...)` capture stays clean.

# shellcheck disable=SC2034

filaway_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

note() { echo "$*" >&2; }
warn() { echo "WARNING: $*" >&2; }

# --- release.env -------------------------------------------------------------
# Untracked, gitignored, one `KEY=value` per line. Holds the values that differ
# between "this developer's machine" and CI:
#
#     DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#     SPARKLE_PUBLIC_KEY="base64…"          # goes into Info.plist SUPublicEDKey
#     NOTARY_PROFILE="filaway-notary"
#     SUFEED_URL="https://…/appcast.xml"
#
# Environment variables already set win over the file, so CI can export secrets
# without writing one. See Tools/release.env.example and docs/release.md.
filaway_load_release_env() {
    local root="${1:-$(filaway_root)}"
    local file="${root}/Tools/release.env"
    [[ -f "$file" ]] || return 0
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="$(echo "$key" | tr -d '[:space:]')"
        # Strip one layer of matching quotes.
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        [[ -n "${!key-}" ]] && continue   # already exported: environment wins
        export "${key}=${value}"
    done < "$file"
}

# --- Versions ----------------------------------------------------------------
# CFBundleShortVersionString. Precedence:
#   1. $FILAWAY_VERSION            (what `make release VERSION=x.y.z` sets)
#   2. an exact `v*` git tag on HEAD, with the leading `v` dropped
#   3. the VERSION file
# A dirty tree or a commit past the tag falls through to VERSION, so a local
# build never claims to be the tagged release.
filaway_short_version() {
    local root="${1:-$(filaway_root)}"
    if [[ -n "${FILAWAY_VERSION:-}" ]]; then
        echo "${FILAWAY_VERSION#v}"
        return
    fi
    local tag
    tag="$(git -C "$root" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
    if [[ -n "$tag" ]]; then
        echo "${tag#v}"
        return
    fi
    tr -d '[:space:]' < "${root}/VERSION"
}

# CFBundleVersion — the number Sparkle compares to decide "is this newer?".
# It must increase monotonically and never repeat, which rules out the marketing
# version (0.1.0 can ship twice as 0.1.0+hotfix) and rules out a timestamp (not
# reproducible). The commit count is both, and is derivable from any checkout.
filaway_build_version() {
    local root="${1:-$(filaway_root)}"
    git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1
}

# --- Sparkle -----------------------------------------------------------------
# `swift build` copies Sparkle.framework beside the executable and unpacks the
# whole distribution — including bin/generate_keys, bin/sign_update,
# bin/generate_appcast, bin/BinaryDelta — into .build/artifacts. Nothing extra
# has to be downloaded; `swift package resolve` is the fetch step (ADR-041).
filaway_sparkle_artifact_root() {
    local root="${1:-$(filaway_root)}"
    local dir
    for dir in "${root}"/.build/artifacts/sparkle/Sparkle "${root}"/.build/artifacts/*/Sparkle; do
        [[ -d "$dir" ]] && { echo "$dir"; return 0; }
    done
    return 1
}

filaway_sparkle_bin_dir() {
    local artifact
    artifact="$(filaway_sparkle_artifact_root "${1:-}")" || return 1
    [[ -d "${artifact}/bin" ]] || return 1
    echo "${artifact}/bin"
}

# The framework to embed. Prefer the copy SwiftPM staged next to the binary
# (that is the one the executable was linked against); fall back to the
# xcframework slice, which is what a universal build under Xcode leaves behind.
filaway_sparkle_framework() {
    local root="${1:-$(filaway_root)}"
    local bin_dir="${2:-}"
    if [[ -n "$bin_dir" && -d "${bin_dir}/Sparkle.framework" ]]; then
        echo "${bin_dir}/Sparkle.framework"
        return 0
    fi
    local artifact slice
    artifact="$(filaway_sparkle_artifact_root "$root")" || return 1
    for slice in "${artifact}"/Sparkle.xcframework/macos-*/Sparkle.framework; do
        [[ -d "$slice" ]] && { echo "$slice"; return 0; }
    done
    return 1
}

# --- Signing -----------------------------------------------------------------
# Echoes a Developer ID Application identity, or nothing at all. Precedence:
# $DEVELOPER_ID, then the legacy $FILAWAY_SIGNING_IDENTITY, then the first such
# certificate in the keychain.
filaway_signing_identity() {
    if [[ -n "${DEVELOPER_ID:-}" ]]; then
        echo "$DEVELOPER_ID"
        return 0
    fi
    if [[ -n "${FILAWAY_SIGNING_IDENTITY:-}" ]]; then
        echo "$FILAWAY_SIGNING_IDENTITY"
        return 0
    fi
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true
}
