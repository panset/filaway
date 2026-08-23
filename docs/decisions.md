# Decisions (ADR-lite)

Append one entry per notable decision. Newest last. Keep each to context /
decision / consequences. Decisions that only restate `docs/plan.md` §1 do not
need an entry; deviations from it always do.

---

## ADR-001 — Build with pure SwiftPM, no Xcode project

**Date:** 2026-08-22 · **Task:** M1-01 · **Status:** accepted (revisit when Xcode is installed)

**Context.** The plan (§1) assumed Xcode 16.4+ with an XcodeGen-generated
`.xcodeproj` for the app target. At kickoff the dev machine turned out to have
only the Command Line Tools (Swift 6.0.3, macOS 26.1) and no Xcode.app, so
`xcodebuild`, XcodeGen's output, and XCTest UI tests are all unusable.

**Decision.** A single root `Package.swift` (swift-tools-version 6.0) defines
every target: `FilawayCore` (library), `FilawayApp` (executable, SwiftUI +
AppKit), `filaway-bench` (executable) and `FilawayCoreTests`. Language modes
follow plan §1: Swift 6 in Core, Swift 5 + `StrictConcurrency` upcoming-feature
warnings in the app target for AppKit interop. Min platform macOS 14.

**Consequences.**
- `swift build` / `swift test` are the whole build; CI runs the same commands.
- Universal (arm64 + x86_64) builds are **not possible**: `--arch arm64 --arch
  x86_64` requires Xcode's `xcbuild`, which the CLT does not ship. Builds are
  native arm64; `Tools/make_app.sh` warns. Intel support must be re-verified
  once Xcode exists.
- XCTest UI tests are replaced by Core-level tests plus a `FILAWAY_SMOKE=1`
  launch hook in `AppDelegate` that prints window title/size and exits.
- `project.yml` becomes additive later; `Package.swift` stays the source of truth.

---

## ADR-002 — The `.app` bundle is assembled by a script and ad-hoc signed

**Date:** 2026-08-22 · **Task:** M1-01 / M1-02 · **Status:** accepted (signing steps blocked)

**Context.** SwiftPM produces a bare executable, not a bundle. A SwiftUI app run
as a bare executable launches as an accessory: no menu bar, no key window. There
are also no code-signing identities on the machine and no Developer Program
enrolment, so the M1-02 notarization dry run cannot complete.

**Decision.** `Tools/make_app.sh` assembles `build/Filaway.app` by hand —
`Contents/Info.plist` (id `com.tejaspanse.filaway`, `NSPrincipalClass`
`NSApplication`, `LSMinimumSystemVersion` 14.0, `NSHighResolutionCapable`),
`Contents/MacOS/Filaway`, and any SwiftPM `*.bundle` resources copied into
`Contents/Resources/` so `Bundle.module` resolves — then ad-hoc signs it
(`codesign --force --deep --sign -`). `AppDelegate` additionally forces
`.regular` activation policy and calls `activate`, so the app also behaves when
run directly via `swift run`. `Tools/make_dmg.sh` prefers `create-dmg` and falls
back to `hdiutil`. `Tools/notarize.sh` checks every precondition (notarytool,
stapler, a Developer ID identity, the `filaway-notary` keychain profile) and
exits with an explicit `BLOCKED: …` message rather than failing obscurely.

**Consequences.**
- `make app`, `make run` and `make dmg` work today; `make notarize` reports
  `BLOCKED: no 'Developer ID Application' certificate in the keychain.`
- `create-dmg`'s AppleScript window layout needs an unlocked GUI session; the
  `hdiutil` fallback covers headless/locked and CI runs.
- Risk #5 (signing/notarization friction) stays open until the user enrols and
  installs Xcode. `notarize.sh` is written end-to-end so it can be verified in
  one pass at that point.

---

## ADR-003 — Initial dependency set and version pins

**Date:** 2026-08-22 · **Task:** M1-01 · **Status:** accepted

**Context.** Plan §1 names GRDB (derived DB), swift-markdown (parsing) and
Sparkle (updates); the bench CLI needs argument parsing. The 6.0.3 toolchain
cannot read packages that declare swift-tools-version 6.1.

**Decision.** Three direct dependencies, resolved as:

| Package | Constraint | Resolved |
|---|---|---|
| `groue/GRDB.swift` | `"7.0.0" ..< "7.9.0"` | **7.8.0** |
| `swiftlang/swift-markdown` | `from: "0.8.0"` | **0.8.0** (pulls swift-cmark 0.8.0) |
| `apple/swift-argument-parser` | `from: "1.8.0"` | **1.8.2** |

Sparkle is deliberately **not** added yet: it is M4-04, and its EdDSA signing is
blocked on the same missing credentials.

**Consequences.**
- The GRDB upper bound is a toolchain workaround, not a compatibility judgement:
  7.9.0+ declares swift-tools-version 6.1 and fails to resolve here with
  `contains incompatible tools version (6.1.0)`. Raise the bound once Swift 6.1+
  is available.
- `Package.resolved` is committed, so CI and the dev machine resolve identically.
- Tests use **Swift Testing** (`import Testing`), which the 6.0.3 toolchain
  supports natively via SwiftPM — no XCTest and no extra dependency needed.
