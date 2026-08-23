#!/usr/bin/env bash
# One release, end to end: app -> dmg -> notarize -> appcast -> GitHub Release.
#
#     make release VERSION=0.2.0                # the real thing
#     make release VERSION=0.2.0 DRY_RUN=1      # print, do not publish
#     Tools/release.sh 0.2.0 --dry-run
#
# --dry-run still builds the app, the DMG and the appcast — those are cheap and
# they are what usually breaks. It skips exactly the three irreversible steps:
# notarizing (a submission to Apple), tagging, and creating the GitHub Release.
#
# The pipeline is also expressed, step for step, in
# .github/workflows/release.yml. Keep the two in sync: this script is what a
# developer runs when CI is not an option, and the workflow is what actually
# ships. Every secret-dependent step is skippable in both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=Tools/lib.sh
. "${ROOT}/Tools/lib.sh"
filaway_load_release_env "$ROOT"

DRY_RUN="${DRY_RUN:-0}"
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) echo "ERROR: unknown flag ${arg}" >&2; exit 2 ;;
        *) VERSION="${arg#v}" ;;
    esac
done

[[ -n "$VERSION" ]] || { echo "usage: Tools/release.sh <version> [--dry-run]" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || { echo "ERROR: '${VERSION}' is not a semantic version." >&2; exit 2; }

export FILAWAY_VERSION="$VERSION"
TAG="v${VERSION}"
APP_NAME="Filaway"
DMG="build/${APP_NAME}-${VERSION}.dmg"
RELEASES="build/releases"

step() { echo; echo "==> $*"; }
skip() { echo "    SKIPPED: $*"; }

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN — nothing will be notarized, tagged or published."
fi

# --- 0. Sanity ---------------------------------------------------------------
step "Checking the working tree"
if [[ -n "$(git status --porcelain)" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        warn "working tree is dirty (fine for a dry run)."
    else
        echo "ERROR: working tree is dirty. Commit or stash before releasing." >&2
        exit 1
    fi
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag ${TAG} already exists. Releases are immutable; pick a new version." >&2
    exit 1
fi
# The VERSION file is the fallback source for every build that is not on a tag,
# so a release that does not update it would leave `main` claiming the old one.
FILE_VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ "$FILE_VERSION" != "$VERSION" ]]; then
    warn "VERSION file says ${FILE_VERSION}, releasing ${VERSION}."
    note "         Update it and commit before tagging: echo ${VERSION} > VERSION"
fi

# --- 1. Test -----------------------------------------------------------------
step "swift test"
swift test

# --- 2. Build ----------------------------------------------------------------
step "Building ${APP_NAME}.app ${VERSION}"
Tools/make_app.sh

ARCHS="$(lipo -archs "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}")"
if [[ "$ARCHS" != *x86_64* ]]; then
    warn "this build is ${ARCHS}, not universal."
    note "         Sparkle stamps sparkle:hardwareRequirements=arm64 on the appcast"
    note "         entry, so Intel Macs will not be offered the update at all."
    note "         Release from CI (macos-15 has Xcode) or install Xcode locally."
fi

# --- 3. DMG ------------------------------------------------------------------
step "Packaging ${DMG}"
Tools/make_dmg.sh

# --- 4. Notarize -------------------------------------------------------------
step "Notarizing"
if [[ "$DRY_RUN" == "1" ]]; then
    skip "Tools/notarize.sh (dry run)"
elif [[ -z "$(filaway_signing_identity)" ]]; then
    skip "no Developer ID; the DMG is ad-hoc signed and Gatekeeper will refuse it"
    note "    Run 'make notarize' after enrolling; see docs/release.md."
else
    Tools/notarize.sh
fi

# --- 5. Appcast --------------------------------------------------------------
step "Generating the appcast"
Tools/sparkle/make_appcast.sh

# --- 6. Publish --------------------------------------------------------------
step "Publishing ${TAG}"
if ! command -v gh >/dev/null 2>&1; then
    skip "gh is not installed; upload ${DMG} and ${RELEASES}/appcast.xml by hand"
elif [[ "$DRY_RUN" == "1" ]]; then
    skip "git tag ${TAG} && gh release create ${TAG} ${DMG} ${RELEASES}/appcast.xml"
else
    git tag -a "$TAG" -m "Filaway ${VERSION}"
    gh release create "$TAG" \
        --title "Filaway ${VERSION}" \
        --generate-notes \
        "$DMG" "${RELEASES}/appcast.xml"
    note "Pushing the tag so the release is reachable..."
    git push origin "$TAG"
fi

echo
echo "Done: ${DMG}"
echo "Appcast: ${RELEASES}/appcast.xml"
echo "Publish the appcast to GitHub Pages so SUFeedURL resolves — see docs/release.md."
