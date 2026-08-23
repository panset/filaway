#!/usr/bin/env bash
# Assembles build/Filaway.app from a release SwiftPM build and ad-hoc signs it.
#
# There is no Xcode on this machine (plan §8), so the bundle is built by hand
# rather than by a .xcodeproj. Universal builds need Xcode's xcbuild; when that
# is missing we fall back to the native architecture and say so.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Filaway"
BUNDLE_ID="com.tejaspanse.filaway"
SHORT_VERSION="0.1.0"
BUNDLE_VERSION="1"
MIN_MACOS="14.0"

APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

# --- 1. Build ----------------------------------------------------------------
UNIVERSAL=1
BUILD_FLAGS=(-c release --product FilawayApp --arch arm64 --arch x86_64)
if [[ ! -x /Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild ]]; then
    UNIVERSAL=0
else
    # xcbuild exists but may still refuse; probe with a dry run.
    if ! swift build "${BUILD_FLAGS[@]}" --help >/dev/null 2>&1; then
        UNIVERSAL=0
    fi
fi

if [[ $UNIVERSAL -eq 1 ]] && swift build "${BUILD_FLAGS[@]}"; then
    BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
else
    if [[ $UNIVERSAL -eq 1 ]]; then
        echo "WARNING: universal build failed; falling back to native arch." >&2
    else
        echo "WARNING: universal (arm64+x86_64) build needs Xcode's xcbuild, which" >&2
        echo "         is not installed. Building for the native arch only." >&2
        echo "         Install Xcode.app to ship a universal binary (plan §8)." >&2
    fi
    swift build -c release --product FilawayApp
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

BINARY="${BIN_DIR}/FilawayApp"
[[ -f "$BINARY" ]] || { echo "ERROR: no binary at ${BINARY}" >&2; exit 1; }

# --- 2. Assemble the bundle --------------------------------------------------
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY" "${MACOS_DIR}/${APP_NAME}"

# SwiftPM emits resource bundles (Foo_Bar.bundle) next to the binary. Bundle.module
# looks for them beside the executable *and* in Contents/Resources; copy them so
# both lookups succeed.
shopt -s nullglob
for b in "${BIN_DIR}"/*.bundle; do
    cp -R "$b" "${RESOURCES_DIR}/"
done
shopt -u nullglob

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>            <string>en</string>
    <key>CFBundleExecutable</key>                   <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>                   <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>        <string>6.0</string>
    <key>CFBundleName</key>                         <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>                  <string>APPL</string>
    <key>CFBundleShortVersionString</key>           <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>                      <string>${BUNDLE_VERSION}</string>
    <key>LSMinimumSystemVersion</key>               <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>              <true/>
    <key>NSPrincipalClass</key>                     <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>       <false/>
    <key>NSSupportsSuddenTermination</key>          <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"

# --- 3. Ad-hoc sign ----------------------------------------------------------
# No Developer ID identity exists yet (plan §8); ad-hoc signing is enough to run
# locally. Tools/notarize.sh handles the real identity once one is available.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

ARCHS="$(lipo -archs "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || echo unknown)"
echo "Built ${APP} (${ARCHS}, ad-hoc signed)"
