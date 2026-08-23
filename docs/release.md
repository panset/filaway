# Releasing Filaway

Spec §3 ships a signed, notarized DMG outside the App Store; spec §9 requires an
in-app update mechanism, which is Sparkle 2. This document covers the one-time
setup for both and the per-release flow. Tasks M4-04 and M4-05.

**Status on the dev machine (2026-08):** the whole pipeline is implemented and
everything that does not need an Apple Developer Program membership has been run
end to end — universal builds excepted, which need Xcode. `make notarize`
prints `BLOCKED: no 'Developer ID Application' certificate in the keychain.`
Section 1 is what turns that into a shipping release.

---

## 1. One-time setup

Six things, roughly in the order they unblock each other. Only the first has a
waiting period.

### 1.1 Apple Developer Program — $99/yr

Enrol at <https://developer.apple.com/programs/>. Approval takes anywhere from
minutes to several days, so start here. Nothing below 1.2 works without it.

### 1.2 Developer ID Application certificate

Needs Xcode.app (the Command Line Tools cannot create certificates):

1. Xcode → Settings → Accounts → add the Apple ID → *Manage Certificates…*
2. **+** → *Developer ID Application*.
3. Confirm it landed: `security find-identity -v -p codesigning` should list
   `Developer ID Application: <Name> (<TEAMID>)`.
4. Put that exact string in `Tools/release.env` as `DEVELOPER_ID` (copy
   `Tools/release.env.example` to start). `Tools/make_app.sh` picks the first
   such certificate up automatically, so this is only needed when several
   exist.

For CI, export the certificate *with its private key* as a `.p12` from Keychain
Access (right-click → Export), then:

```sh
base64 -i Certificates.p12 | pbcopy   # -> secret DEVELOPER_ID_P12
```

### 1.3 Notary credentials

Two options; use both if you like, the scripts prefer the API key.

**A keychain profile** (developer machine):

```sh
xcrun notarytool store-credentials "filaway-notary" \
  --apple-id you@example.com --team-id ABCDE12345 \
  --password <app-specific-password>
```

The app-specific password comes from <https://account.apple.com> → Sign-In and
Security → App-Specific Passwords. It is *not* the Apple ID password.

**An App Store Connect API key** (CI): App Store Connect → Users and Access →
Integrations → App Store Connect API → **+**, role *Developer*. Download the
`AuthKey_XXXXXXXXXX.p8` once — it cannot be downloaded twice. Note the Key ID
and the Issuer ID.

### 1.4 Sparkle signing keys

```sh
make sparkle-keys          # = Tools/sparkle/generate_keys.sh
```

The private key goes into the login Keychain (item "Private key for signing
Sparkle updates"); the public key is printed. Copy it into `Tools/release.env`:

```sh
SPARKLE_PUBLIC_KEY="…"
```

Rebuild (`make app`) and the Info.plist gains `SUPublicEDKey`; the
**Check for Updates…** menu item stops being disabled.

For CI, export the private key:

```sh
Tools/sparkle/generate_keys.sh --export     # -> secret SPARKLE_PRIVATE_KEY
```

> Treat that string like the signing certificate. Anyone holding it can publish
> an update that every installed copy of Filaway will accept and run. There is
> no revocation: recovering from a leak means shipping a new public key in a new
> build and getting every user to install it out of band.

**Back up the Keychain item.** Losing it means every already-installed copy is
permanently unable to update — the public key is baked into the shipped
Info.plist and cannot be changed remotely.

### 1.5 GitHub Actions secrets

Settings → Secrets and variables → Actions. All optional; `release.yml` skips
each dependent step with a visible warning when its secret is missing, so the
workflow can be dispatched and inspected before any of them exist.

| Secret | Source | Without it |
|---|---|---|
| `DEVELOPER_ID_P12` | 1.2, base64 of the `.p12` | ad-hoc signed; no notarization |
| `DEVELOPER_ID_P12_PASSWORD` | the export password | as above |
| `NOTARY_KEY_ID` | 1.3, App Store Connect | not notarized |
| `NOTARY_ISSUER_ID` | 1.3 | not notarized |
| `NOTARY_KEY_P8` | contents of `AuthKey_*.p8` | not notarized |
| `SPARKLE_PUBLIC_KEY` | 1.4 | build cannot update itself |
| `SPARKLE_PRIVATE_KEY` | 1.4 `--export` | no appcast is generated |

### 1.6 GitHub Pages for the appcast

`SUFeedURL` is baked into every shipped build and can never be moved afterwards
without stranding the users who already installed it. It is currently
`https://tejaspanse.github.io/filaway/appcast.xml` — **[ASSUMPTION]**; if the
repo is named differently, change `FEED_URL` in `Tools/make_app.sh` (or set
`SUFEED_URL` in `release.env`) *before the first public release*.

Settings → Pages → Source: *Deploy from a branch*, branch `gh-pages`, folder
`/`. The release workflow creates and pushes that branch itself, including a
`.nojekyll` file so Jekyll does not swallow the XML.

Verify after the first release:

```sh
curl -I https://tejaspanse.github.io/filaway/appcast.xml
```

---

## 2. Per-release flow

### The normal path — CI

```sh
echo 0.2.0 > VERSION
git commit -am "release: 0.2.0"
git push
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` then, on a macos-15 runner: runs `swift test`,
selects Xcode, builds a **universal** app, verifies it with `lipo`, runs the
smoke suite, packages the DMG, notarizes and staples it, signs the update,
generates the appcast, creates the GitHub Release with the DMG and appcast
attached, and pushes `appcast.xml` to `gh-pages`.

Dispatch it manually first (Actions → Release → Run workflow) to see the shape
of a run without publishing anything.

### The local path

```sh
make release VERSION=0.2.0 DRY_RUN=1    # build + dmg + appcast, publish nothing
make release VERSION=0.2.0              # the real thing
```

`Tools/release.sh` runs the same steps and refuses a dirty tree or an existing
tag. On this machine it will warn that the build is `arm64` only — see §4.

### Individual steps

```sh
make app        # build/Filaway.app, Sparkle embedded, signed
make dmg        # build/Filaway-<version>.dmg (+ a Filaway.dmg symlink)
make notarize   # Developer ID sign, notarize, staple, spctl
make appcast    # build/releases/appcast.xml, EdDSA-signed
```

### Where the version numbers come from

| Key | Source |
|---|---|
| `CFBundleShortVersionString` | `$FILAWAY_VERSION`, else an exact `v*` tag on HEAD, else the `VERSION` file |
| `CFBundleVersion` | `git rev-list --count HEAD` |

`CFBundleVersion` is the number **Sparkle compares** to decide whether an update
is newer, which is why it is the commit count and not the marketing version: it
increases monotonically, never repeats, and is derivable from any checkout. A
shallow clone breaks it — `release.yml` uses `fetch-depth: 0` for exactly that
reason.

---

## 3. Verifying a release

```sh
# Gatekeeper's own verdict — the thing that actually decides whether a
# downloaded DMG opens on someone else's Mac.
spctl -a -vv -t install build/Filaway-0.2.0.dmg
spctl -a -vv -t exec build/Filaway.app

# The stapled ticket, so it works offline.
xcrun stapler validate build/Filaway-0.2.0.dmg

# Universal, and Sparkle actually resolves.
lipo -info build/Filaway.app/Contents/MacOS/Filaway
otool -L build/Filaway.app/Contents/MacOS/Filaway | grep Sparkle
codesign --verify --deep --strict --verbose=2 build/Filaway.app

# The appcast is signed and points at real assets.
grep edSignature build/releases/appcast.xml
curl -sI "$(grep -o 'url="[^"]*"' build/releases/appcast.xml | head -1 | cut -d'"' -f2)"
```

The end-to-end test Sparkle needs, once per release and only doable by hand:
install release *N* from its DMG into `/Applications`, publish *N+1*, then use
**Check for Updates…** in the installed copy. It has to be the installed copy —
Sparkle refuses to update an app running from a DMG or a build directory.

---

## 4. What is blocked, and by what

| Blocked | Needs | Symptom today |
|---|---|---|
| Notarization | 1.1 + 1.2 + 1.3 | `Tools/notarize.sh` exits `BLOCKED: no 'Developer ID Application' certificate` |
| Hardened runtime | 1.2 | `make app` ad-hoc signs without `--options runtime` (an ad-hoc signature has no team id, so library validation would refuse to load the equally ad-hoc Sparkle.framework) |
| Universal binary | Xcode.app | `make app` warns and builds arm64 only; `swift build --arch arm64 --arch x86_64` needs Xcode's `xcbuild` (ADR-001) |
| Signed appcast | 1.4 | `make appcast` exits `BLOCKED: … no EdDSA private key` |
| Working updates | 1.4 + 1.6 | the menu item is disabled, tooltip "Updates not configured in this build" |

Two of these interact in a way that is easy to miss:

* `generate_appcast` writes `sparkle:edSignature` **only when the archived app's
  Info.plist declares `SUPublicEDKey`.** A DMG built without
  `SPARKLE_PUBLIC_KEY` produces a silently unsigned appcast entry that every
  client will reject. Verified by building it both ways.
* Sparkle stamps `sparkle:hardwareRequirements` from the slices it finds in the
  archive. An arm64-only build therefore yields
  `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`, and
  **Intel Macs are never offered the update at all** — a silent failure with no
  error anywhere. This is why `ci.yml` and `release.yml` both set
  `FILAWAY_REQUIRE_UNIVERSAL=1` and assert with `lipo`.

---

## 5. How the pieces fit

```
Package.swift ──> Sparkle 2.9.x (SPM binary target, prebuilt universal xcframework)
                   │
                   ├─ .build/…/Sparkle.framework      -> embedded by make_app.sh
                   └─ .build/artifacts/…/bin/         -> generate_keys, sign_update,
                                                         generate_appcast, BinaryDelta

Tools/lib.sh          versions, release.env, Sparkle paths, signing identity
Tools/make_app.sh     build -> bundle -> embed Sparkle -> Info.plist -> sign inner-out
Tools/make_dmg.sh     build/Filaway-<version>.dmg
Tools/notarize.sh     Developer ID + notarytool + stapler + spctl (or BLOCKED)
Tools/sparkle/        generate_keys.sh, make_appcast.sh
Tools/release.sh      all of the above + gh release create   (make release)
.github/workflows/release.yml   the same pipeline, on a runner that has Xcode
```

Sparkle's command-line tools are **not** downloaded separately: SwiftPM unpacks
the entire Sparkle distribution — tools included — when it resolves the binary
target, and `Tools/lib.sh` finds them under `.build/artifacts` (ADR-043).

Filaway is not sandboxed (spec §3, `Tools/Filaway.entitlements`), so Sparkle's
XPC services are unnecessary; `make_app.sh` strips them and the corresponding
`SUEnableInstallerLauncherService` / `SUEnableDownloaderService` Info.plist keys
are deliberately unset (ADR-045).
