#!/usr/bin/env bash
# Packages build/Filaway.app into build/Filaway-<version>.dmg.
#
# Uses create-dmg when installed and a GUI session is available (nicer window
# layout), hdiutil otherwise. Set FILAWAY_DMG_PLAIN=1 to force hdiutil — that is
# what CI does, because create-dmg drives Finder through AppleScript and a
# headless runner has no Finder to drive.
#
# The staged layout is fixed: the app, an /Applications symlink, nothing else.
# .DS_Store files and extended attributes are stripped before the image is made,
# so two builds of the same commit produce the same tree inside the image (the
# compressed bytes still differ — hdiutil stamps a creation date).
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
VOLNAME="${APP_NAME} ${VERSION}"

[[ -d "$APP" ]] || { echo "ERROR: ${APP} not found. Run 'make app' first." >&2; exit 1; }

# The app's own Info.plist is the authority once it exists — a DMG labelled
# 0.2.0 around a 0.1.0 app is the kind of mistake Sparkle turns into a broken
# update for every user.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$APP_VERSION" && "$APP_VERSION" != "$VERSION" ]]; then
    warn "${APP} is version ${APP_VERSION}, not ${VERSION}; using the bundle's."
    VERSION="$APP_VERSION"
    DMG="build/${APP_NAME}-${VERSION}.dmg"
    VOLNAME="${APP_NAME} ${VERSION}"
fi

rm -f "$DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
find "$STAGE" -name '.DS_Store' -delete

if command -v create-dmg >/dev/null 2>&1 && [[ "${FILAWAY_DMG_PLAIN:-0}" != "1" ]]; then
    note "Packaging with create-dmg..."
    # create-dmg exits 2 when it cannot set a custom icon layout; that is
    # cosmetic, so accept it as long as the image was produced. It stages its
    # own copy, so point it at the app rather than at $STAGE (it adds its own
    # /Applications link via --app-drop-link).
    create-dmg \
        --volname "$VOLNAME" \
        --window-size 520 340 \
        --icon-size 96 \
        --icon "${APP_NAME}.app" 130 150 \
        --app-drop-link 390 150 \
        --no-internet-enable \
        "$DMG" "$APP" || true
    [[ -f "$DMG" ]] || warn "create-dmg produced no image; falling back to hdiutil."
fi

if [[ ! -f "$DMG" ]]; then
    note "Packaging with hdiutil..."
    hdiutil create \
        -volname "$VOLNAME" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        "$DMG" >/dev/null
fi

# A stable, unversioned name for `make notarize` and for anything that just
# wants "the DMG that was built last".
ln -sf "$(basename "$DMG")" "build/${APP_NAME}.dmg"

echo "Built ${DMG} ($(du -h "$DMG" | cut -f1))"
