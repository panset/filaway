#!/usr/bin/env bash
# Signs with Developer ID, submits build/Filaway.dmg to Apple's notary service
# and staples the ticket.
#
# Everything here is BLOCKED until the user enrols in the Apple Developer
# Program and installs Xcode (plan §8). Each precondition is checked up front so
# the failure is a clear "BLOCKED: ..." line rather than an obscure tool error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Filaway"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}.dmg"
KEYCHAIN_PROFILE="${FILAWAY_NOTARY_PROFILE:-filaway-notary}"

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

IDENTITY="${FILAWAY_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)"
fi
[[ -n "$IDENTITY" ]] \
    || blocked "no 'Developer ID Application' certificate in the keychain." \
               "Enrol at developer.apple.com (\$99/yr), then create the certificate in Xcode > Settings > Accounts. Override with FILAWAY_SIGNING_IDENTITY."

xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    || blocked "notary keychain profile '${KEYCHAIN_PROFILE}' is missing or invalid." \
               "Create it with: xcrun notarytool store-credentials \"${KEYCHAIN_PROFILE}\" --apple-id <id> --team-id <team> --password <app-specific-password>"

# --- Sign with hardened runtime ---------------------------------------------
echo "Signing with: ${IDENTITY}"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# The DMG must be rebuilt so it contains the Developer ID-signed app.
echo "Rebuilding DMG around the signed app..."
Tools/make_dmg.sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DMG"

# --- Notarize and staple -----------------------------------------------------
echo "Submitting ${DMG} to the notary service (this can take several minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "Stapling..."
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

spctl -a -vv -t install "$DMG" || true
echo "Notarized and stapled: ${DMG}"
