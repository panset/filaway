#!/usr/bin/env bash
# One-time (M4-04): create the EdDSA key pair Sparkle uses to sign updates.
#
# The private key is stored in the login Keychain by Sparkle's own tool and
# never touches the working tree. The public key is printed here so it can go
# into Tools/release.env as SPARKLE_PUBLIC_KEY, from where Tools/make_app.sh
# writes it into Info.plist as SUPublicEDKey.
#
#     Tools/sparkle/generate_keys.sh              # create (or show) the pair
#     Tools/sparkle/generate_keys.sh --export     # print the private key too
#
# --export is for the GitHub Actions secret SPARKLE_PRIVATE_KEY and prompts for
# Keychain access. Treat its output like a signing certificate: anyone holding
# it can publish an update that every installed copy of Filaway will accept.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=Tools/lib.sh
. "${ROOT}/Tools/lib.sh"

BIN_DIR="$(filaway_sparkle_bin_dir "$ROOT" || true)"
if [[ -z "$BIN_DIR" ]]; then
    note "Sparkle's tools are not unpacked yet; resolving the package..."
    swift package resolve >&2
    BIN_DIR="$(filaway_sparkle_bin_dir "$ROOT" || true)"
fi
[[ -n "$BIN_DIR" ]] || {
    echo "ERROR: could not find Sparkle's bin/ under .build/artifacts." >&2
    echo "       Run 'swift build' once — SwiftPM unpacks the whole Sparkle" >&2
    echo "       distribution, tools included, as part of the binary target." >&2
    exit 1
}

if [[ "${1:-}" == "--export" ]]; then
    note "Exporting the private key from the Keychain (macOS will ask to allow it)."
    note "Paste the line below into the GitHub secret SPARKLE_PRIVATE_KEY."
    exec "${BIN_DIR}/generate_keys" -x /dev/stdout
fi

# generate_keys is idempotent: with a key already in the Keychain it prints the
# existing public key instead of making a second one.
"${BIN_DIR}/generate_keys"

echo
echo "Next: copy the public key above into Tools/release.env as"
echo "  SPARKLE_PUBLIC_KEY=\"<key>\""
echo "then rebuild with 'make app' — Info.plist gains SUPublicEDKey and the"
echo "Check for Updates… menu item stops being disabled."
