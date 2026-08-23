# Filaway — guide for implementation agents

macOS notes app: an AI files notes after each writing session; retrieval is
natural language. Spec: `docs/spec/functional-spec.html` (v0.3). Plan of record:
`docs/plan.md` — **read §1 (tech decisions), §2 (layout/conventions) and §8
(build-environment amendment) before touching anything.**

## Commands

| Command | What it does |
|---|---|
| `make setup` | Checks toolchain, reports optional tools, resolves dependencies |
| `make build` | `swift build` (debug, all targets) |
| `make test` | `swift test` — **must be green before any task is reported done** |
| `make bench` | Runs `filaway-bench` (pass `ARGS="keyword --notes 5000"`) |
| `make app` | Release build → `build/Filaway.app`, ad-hoc signed |
| `make run` | `make app` then `open build/Filaway.app` |
| `make dmg` | `build/Filaway.dmg` (create-dmg, hdiutil fallback) |
| `make notarize` | Developer ID sign + notarize + staple (currently BLOCKED, see below) |
| `make release` | app → dmg → notarize |
| `make clean` | Removes `.build/` and `build/` |

Headless UI smoke check (no Xcode/XCTest needed, works on a locked screen):

```
FILAWAY_SMOKE=1 build/Filaway.app/Contents/MacOS/Filaway
# -> SMOKE window title="Filaway" visible=true size=1000x680
```

## Layout

```
Package.swift              # single root package (no .xcodeproj — see §8)
Sources/FilawayCore/       # all logic; library; Swift 6 language mode
  Util/Log.swift           # OSLog factory, subsystem com.tejaspanse.filaway
Sources/FilawayApp/        # SwiftUI + AppKit shell; executable; Swift 5 mode
Sources/FilawayBench/      # filaway-bench CLI (swift-argument-parser)
Tests/FilawayCoreTests/    # Swift Testing (import Testing, @Test)
Tools/                     # make_app.sh, make_dmg.sh, notarize.sh
.github/workflows/ci.yml   # macos-15: build, test, assemble app
docs/plan.md               # Phase 1 plan (authoritative)
docs/decisions.md          # ADR-lite — append every notable decision
docs/spec/                 # functional spec
```

Planned `FilawayCore` subdirectories (plan §2.7): `Storage`, `Markdown`, `Index`,
`Search`, `Session`, `Organize`, `AI`, `Embeddings`, `Activity`, `Settings`, `Util`.

## Conventions

1. **`FilawayCore` must never `import AppKit` or `import SwiftUI`.** All logic
   lives there so it is testable with `swift test` alone. UI-only types stay in
   `FilawayApp`.
2. **Swift 6 language mode in Core** (actors: `NoteStore`, `Indexer`,
   `SessionTracker`, `Organizer`). The app target is Swift 5 mode with
   `StrictConcurrency` upcoming-feature warnings, for AppKit interop.
3. **Every task ends with `make test` green.** No exceptions.
4. **Append notable decisions to `docs/decisions.md`** (ADR-lite: context,
   decision, consequences).
5. **Never commit a `.xcodeproj`/`.xcworkspace`** — they are gitignored. When
   Xcode is installed, XcodeGen `project.yml` becomes additive, not a
   replacement for `Package.swift`.
6. **Commit messages cite requirement IDs from the spec** — e.g.
   `feat(storage): atomic note write and front-matter codec (DS-1, DS-2)`.
   Task IDs from the plan (`M1-03`) are welcome too.
7. **Never log note content.** NFR-4 is zero-content telemetry; interpolate user
   text into `Logger` only with `privacy: .private`.
8. Bundle id and OSLog subsystem are both `com.tejaspanse.filaway`
   (`FilawayCore.subsystem`).

## Environment caveats (plan §8 — this machine, 2026-08)

- **No Xcode.app.** Command Line Tools only, Swift 6.0.3, macOS 26.1.
  Consequences:
  - **Build is pure SwiftPM.** One root `Package.swift`; no XcodeGen yet.
  - **The `.app` bundle is assembled by `Tools/make_app.sh`**, not by a project
    file, and ad-hoc signed (`codesign -s -`).
  - **Universal (arm64 + x86_64) builds are impossible**: `swift build --arch
    arm64 --arch x86_64` needs Xcode's `xcbuild`. `make_app.sh` detects this,
    warns, and builds native arm64 only. Re-test the universal path once Xcode
    is installed (needed for NFR Intel support).
  - **XCTest UI tests are unavailable.** Use (a) Core-level tests for all logic,
    (b) the `FILAWAY_SMOKE=1` hook above / `osascript` + `screencapture`
    drivers, (c) manual DoD checklists.
  - **Core ML `coremlcompiler` is Xcode-only** → compile `.mlpackage` at first
    launch with `MLModel.compileModel(at:)` and cache it. The embedder fallback
    ladder gains `NLContextualEmbedding` (macOS 14+) as a zero-download option.
- **No code-signing identities and no Apple Developer Program enrolment.**
  Signing, notarization and Sparkle EdDSA are blocked. `Tools/notarize.sh` runs
  every precondition check and exits with a `BLOCKED: …` message; implement
  release tasks up to the signing step and verify once credentials exist.
- **GRDB is pinned below 7.9.0**: 7.9.0+ declares swift-tools-version 6.1, which
  the 6.0.3 toolchain cannot read. Raise the bound with the toolchain.
- **Action for the user:** install Xcode from the App Store and enrol in the
  Apple Developer Program to unblock notarization, Sparkle signing, universal
  builds and XCTest UI tests.

## Current state

M1-01 / M1-02 scaffolding only: the app shows an empty `NavigationSplitView`
("Recents / Library" | "Editor"). No storage, no DB, no AI. Next tasks are
M1-03 (storage model) and M1-09/M1-10 (shell and editor) — see `docs/plan.md` §3.
