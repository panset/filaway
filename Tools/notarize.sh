#!/usr/bin/env bash
# Signs with Developer ID, submits the DMG to Apple's notary service, staples
# the ticket and proves the result with spctl.
#
# Everything here is BLOCKED until the user enrols in the Apple Developer
# Program and installs Xcode (plan §8). Each precondition is checked up front so
# the failure is a clear "BLOCKED: ..." line rather than an obscure tool error.
#
# Two ways to authenticate, in this order:
#   1. App Store Connect API key — NOTARY_KEY_ID + NOTARY_ISSUER_ID +
#      NOTARY_KEY_P8 (a path, or the PEM text itself). What CI uses: no keychain
#      and no app-specific password involved.
#   2. A notarytool keychain profile — $NOTARY_PROFILE, default "filaway-notary",
#      created once with `xcrun notarytool store-credentials`. What a developer
#      machine uses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=Tools/lib.sh
. "${ROOT}/Tools/lib.sh"
filaway_load_release_env "$ROOT"

APP_NAME="Filaway"
VERSION="$(filaway_short_version "$ROOT")"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"
[[ -f "$DMG" ]] || DMG="build/${APP_NAME}.dmg"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-${FILAWAY_NOTARY_PROFILE:-filaway-notary}}"

blocked() {
    echo "BLOCKED: $1" >&2
    [[ $# -gt 1 ]] && echo "         $2" >&2
    exit 1
}

# --- Preconditions -----------------------------------------------------------
[[ -d "$APP" ]] || blocked "${APP} not found." "Run 'make app' first."
[[ -f "$DMG" ]] || blocked "${DMG} not found." "Run 'make dmg' first."

command -v xcrun >/dev/null 2>&1 || blocked "xcrun not found." "Install the Xcode Command Line Tools."

xcrun --find notarytool >/dev/null 2>&1 \
    || blocked "notarytool is unavailable in the active developer directory." \
               "Install Xcode.app and run: sudo xcode-select -s /Applications/Xcode.app"

xcrun --find stapler >/dev/null 2>&1 \
    || blocked "stapler is unavailable (it ships with Xcode.app, not the Command Line Tools)." \
               "Install Xcode.app and run: sudo xcode-select -s /Applications/Xcode.app"

IDENTITY="$(filaway_signing_identity)"
[[ -n "$IDENTITY" ]] \
    || blocked "no 'Developer ID Application' certificate in the keychain." \
               "Enrol at developer.apple.com (\$99/yr), then create the certificate in Xcode > Settings > Accounts. Override with \$DEVELOPER_ID."

# Assemble the notarytool credential arguments once; every later call reuses them.
NOTARY_ARGS=()
CLEANUP_P8=""
cleanup() { [[ -n "$CLEANUP_P8" ]] && rm -f "$CLEANUP_P8"; }
trap cleanup EXIT

if [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -n "${NOTARY_KEY_P8:-}" ]]; then
    if [[ -f "$NOTARY_KEY_P8" ]]; then
        P8_PATH="$NOTARY_KEY_P8"
    else
        # The secret holds the PEM text, not a path. Write it to a private temp
        # file that the EXIT trap removes even if notarytool fails.
        CLEANUP_P8="$(mktemp -t filaway-notary-XXXXXX.p8)"
        chmod 600 "$CLEANUP_P8"
        printf '%s\n' "$NOTARY_KEY_P8" > "$CLEANUP_P8"
        P8_PATH="$CLEANUP_P8"
    fi
    NOTARY_ARGS=(--key "$P8_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    note "Notarizing with the App Store Connect API key ${NOTARY_KEY_ID}."
else
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
        || blocked "no notary credentials." \
                   "Either set NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY_P8, or run: xcrun notarytool store-credentials \"${KEYCHAIN_PROFILE}\" --apple-id <id> --team-id <team> --password <app-specific-password>"
    NOTARY_ARGS=(--keychain-profile "$KEYCHAIN_PROFILE")
    note "Notarizing with the keychain profile '${KEYCHAIN_PROFILE}'."
fi

# --- Sign with hardened runtime ---------------------------------------------
# Tools/make_app.sh already signs with $DEVELOPER_ID when it can see one. Re-run
# it rather than re-signing here, so there is exactly one place that knows the
# inner-out order and the entitlements file.
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
    note "${APP} is not hardened; rebuilding it with the Developer ID..."
    DEVELOPER_ID="$IDENTITY" Tools/make_app.sh
    DEVELOPER_ID="$IDENTITY" Tools/make_dmg.sh
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Notarize and staple -----------------------------------------------------
note "Submitting ${DMG} to the notary service (this can take several minutes)..."
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait

note "Stapling..."
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

# The actual proof that a clean Mac will open it: Gatekeeper's own verdict.
echo "--- spctl ---"
spctl -a -vv -t install "$DMG"
spctl -a -vv -t exec "$APP"
echo "Notarized and stapled: ${DMG}"
