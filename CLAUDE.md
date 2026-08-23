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
| `make bench ARGS="retrieval --embedder bge --failures"` | M3-07 retrieval gate: note top-1, MRR@10, answer-card accuracy, p95 over `Tests/Fixtures/{corpus/dev,queries/dev.json}`; exits non-zero below the bar |
| `make bench ARGS="corpus generate"` | Regenerates the committed dev corpus from `DevCorpusContent` |
| `make bench ARGS="index --notes 5000"` | Semantic index build cost (add `--embed-batch`/`--min-tokens` to probe the levers) |
| `make bench ARGS="semantic --notes 5000"` | Offline semantic query p50/p95 and the resident matrix |
| `make app` | Release build → `build/Filaway.app`, Sparkle embedded, signed |
| `make run` | `make app` then `open build/Filaway.app` |
| `make dmg` | `build/Filaway-<version>.dmg` (create-dmg, hdiutil fallback) |
| `make notarize` | Developer ID sign + notarize + staple + `spctl` (currently BLOCKED, see below) |
| `make sparkle-keys` | Create/print the EdDSA key pair Sparkle signs updates with |
| `make appcast` | `build/releases/appcast.xml`, EdDSA-signed |
| `make release VERSION=x.y.z` | test → app → dmg → notarize → appcast → GitHub Release (`DRY_RUN=1` publishes nothing) |
| `make clean` | Removes `.build/` and `build/` |

Headless UI smoke tests (no Xcode/XCTest needed, no synthetic key events —
but **the screen must be unlocked**: on macOS 26 a newly launched app gets no
window while the screen is locked, SwiftUI never builds the scene, and every
phase fails at `library-open` with no `SMOKE window …` lines. `Tools/smoke.sh`
detects it and says so):

```
make smoke          # or: Tools/smoke.sh [--keep]
# -> === smoke phase: editor ===   M1-10 editor checks, on a note read from disk
# -> === smoke phase: search ===   M1-12 ⌘K on a 3-note corpus seeded on disk
#                                  *before* launch: as-you-type hits, match and
#                                  snippet ranges, ↑↓⏎esc, open-scrolled-to-
#                                  match, fuzzy titles, recents, "No matches"
# -> === smoke phase: organize === M2 end to end on a committed replay fixture:
#                                  seed the library the fixture was recorded
#                                  against, type the session, end it at the
#                                  fixture's instant, Accept -> bytes move ->
#                                  Activity has the event + diff -> Undo
# -> === smoke phase: organize-auto === the same session in auto mode: applied
#                                  unasked, the card offers Undo, Undo restores
# -> === smoke phase: organize-offline === the provider fails with a network
#                                  error: nothing changes, the session is queued
#                                  durably, no modal, capture still works
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
# -> === smoke phase: settings === ⌘, opens Settings; the Figure 4 rows write
#                                  through AppSettings; the idle interval
#                                  clamps; AIConnectionManager walks
#                                  notConfigured -> connected -> notConfigured
# -> === smoke phase: settings2 ==  relaunch: those preferences persisted
# -> === smoke phase: paste ===    M4-03: a curl line on the real pasteboard ->
#                                  ⌘V lands it verbatim -> the affordance shows
#                                  -> Wrap fences it -> one ⌘Z undoes the wrap;
#                                  prose offers nothing; the setting disables it
# -> === smoke phase: onboarding = M4-01: the three-step flow, driven inside its
#                                  modal session: folder chosen, mock key
#                                  validated, finish writes the bookmark and the
#                                  library opens at the chosen folder
# -> === smoke phase: onboarding2  relaunch: no flow, same library
# -> === smoke phase: onboardingskip  "Skip for now" -> the gentle sidebar
#                                  prompt is visible and dismissable
# -> SMOKE result failures=0       (exit status = number of failures)
```

**Run `make smoke` only when no other agent is running it.** Two
`build/Filaway.app` processes with the same bundle id at the same time and only
one of them gets a `WindowGroup` window — the other's `editor`, `search`, `1`,
`2` and `paste` phases then all fail at `library-open`, because `ShellView.task`
(and therefore `AppModel.bootstrap()`) never runs. `settings`, `settings2` and
the onboarding flow half are unaffected: they create their windows themselves.
Check with `ps aux | grep '[F]ilaway.app/Contents/MacOS'` first.

`Tools/smoke.sh` runs `build/Filaway.app` a dozen-plus times against throwaway notes
roots, one preferences domain and one Application Support (`FILAWAY_NOTES_ROOT`,
`FILAWAY_DEFAULTS_SUITE`, `FILAWAY_SUPPORT_ROOT`), kills any phase that
overstays, and never leaves the app running. `editor`, `search`,
`kill`/`killcheck` and each `organize*` phase get their own notes root (the
organize phases get their own Application Support too, so baselines and the
Activity journal start empty); `1` and `2` share one so the relaunch has state
to restore. Every phase runs with `FILAWAY_AI_MODE=replay` and
`FILAWAY_AI_FIXTURES=Tests/Fixtures/ai-recordings`, so no phase can reach the
network (ADR-035); `organize-offline` adds `FILAWAY_AI_FAIL=network`. A single
phase directly:

```
FILAWAY_SMOKE=1 FILAWAY_NOTES_ROOT=/tmp/notes build/Filaway.app/Contents/MacOS/Filaway
```

The phases drive the real objects — `AppModel`, `NoteStore`, the live
`NSTextView` — so they cover the callback chain, autosave timing, the watcher
and state restoration. Add a `check(...)` line for each new UI behaviour that
cannot be unit-tested: shell behaviour in
`Sources/FilawayApp/Features/Shell/SmokeDriver.swift`, editor behaviour in
`Sources/FilawayApp/Features/Editor/EditorSmokeCheck.swift`, search behaviour in
`Sources/FilawayApp/Features/Search/SearchSmokeCheck.swift`, organize behaviour
in `Sources/FilawayApp/Features/Organize/OrganizeSmokeCheck.swift`.

The organize phases replay a **committed** fixture whose filename is a hash of
the whole rendered prompt, so the corpus in `OrganizeSmokeCheck` and
`AppWiringFixture` (`Tests/FilawayCoreTests/OrganizeWiringTests.swift`) must
stay in step — `wiringHitsTheCommittedFixture` pins the key so drift is a test
failure, not a mystery. Regenerate with
`FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter OrganizeWiringTests/regenerateFixture`.

CI runs `swift build`, `swift test`, `swift run filaway-bench keyword --notes
5000` (the NFR-1 gate: non-zero at p95 ≥ 100 ms), `Tools/make_app.sh` and
`Tools/smoke.sh`.

`Sources/FilawayApp/Features/Editor/EditorSmokeCheck.swift`, Settings in
`Sources/FilawayApp/Features/Settings/SettingsSmokeCheck.swift` (its phases are
dispatched from `AppDelegate`). `FILAWAY_SMOKE_SHOTS=<dir>` writes the rendered
Settings pane to a PNG — `screencapture` needs screen-recording permission this
machine has not granted.

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
  Features/Organize/       # OrganizeCoordinator (the whole M2 seam), the
                           #   Figure 2a card, Edit + View-changes sheets,
                           #   the AI status pill (FR-4.2, FR-6.4)
  Features/Activity/       # Activity window ⌥⌘A: events, diffs, Undo (FR-4.3)
  Features/Search/         # toolbar field, SearchCoordinator, ⌘K results panel
                           #   (Figure 2b, FR-1.3, FR-5.1/5.2)

  Features/Settings/       # Settings scene (⌘,): General / AI (Figure 4) /
                           #   Activity, AIStatusPill, SettingsSmokeCheck
  Features/Onboarding/     # First-run flow (Figure 3, FR-7.1): OnboardingModel,
                           #   OnboardingWindowController (AppKit), the launch
                           #   gate, the gentle "connect AI" prompt, File →
                           #   Import stub
Sources/FilawayBench/      # filaway-bench CLI (swift-argument-parser)
Tests/FilawayCoreTests/    # Swift Testing (import Testing, @Test)
Sources/FilawayApp/
  Features/Updates/        # UpdaterMenu.swift — UpdaterProviding + Sparkle 2
                           #   "Check for Updates…" (M4-04)
Tools/                     # lib.sh (versions/release.env/Sparkle paths/identity),
                           #   make_app.sh, make_dmg.sh, notarize.sh, release.sh,
                           #   smoke.sh, sparkle/{generate_keys,make_appcast}.sh,
                           #   Filaway.entitlements, release.env.example
VERSION                    # CFBundleShortVersionString fallback
.github/workflows/ci.yml   # macos-15: build, test, universal app, smoke
.github/workflows/release.yml  # tag v*: sign, notarize, DMG, appcast, Release
docs/plan.md               # Phase 1 plan (authoritative)
docs/release.md            # signing/notarization/Sparkle setup + release flow
docs/decisions.md          # ADR-lite — append every notable decision
docs/spec/                 # functional spec
```

Planned `FilawayCore` subdirectories (plan §2.7): `Storage`, `Markdown`, `Index`,
`Search`, `Session`, `Organize`, `AI`, `Embeddings`, `Activity`, `Settings`,
`Import`, `Util`.
Plus `Bench/` — the M3-07 development corpus and retrieval benchmark. It lives
in Core, not in `FilawayBench`, because a SwiftPM executable target cannot be
imported by a test target and the CI gate must measure exactly what the CLI
measures (ADR-011, ADR-042).

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
    drivers, (c) manual DoD checklists. The smoke phases need no unlocked
    *screen saver* interaction, but they do need the screen **unlocked**: a
    locked session gives a launched app no window at all (see above).
  - **Core ML `coremlcompiler` is Xcode-only** → compile `.mlpackage` at first
    launch with `MLModel.compileModel(at:)` and cache it. The embedder fallback
    ladder gains `NLContextualEmbedding` (macOS 14+) as a zero-download option.
- **No code-signing identities and no Apple Developer Program enrolment.**
  Signing, notarization and Sparkle EdDSA are blocked. `Tools/notarize.sh` runs
  every precondition check and exits with a `BLOCKED: …` message; implement
  release tasks up to the signing step and verify once credentials exist.
  **The full pipeline is written and everything not needing credentials has been
  run end to end — see `docs/release.md` for the user's unblock checklist.**
  Sparkle itself works: it resolves under 6.0.3 because its manifest is
  tools-version 5.3 and its target is a prebuilt universal xcframework
  (ADR-041). Local builds get no `SUPublicEDKey`, so the "Check for Updates…"
  item is disabled with the tooltip "Updates not configured in this build"
  (ADR-042) — that is the intended state, not a bug.
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

## Organize UI (spec Figure 2a, FR-4.2, FR-4.3, FR-6.4)

`OrganizeCoordinator` (`Features/Organize/`) is the seam, the way
`SearchCoordinator` is for ⌘K: it owns the `SessionTracker`, the `Organizer`,
the `PlanApplier`, the `ActivityLog`, `UndoService` and the durable offline
queue, and turns `OrganizerEvent`s into main-actor card state. `AppModel` builds
one after the first paint. Full wiring diagram in `docs/organize.md`.

- **The card** is a non-blocking stack at the **bottom-trailing** of the editor
  pane (ADR-036 — the top strip is `BannerView`'s, and the caret usually is not
  at the bottom). Ask mode asks — *Organize this session?* with **Accept** (⏎),
  **Edit**, **Dismiss** (⎋) — and waits as long as it takes. Auto mode states —
  *Session organized* with **Undo** and **View changes** — and fades after 20 s.
  Cards queue; none of them ever takes first responder.
- **Menu items.** Window ▸ **Activity** is ⌥⌘A (the `Window` scene's own
  shortcut). Edit ▸ **Undo Last Organization** is **⌥⌘Z** — ⇧⌘Z is Redo in every
  macOS text view including Filaway's editor, and taking it would make the
  editor lie.
- **Status.** One pill in the toolbar (`AI ready` / `AI queued · N` /
  `AI offline` / `Key invalid` / `AI paused` / `AI off`). Clicking it posts
  `.filawayOpenAISettings` for Settings to catch. No modal alerts anywhere;
  queued sessions retry on their own and survive a relaunch.
- **Settings** are read through `OrganizeSettingsSource` (keys
  `organizationMode`, `idleInterval` in minutes, `excludedFolders`) with a
  UserDefaults default, so M2-11 can substitute `AppSettings` in one line.
- **Candidates** come from `KeywordCandidateFinder` (FTS body evidence on top of
  title overlap). M3-08 replaces it behind the same `CandidateFinder` protocol.

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

**M2 is wired end to end** (M2-09/10/12): a writing session ends, the plan comes
back from the provider, the Figure 2a card appears, Accept applies it, Activity
records a diff and Undo restores every byte — proved headlessly by the
`organize`, `organize-auto` and `organize-offline` smoke phases against a
committed replay fixture. Settings → AI (M2-11) is in; the organizer still reads
`OrganizeSettingsSource` from UserDefaults (swap to `AppSettings` pending) and the
status pill's click posts `.filawayOpenAISettings`.

One known gap: FR-4.4's **raw session text is not recorded** on the automatic
path — `PlanApplying.apply(_:)` has no room for it, so nothing between the
tracker and the applier carries the text (`docs/organize.md`, "Known gap").

Next up: **M3** (semantic search, which fills `SearchMode.semantic`, and M3-08's
hybrid `CandidateFinder`). The onboarding folder picker is M4-01, so the notes
root is `~/Notes` (override with `FILAWAY_NOTES_ROOT`) and is not yet stored as
a bookmark.

**M4-04 / M4-05 are in.** Sparkle 2.9.x arrives through SPM and is embedded in
`Contents/Frameworks` by `Tools/make_app.sh`, which also writes the Sparkle
Info.plist keys, applies `Tools/Filaway.entitlements`, and signs inner-out with
`$DEVELOPER_ID` when one exists. `Tools/release.sh` (`make release`) and
`.github/workflows/release.yml` are the pipeline; every secret-dependent step in
the workflow degrades to a visible warning so it can be dispatched before
enrolment. Two Sparkle traps worth knowing, both verified by building it both
ways and both asserted in CI: `generate_appcast` signs an entry **only** when
the archived app declares `SUPublicEDKey`, and it derives
`sparkle:hardwareRequirements` from the slices in the archive, so an arm64-only
release is never offered to Intel Macs (ADR-046).

**M2-11 Settings** is in: a `Settings` scene (⌘,) with General / AI / Activity,
the AI pane built to Figure 4, and `FilawayCore/Settings/` holding `AppSettings`
(every FR-8.1 preference, typed, clamped, observable — see `docs/core-api.md`)
and `AIConnectionManager` (key validation, Keychain, `AIStatus`, monthly usage).
Two seams are left for the integration pass, both deliberate so this task did not
rewrite files other agents own:

- **`AIStatusPill`** exists in `Features/Settings/` and is not in the toolbar.
  One line in `ShellView`: `ToolbarItem(placement: .status) { AIStatusPill(status:
  …) }`, fed from `AIConnectionManager.statusChanges()`.
- **Nothing reads the preferences yet.** The Organizer, `SessionTracker` and the
  Indexer should take `CoreSettings` (the alias for `FilawayCore.AppSettings` —
  the app's own `AppSettings` shadows it, ADR-035) and subscribe with
  `observe(_:)`, reading `organizationMode`, `idleIntervalSeconds`,
  `excludedFolders`, `semanticSearchEnabled` and `effectiveOrganizeModel` /
  `effectiveSearchModel`. `SettingsModel.shared` owns the app's instances.

## Onboarding, paste intelligence, deferred stubs (M4-01 / M4-03 / M4-10)

**The first-run flow is a modal AppKit window, run before the library opens.**
`OnboardingPresenter.runIfNeeded()` is called from two places — the top of
`applicationDidFinishLaunching` *and* the first read of `AppSettings.notesRoot`
— because SwiftUI decides for itself when it builds the scene, and whichever
call comes first wins. That ordering matters: `AppModel` binds its `Library` in
`init`, so the folder question has to be answered before anything reads the
root. Two traps are recorded in **ADR-037** and both cost real time:

- **Never implement `applicationWillFinishLaunching` on the
  `@NSApplicationDelegateAdaptor` delegate.** It replaces SwiftUI's own
  implementation, the scene is never built, and no window ever appears.
- **Never host SwiftUI (`NSHostingController`) in a window shown before the
  scene exists.** It trips an AttributeGraph precondition and aborts the
  process. `OnboardingWindowController` is therefore plain AppKit.

The notes root now resolves `FILAWAY_NOTES_ROOT` → the bookmark in
`AppSettings.notesRootBookmark` → `~/Notes`, cached per launch and invalidated
by `AppSettings.setNotesRoot(_:)`. When AI is skipped, `ConnectAIPromptModel`
puts one quiet row in the sidebar footer (`aiConnectionSkipped`, dismissable per
launch) — never a modal (FR-6.4).

**Paste intelligence** (FR-2.4) classifies in Core
(`CodeLikePasteClassifier` — pure, unit-tested with a ≥25-case corpus) and
offers in the app (`Features/Editor/PasteIntelligence*.swift`). The paste always
lands verbatim; the wrap is one undo step; `AppSettings.pasteIntelligenceEnabled`
(Settings → General) turns it off. ADR-038.

**Deferred stubs.** `FilawayCore/Import/` holds the `NoteImporter` contract and
`AppleNotesImporter`, which throws `.notAvailableInThisVersion`; File → Import →
Apple Notes… is present and disabled with that message as its tooltip
(ADR-039). `<root>/_assets/` is reserved for future attachments — `PathRules`
treats it as non-note content and `NoteStore.scan` skips the subtree
(ADR-040). FR-4.7 "Reorganize library" is cut, with reasons, in ADR-041.
