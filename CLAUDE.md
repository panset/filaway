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

Headless UI smoke tests (no Xcode/XCTest needed, works on a locked screen):

```
make smoke          # or: Tools/smoke.sh [--keep]
# -> === smoke phase: editor ===   M1-10 editor checks, on a note read from disk
# -> === smoke phase: search ===   M1-12 ⌘K on a 3-note corpus seeded on disk
#                                  *before* launch: as-you-type hits, match and
#                                  snippet ranges, ↑↓⏎esc, open-scrolled-to-
#                                  match, fuzzy titles, recents, "No matches"
# -> === smoke phase: kill ===     type -> wait out the 750 ms debounce -> type
#                                  again -> park; the script sends SIGKILL
# -> === smoke phase: killcheck === relaunch: the debounced burst is on disk,
#                                  the library opens clean (FR-2.3, NFR-3)
# -> === smoke phase: 1 ===        empty sidebar -> ⌘N -> type -> autosave hits
#                                  disk -> retitle renames the file -> an
#                                  external note reaches the sidebar -> quit
#                                  mid-burst
# -> === smoke phase: 2 ===        relaunch: last note and that last burst are
#                                  back (FR-1.5, FR-2.3)
# -> SMOKE result failures=0       (exit status = number of failures)
```

`Tools/smoke.sh` runs `build/Filaway.app` six times against throwaway notes
roots, one preferences domain and one Application Support (`FILAWAY_NOTES_ROOT`,
`FILAWAY_DEFAULTS_SUITE`, `FILAWAY_SUPPORT_ROOT`), kills any phase that
overstays, and never leaves the app running. `editor`, `search` and
`kill`/`killcheck` each get their own notes root; `1` and `2` share one so the
relaunch has state to restore. A single phase directly:

```
FILAWAY_SMOKE=1 FILAWAY_NOTES_ROOT=/tmp/notes build/Filaway.app/Contents/MacOS/Filaway
```

The phases drive the real objects — `AppModel`, `NoteStore`, the live
`NSTextView` — so they cover the callback chain, autosave timing, the watcher
and state restoration. Add a `check(...)` line for each new UI behaviour that
cannot be unit-tested: shell behaviour in
`Sources/FilawayApp/Features/Shell/SmokeDriver.swift`, editor behaviour in
`Sources/FilawayApp/Features/Editor/EditorSmokeCheck.swift`, search behaviour in
`Sources/FilawayApp/Features/Search/SearchSmokeCheck.swift`.

CI runs `swift build`, `swift test`, `swift run filaway-bench keyword --notes
5000` (the NFR-1 gate: non-zero at p95 ≥ 100 ms), `Tools/make_app.sh` and
`Tools/smoke.sh`.

## Layout

```
Package.swift              # single root package (no .xcodeproj — see §8)
Sources/FilawayCore/       # all logic; library; Swift 6 language mode
  Util/Log.swift           # OSLog factory, subsystem com.tejaspanse.filaway
Sources/FilawayApp/        # SwiftUI + AppKit shell; executable; Swift 5 mode
  Features/Shell/          # AppModel (owns the storage stack), ShellView,
                           #   AppSettings, SmokeDriver
  Features/Sidebar/        # Recents + Library tree (Figure 1, FR-1.2)
  Features/Editor/         # TextKit 2 editor, AutosaveController
  Features/Search/         # toolbar field, SearchCoordinator, ⌘K results panel
                           #   (Figure 2b, FR-1.3, FR-5.1/5.2)
Sources/FilawayBench/      # filaway-bench CLI (swift-argument-parser)
Tests/FilawayCoreTests/    # Swift Testing (import Testing, @Test)
Tools/                     # make_app.sh, make_dmg.sh, notarize.sh, smoke.sh
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

## Window layout (spec Figure 1)

```
┌─ toolbar ────────────────────────────────────────────────────────────────┐
│ [sidebar]        ✦ Ask anything…                 ⌘K      [square.and.pencil] │
├──────────────────────────┬───────────────────────────────────────────────┤
│ Recents                  │  August 22, 2026 · 9:41      ← date stamp     │
│   Untitled note          │  Untitled note               ← title field    │
│   Now · editing          │                                               │
│   Auth API debug  2d ago │  curl to fetch docs from staging:             │
│                          │  ┌───────────────────────────────┐ bash  Copy │
│ ✦ Library                │  │ curl -H "Auth: Bearer $TOK" … │            │
│   ▾ 📁 Commands          │  └───────────────────────────────┘            │
│       curl               │  remember: token expires hourly               │
│   ▸ 📁 Snippets          │                                               │
└──────────────────────────┴───────────────────────────────────────────────┘
```

Rules the layout encodes:

- **Recents** — at most 10, ordered by `max(lastOpened, mtime)`, title plus a
  relative timestamp, `Now · editing` while the note has unwritten text. Purely
  chronological; the AI never reorders it (FR-1.2).
- **Library** — a collapsible tree, at most two folder levels
  (`PathRules.maxFolderDepth`), root-level notes below the folders. Context
  menu: New Note, New Folder…, Rename…, Move to…, Show in Finder, Delete (to
  the Trash). Notes drag onto folders.
- **Toolbar** — sidebar toggle, the search pill (⌘K focuses it and selects its
  text; every keystroke goes to `SearchCoordinator.query(_:)`), New Note (⌘N).
- System colors and materials only, so light and dark both come for free
  (NFR-6/7). SF Symbols for every glyph; `accessibilityLabel` on every control.

## Search UI (spec Figure 2b, FR-1.3, FR-5.1, FR-5.2)

⌘K's results are a **non-focusable overlay** on the window, centred under the
toolbar's search field — not an `NSPopover` and not a separate panel. The text
field keeps first responder for the whole interaction and forwards keys to
`SearchCoordinator`, which owns `results` *and* `selectedIndex`; the panel is a
pure function of that state. Full rationale in ADR-034.

- `SearchCoordinator` (`Features/Search/`) is the whole seam: 80 ms debounce,
  one query in flight, and only the newest *generation* may publish, so a slow
  query for `cur` can never overwrite a fast one for `curl`. The empty query is
  a real query — `SearchService.keyword("")` returns Recents, which is what ⌘K
  shows before anything is typed.
- Keys: ↑/↓ move (clamped, no wrap), ⏎ opens the selection, Esc closes and
  returns focus to the editor (a second Esc clears the field), ⌘K focuses the
  field and selects its text. Every one of those is a method call on a
  `@MainActor` object, which is what lets the `search` smoke phase drive them
  with no synthetic key events.
- A row is title · folder · relative modified time, with the matched span of the
  snippet in primary bold. Opening a hit selects the note in the sidebar, loads
  it, then scrolls the editor to `KeywordHit.matchRange` and selects it — via
  `AppModel.reveal`, which `ShellView` turns into
  `MarkdownEditorController.scrollTo(range:)`. Hits inside the note already open
  work the same way. A title-only hit (`matchRange == nil`) opens at the top.
- **`SearchMode.semantic` is a declared, unimplemented extension point for
  M3-06.** Nothing in M1 sets it. The answer card and Find/Ask toggle belong at
  the `// MARK: - Extension point (M3-06)` marker in `SearchResultsPanel`.
  Keyword search must keep working with no AI and no network at all (FR-5.5).

## Current state

**M1 is complete.** Filaway is a working notes app on `~/Notes`: two-pane window
per Figure 1, Recents + Library sidebar, ⌘N, TextKit 2 styled-source editor,
750 ms autosave with flushes on switch / resign / quit, external edits
reconciled live (conflict copies announced by a banner), window frame, sidebar
width, last-open note and folder expansion restored across launches, and ⌘K
keyword search over FTS5 with open-scrolled-to-match. Storage and search are
`FilawayCore/{Storage,Index,Watch,Search}` — see `docs/core-api.md`.

The M1 Definition-of-Done walk-through, with numbers and the remaining gaps, is
`docs/verification/M1.md`. The open ones: notarization and the universal build
are blocked on Developer Program enrolment + Xcode (M4-05); the visual Figure-1/
Figure-2b and VoiceOver passes need an unlocked screen (M4-06); launch timing at
5k/20k notes is unmeasured (M4-07).

Next up: **M2** (AI organize) and **M3** (semantic search, which fills
`SearchMode.semantic`). The onboarding folder picker is M4-01, so the notes root
is `~/Notes` (override with `FILAWAY_NOTES_ROOT`) and is not yet stored as a
bookmark.
