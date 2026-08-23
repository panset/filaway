#!/usr/bin/env bash
# Assembles build/Filaway.app from a release SwiftPM build, embeds Sparkle, and
# signs it — with a Developer ID when one is available, ad-hoc otherwise.
#
# There is no Xcode on this machine (plan §8), so the bundle is built by hand
# rather than by a .xcodeproj. Universal builds need Xcode's xcbuild; when that
# is missing we fall back to the native architecture and say so.
#
# Environment (or Tools/release.env — see Tools/lib.sh):
#   FILAWAY_VERSION      overrides CFBundleShortVersionString
#   DEVELOPER_ID         "Developer ID Application: Name (TEAMID)"
#   SPARKLE_PUBLIC_KEY   base64 EdDSA public key -> Info.plist SUPublicEDKey
#   SUFEED_URL           appcast URL -> Info.plist SUFeedURL
#   FILAWAY_REQUIRE_UNIVERSAL=1  fail instead of falling back to native arch
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=Tools/lib.sh
. "${ROOT}/Tools/lib.sh"
filaway_load_release_env "$ROOT"

APP_NAME="Filaway"
BUNDLE_ID="com.tejaspanse.filaway"
MIN_MACOS="14.0"
ENTITLEMENTS="${ROOT}/Tools/${APP_NAME}.entitlements"

SHORT_VERSION="$(filaway_short_version "$ROOT")"
BUNDLE_VERSION="$(filaway_build_version "$ROOT")"

# [ASSUMPTION] GitHub Pages on the project repo. Change here and in
# docs/release.md together; a shipped build's SUFeedURL cannot be moved
# afterwards without stranding everyone who already installed it.
FEED_URL="${SUFEED_URL:-https://tejaspanse.github.io/filaway/appcast.xml}"
PUBLIC_ED_KEY="${SPARKLE_PUBLIC_KEY:-}"

APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"

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

BUILT_UNIVERSAL=0
if [[ $UNIVERSAL -eq 1 ]] && swift build "${BUILD_FLAGS[@]}"; then
    BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
    BUILT_UNIVERSAL=1
else
    if [[ $UNIVERSAL -eq 1 ]]; then
        warn "universal build failed; falling back to native arch."
    else
        warn "universal (arm64+x86_64) build needs Xcode's xcbuild, which is not"
        note "         installed. Building for the native arch only."
        note "         Install Xcode.app to ship a universal binary (plan §8)."
    fi
    if [[ "${FILAWAY_REQUIRE_UNIVERSAL:-0}" == "1" ]]; then
        echo "ERROR: FILAWAY_REQUIRE_UNIVERSAL=1 but a universal build is not possible here." >&2
        exit 1
    fi
    swift build -c release --product FilawayApp
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

BINARY="${BIN_DIR}/FilawayApp"
[[ -f "$BINARY" ]] || { echo "ERROR: no binary at ${BINARY}" >&2; exit 1; }

# --- 2. Assemble the bundle --------------------------------------------------
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$BINARY" "${MACOS_DIR}/${APP_NAME}"

# SwiftPM emits resource bundles (Foo_Bar.bundle) next to the binary. Bundle.module
# looks for them beside the executable *and* in Contents/Resources; copy them so
# both lookups succeed.
shopt -s nullglob
for b in "${BIN_DIR}"/*.bundle; do
    cp -R "$b" "${RESOURCES_DIR}/"
done
shopt -u nullglob

# --- 3. Embed Sparkle --------------------------------------------------------
# The executable links `@rpath/Sparkle.framework/Versions/B/Sparkle` and SwiftPM
# gives it only an `@loader_path` rpath, which inside Contents/MacOS resolves to
# Contents/MacOS. Add the conventional Frameworks rpath and drop the Command
# Line Tools' developer-frameworks rpath, which has no business in a shipped app.
SPARKLE_FRAMEWORK="$(filaway_sparkle_framework "$ROOT" "$BIN_DIR" || true)"
[[ -n "$SPARKLE_FRAMEWORK" ]] \
    || { echo "ERROR: Sparkle.framework not found. Run 'swift package resolve' first." >&2; exit 1; }

# ditto, not cp -R: it preserves the framework's symlink farm (Versions/Current,
# the top-level aliases) and its extended attributes exactly.
ditto "$SPARKLE_FRAMEWORK" "${FRAMEWORKS_DIR}/Sparkle.framework"

# Sparkle's XPC services exist only so a *sandboxed* app can install updates and
# download over the network. Filaway is deliberately not sandboxed (spec §3, see
# Tools/Filaway.entitlements), so they are dead weight that would additionally
# have to be re-signed with their own sandbox entitlements. Sparkle's sandboxing
# guide says to omit them in exactly this case; the matching Info.plist keys
# SUEnableInstallerLauncherService / SUEnableDownloaderService stay unset.
rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices"
rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework/XPCServices"
# Headers are a build-time artefact; shipping them bloats the DMG and confuses
# `codesign --verify --strict` about what is sealed.
rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Headers" \
       "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/PrivateHeaders" \
       "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Modules" \
       "${FRAMEWORKS_DIR}/Sparkle.framework/Headers" \
       "${FRAMEWORKS_DIR}/Sparkle.framework/PrivateHeaders" \
       "${FRAMEWORKS_DIR}/Sparkle.framework/Modules"

install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true
for stale in $(otool -l "${MACOS_DIR}/${APP_NAME}" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' \
               | grep '^/Library/Developer/' || true); do
    install_name_tool -delete_rpath "$stale" "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true
done

# --- 4. Info.plist -----------------------------------------------------------
# SUPublicEDKey is written only when a key is supplied. Its absence is what
# UpdaterController reads as "updates not configured in this build", which is the
# correct state for every ad-hoc developer build (ADR-042).
SPARKLE_KEYS="    <key>SUFeedURL</key>                            <string>${FEED_URL}</string>
    <key>SUEnableAutomaticChecks</key>              <true/>
    <key>SUScheduledCheckInterval</key>             <integer>86400</integer>
    <key>SUAutomaticallyUpdate</key>                <false/>"
if [[ -n "$PUBLIC_ED_KEY" ]]; then
    SPARKLE_KEYS="${SPARKLE_KEYS}
    <key>SUPublicEDKey</key>                        <string>${PUBLIC_ED_KEY}</string>"
else
    warn "no SPARKLE_PUBLIC_KEY: SUPublicEDKey omitted, so this build cannot update itself."
    note "         Run Tools/sparkle/generate_keys.sh once and put the key in Tools/release.env."
fi

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
${SPARKLE_KEYS}
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"

# --- 5. Sign, inner-out ------------------------------------------------------
# `codesign --deep` is deprecated and cannot apply entitlements to nested code,
# so every nested executable is signed explicitly, deepest first, before the
# bundle that contains it. Sparkle's Autoupdate and Updater.app are separate
# executables and must each carry the hardened runtime for notarization to pass.
IDENTITY="$(filaway_signing_identity)"
SIGN_FLAGS=(--force)
if [[ -n "$IDENTITY" ]]; then
    note "Signing with: ${IDENTITY}"
    # --timestamp reaches Apple's timestamp server; required for notarization.
    SIGN_FLAGS+=(--options runtime --timestamp --sign "$IDENTITY")
else
    note "No Developer ID identity; ad-hoc signing (plan §8)."
    # No hardened runtime for ad-hoc: an ad-hoc signature carries no team
    # identifier, so library validation would refuse to load the equally ad-hoc
    # Sparkle.framework and the app would not launch at all.
    SIGN_FLAGS+=(--timestamp=none --sign -)
fi

SPARKLE_VERSION_DIR="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"
[[ -e "${SPARKLE_VERSION_DIR}/Autoupdate" ]] && codesign "${SIGN_FLAGS[@]}" "${SPARKLE_VERSION_DIR}/Autoupdate"
[[ -d "${SPARKLE_VERSION_DIR}/Updater.app" ]] && codesign "${SIGN_FLAGS[@]}" "${SPARKLE_VERSION_DIR}/Updater.app"
codesign "${SIGN_FLAGS[@]}" "${FRAMEWORKS_DIR}/Sparkle.framework"

APP_SIGN_FLAGS=("${SIGN_FLAGS[@]}")
[[ -n "$IDENTITY" && -f "$ENTITLEMENTS" ]] && APP_SIGN_FLAGS+=(--entitlements "$ENTITLEMENTS")
codesign "${APP_SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# --- 6. Report ---------------------------------------------------------------
ARCHS="$(lipo -archs "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || echo unknown)"
if [[ $BUILT_UNIVERSAL -eq 1 && "$ARCHS" != *x86_64* ]]; then
    echo "ERROR: universal build requested but the binary is ${ARCHS}." >&2
    exit 1
fi
# Proves the rpath surgery worked: an unresolved @rpath would print nothing.
if ! otool -L "${MACOS_DIR}/${APP_NAME}" | grep -q 'Sparkle.framework'; then
    echo "ERROR: the binary does not link Sparkle." >&2
    exit 1
fi
echo "Built ${APP} ${SHORT_VERSION} (${BUNDLE_VERSION}) — ${ARCHS}, $(
    [[ -n "$IDENTITY" ]] && echo "Developer ID + hardened runtime" || echo "ad-hoc signed"
), Sparkle $(
    [[ -n "$PUBLIC_ED_KEY" ]] && echo "configured" || echo "unconfigured"
)"
