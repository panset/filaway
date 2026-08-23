#!/usr/bin/env bash
# Packages build/Filaway.app into build/Filaway.dmg.
# Uses create-dmg when installed (nicer window layout), hdiutil otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Filaway"
VERSION="0.1.0"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}.dmg"

[[ -d "$APP" ]] || { echo "ERROR: ${APP} not found. Run 'make app' first." >&2; exit 1; }

rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
    echo "Packaging with create-dmg..."
    # create-dmg exits 2 when it cannot set a custom icon layout; that is
    # cosmetic, so accept it as long as the image was produced.
    create-dmg \
        --volname "${APP_NAME} ${VERSION}" \
        --window-size 520 340 \
        --icon-size 96 \
        --icon "${APP_NAME}.app" 130 150 \
        --app-drop-link 390 150 \
        --no-internet-enable \
        "$DMG" "$APP" || true
    [[ -f "$DMG" ]] || { echo "create-dmg produced no image; falling back to hdiutil." >&2; }
fi

if [[ ! -f "$DMG" ]]; then
    echo "Packaging with hdiutil..."
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "${STAGE}/"
    ln -s /Applications "${STAGE}/Applications"
    hdiutil create \
        -volname "${APP_NAME} ${VERSION}" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        "$DMG"
fi

echo "Built ${DMG} ($(du -h "$DMG" | cut -f1))"
