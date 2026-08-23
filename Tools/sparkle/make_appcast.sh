#!/usr/bin/env bash
# Generates build/releases/appcast.xml (and delta updates) from the DMGs in
# build/releases/, signing every new entry with the EdDSA private key.
#
#     Tools/sparkle/make_appcast.sh                 # stage build/Filaway-<v>.dmg, regenerate
#     Tools/sparkle/make_appcast.sh --no-stage      # use whatever is already in build/releases
#
# Where the private key comes from:
#   * $SPARKLE_PRIVATE_KEY set (CI)  -> piped in via `--ed-key-file -`, never
#                                       written to disk
#   * otherwise                      -> the login Keychain, where
#                                       Tools/sparkle/generate_keys.sh put it
#
# build/releases/ is the accumulating archive Sparkle wants: keeping the last
# few DMGs there is what lets generate_appcast build binary deltas, so an update
# is a few MB instead of 66. It is gitignored — the DMGs live on the GitHub
# Release, and `Tools/release.sh` re-downloads recent ones when it can.
#
# The download URL prefix is per-release on purpose. GitHub Releases put assets
# under .../releases/download/<tag>/, so each run passes its own tag's prefix;
# generate_appcast only applies it to *new* items and leaves the URLs of
# existing entries alone, which is exactly what is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=Tools/lib.sh
. "${ROOT}/Tools/lib.sh"
filaway_load_release_env "$ROOT"

STAGE_DMG=1
[[ "${1:-}" == "--no-stage" ]] && STAGE_DMG=0

APP_NAME="Filaway"
VERSION="$(filaway_short_version "$ROOT")"
RELEASES="${ROOT}/build/releases"
APPCAST="${RELEASES}/appcast.xml"

BIN_DIR="$(filaway_sparkle_bin_dir "$ROOT" || true)"
[[ -n "$BIN_DIR" ]] || {
    echo "ERROR: Sparkle's generate_appcast is not unpacked. Run 'swift build' first." >&2
    exit 1
}

mkdir -p "$RELEASES"

if [[ $STAGE_DMG -eq 1 ]]; then
    DMG="${ROOT}/build/${APP_NAME}-${VERSION}.dmg"
    [[ -f "$DMG" ]] || { echo "ERROR: ${DMG} not found. Run 'make dmg' first." >&2; exit 1; }
    cp -f "$DMG" "${RELEASES}/"
    # Release notes, if someone wrote any. Sparkle matches them by filename.
    for ext in html md txt; do
        src="${ROOT}/docs/release-notes/${VERSION}.${ext}"
        [[ -f "$src" ]] && cp -f "$src" "${RELEASES}/${APP_NAME}-${VERSION}.${ext}"
    done
fi

# Repository slug, for the download prefix and the product link.
REPO="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPO" ]]; then
    origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
    REPO="$(sed -E 's#^.*github\.com[:/]##; s#\.git$##' <<<"$origin")"
fi
[[ -n "$REPO" ]] || { echo "ERROR: cannot determine the GitHub repo. Set GITHUB_REPOSITORY." >&2; exit 1; }

PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/${REPO}/releases/download/v${VERSION}/}"

ARGS=(
    --download-url-prefix "$PREFIX"
    --link "https://github.com/${REPO}"
    --maximum-versions 5
    --maximum-deltas 3
    -o "$APPCAST"
)

note "Generating ${APPCAST}"
note "  download prefix: ${PREFIX}"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    note "  signing key:     \$SPARKLE_PRIVATE_KEY (stdin)"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "${BIN_DIR}/generate_appcast" --ed-key-file - "${ARGS[@]}" "$RELEASES"
else
    note "  signing key:     login Keychain (account 'ed25519')"
    if ! "${BIN_DIR}/generate_appcast" "${ARGS[@]}" "$RELEASES"; then
        echo "BLOCKED: generate_appcast could not sign the update." >&2
        echo "         No EdDSA private key in the Keychain and \$SPARKLE_PRIVATE_KEY is unset." >&2
        echo "         Run Tools/sparkle/generate_keys.sh once (docs/release.md)." >&2
        exit 1
    fi
fi

echo "Wrote ${APPCAST}"
grep -o 'sparkle:edSignature="[^"]\{0,12\}' "$APPCAST" | sed 's/^/  signed: /' | head -5 || true
