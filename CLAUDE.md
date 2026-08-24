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
| `make bench ARGS="churn --root DIR --seconds 60"` | M4-08 DS-4 stress: the real watcher against a folder `Tools/fs_churn.sh` is hammering; non-zero on loss, duplicates, untracked moves or a stray file |
| `make bench ARGS="index --root <notes> --with-queries"` | M4-07: searches at `.userInitiated` while the index builds — the "is ⌘K usable on a first launch?" number |
| `make bench ARGS="launch --library <notes> --runs 5"` | M4-07 NFR-1: launches `build/Filaway.app` five times and reports the p50 of each launch stage (`--warm` primes the database first). Needs `make app` |
| `make bench ARGS="retrieval-log summarize"` | M4-11: hit rate and median seconds over the Help → Log Retrieval Outcome… dogfood log (spec §8) |
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
detects it and says so. `SmokeDriver` opens the library itself when the scene
never arrives, so everything that does not need a view — search, semantic,
settings — still runs; only the phases that type into the live `NSTextView`
fail):

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
# -> === smoke phase: settings-wiring === M4-02: a preference reaching the live
#                                  objects — mode and model to the Organizer
#                                  actor, the interval to SessionTracker, an
#                                  exclusion to both the organizer and the index
#                                  (already-indexed chunks purged), the semantic
#                                  switch to ⌘K's Ask mode, Rebuild index
# -> === smoke phase: a11y ===     M4-06: a walk of the live accessibility tree
#                                  (no unlabelled control, no unlabelled visible
#                                  image), the walk audited against a synthetic
#                                  broken window first, plus light/dark captures
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
# -> === smoke phase: onboarding-ollama  P2-03: Figure 3's local-model card is
#                                  selectable, Test connection succeeds against
#                                  an injected validator (no daemon), Continue
#                                  unlocks, Finish writes ai.provider /
#                                  ai.ollama.baseURL / ai.ollama.model
# -> === smoke phase: onboarding-ollama2  relaunch: the provider persisted
# -> === smoke phase: organize-ollama === GATED. The organize session against a
#                                  *live* local model: only with
#                                  FILAWAY_SMOKE_OLLAMA=1 and a daemon answering
#                                  localhost:11434, else "SKIPPED (no Ollama)"
#                                  and not a failure
# -> === smoke phase: semantic === M3-06: ⌘K Ask on a corpus with fixed mtimes:
#                                  ⏎ -> answer card, Copy -> pasteboard, ⏎ ->
#                                  the note scrolled to the chunk, the temporal
#                                  filter, and the offline notice
# -> SMOKE result failures=0       (exit status = number of failures)
```

**If a phase produces *no output at all* and dies at its timeout, it is not the
lock screen — it is macOS's crash-history alert.** The suite SIGKILLs the app on
purpose (the `kill` phase, and the watchdog on any phase that overstays), so
Filaway accumulates a crash history by design; `NSPersistentUIRestorer` then puts
up a modal "reopen its windows?" alert from inside `_handleAEOpenEvent`, before
`applicationDidFinishLaunching` runs and with nobody to answer it. The phase
hangs, the watchdog kills it, and *that* adds another crash — once it starts it
never stops. `Tools/smoke.sh` passes `-ApplePersistenceIgnoreState YES` to every
launch, which skips the machinery entirely (M4-06). `sample <pid>` on a wedged
phase names it in one line.

**Run `make smoke` only when no other agent is running it.** Two
`build/Filaway.app` processes with the same bundle id at the same time and only
one of them gets a `WindowGroup` window — the other's `editor`, `search`, `1`,
`2` and `paste` phases then all fail at `library-open`, because `ShellView.task`
(and therefore `AppModel.bootstrap()`) never runs. `settings`, `settings2` and
the onboarding flow half are unaffected: they create their windows themselves.
Check with `ps aux | grep '[F]ilaway.app/Contents/MacOS'` first.

`SmokeDriver.openLibraryIfTheSceneDidNot()` softens that: when no scene has
arrived by the time a phase starts, the driver opens the library itself
(idempotent — `bootstrap()` returns early once the store exists). Everything
that does not need a view then still runs, including `search`, `semantic` and
`settings`; only the phases that type into the live `NSTextView` fail.

`Tools/smoke.sh` runs `build/Filaway.app` a dozen-plus times against throwaway notes
roots, one preferences domain and one Application Support (`FILAWAY_NOTES_ROOT`,
`FILAWAY_DEFAULTS_SUITE`, `FILAWAY_SUPPORT_ROOT`), kills any phase that
overstays, and never leaves the app running. `editor`, `search`,
`kill`/`killcheck`, `semantic` and each `organize*` phase get their own notes
root (the organize phases get their own Application Support too, so baselines
and the Activity journal start empty); `1` and `2` share one so the relaunch has
state to restore. The `semantic` corpus is seeded with **fixed mtimes**, so
FR-5.3's "two days ago" has exactly one note to find. Every phase runs with `FILAWAY_AI_MODE=replay` and
`FILAWAY_AI_FIXTURES=Tests/Fixtures/ai-recordings`, so no phase can reach the
network (ADR-035); `organize-offline` adds `FILAWAY_AI_FAIL=network`. The one exception is the
gated `organize-ollama` phase, which runs `FILAWAY_AI_MODE=live
FILAWAY_AI_PROVIDER=ollama` against the local daemon — the harness axis and the
backend axis are independent (ADR-069). A single phase directly:

```
FILAWAY_SMOKE=1 FILAWAY_NOTES_ROOT=/tmp/notes build/Filaway.app/Contents/MacOS/Filaway
```

The phases drive the real objects — `AppModel`, `NoteStore`, the live
`NSTextView` — so they cover the callback chain, autosave timing, the watcher
and state restoration. Add a `check(...)` line for each new UI behaviour that
cannot be unit-tested: shell behaviour in
`Sources/FilawayApp/Features/Shell/SmokeDriver.swift`, editor behaviour in
`Sources/FilawayApp/Features/Editor/EditorSmokeCheck.swift`, search behaviour in
`Sources/FilawayApp/Features/Search/SearchSmokeCheck.swift`, semantic search in
`Sources/FilawayApp/Features/Search/SemanticSmokeCheck.swift`, organize behaviour
in `Sources/FilawayApp/Features/Organize/OrganizeSmokeCheck.swift`.

The organize phases replay a **committed** fixture whose filename is a hash of
the whole rendered prompt, so the corpus in `OrganizeSmokeCheck` and
`AppWiringFixture` (`Tests/FilawayCoreTests/OrganizeWiringTests.swift`) must
stay in step — `wiringHitsTheCommittedFixture` pins the key so drift is a test
failure, not a mystery. Regenerate with
`FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter OrganizeWiringTests/regenerateFixture`.

The `semantic` phase scripts its provider instead of replaying: a replay key
hashes the rendered prompt, and the prompt carries the *indexed* chunks, so a
committed fixture would break the first time the chunker or the embedder moved
(ADR-056). The prompt→tool contract is pinned offline by `AnswerGoldenTests`.

CI runs `swift build`, `swift test`, `swift run filaway-bench keyword --notes
5000` (the NFR-1 gate: non-zero at p95 ≥ 100 ms), `Tools/make_app.sh` and
`Tools/smoke.sh`.

`Sources/FilawayApp/Features/Editor/EditorSmokeCheck.swift`, Settings in
`Sources/FilawayApp/Features/Settings/SettingsSmokeCheck.swift` (its phases —
`settings`, `settings2`, `settings-wiring`, `a11y` — are dispatched from
`AppDelegate`). `FILAWAY_SMOKE_SHOTS=<dir>` writes the rendered panes to PNGs,
in both appearances during the `a11y` phase — `screencapture` needs
screen-recording permission this machine has not granted, but a view's own
`cacheDisplay` bitmap needs neither that nor a visible window. The PNGs land in
`smoke.sh`'s throwaway work directory and are **never committed**; `--keep` is
how a human gets at them.

`make smoke` also greps its own transcript for AppKit's "reentrant operation in
its NSTableView delegate" and counts it (M4-06). It reports rather than fails —
the warning predates the guard and is not fixed — but the count is the
regression signal. It can only mean something where there is a window, so with
no scene it says so rather than claiming a pass.

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
  Features/Diagnostics/    # DiagnosticsMenu.swift — Help ▸ "Export
                           #   Diagnostics…" + save panel (M4-08)
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
docs/diagnostics.md        # what Filaway tells you about itself (NFR-4, M4-08)
docs/verification/         # per-milestone DoD walk-throughs, with numbers
docs/spec/                 # functional spec
```

Planned `FilawayCore` subdirectories (plan §2.7): `Storage`, `Markdown`, `Index`,
`Search`, `Session`, `Organize`, `AI`, `Embeddings`, `Activity`, `Settings`,
`Import`, `Util`. Plus `Diagnostics/` (M4-08) — the NFR-4 export, its redactor, and
`MaintenanceScheduler`.
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
   text into `Logger` only with `privacy: .private`. **A path is a title**
   (DS-1 makes the filename the title), so a path under the notes root is note
   content too — `DiagnosticsRedactor` collapses them to `<notes-root>/…`. See
   `docs/diagnostics.md`.
8. **No fixed sleeps in tests.** Waiting for something to appear is
   `waitUntil`; proving something did *not* appear is a barrier through the same
   queue. Perf budgets are best-of-N, because NFR-1/NFR-2 describe the machine,
   not the worst moment of a parallel test run. `swift test` five times in a row
   is the bar (M4-08).
9. Bundle id and OSLog subsystem are both `com.tejaspanse.filaway`
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
- **`SearchMode.semantic` is live (M3-06).** Typing is always keyword; ⏎ on a
  multi-word query, one ending in "?" or starting with a wh-word switches to Ask
  and runs it, and a Find/Ask toggle in the panel header is the explicit
  override (remembered for the session). Ask is two-staged — the local hybrid
  ranking paints immediately, the answer card upgrades it when the extractor
  returns — so nothing ever blocks on Claude. The card is *item 0* of the
  selection: ↑/↓ walk it, ⏎ opens the note scrolled to its chunk, ⌘C copies the
  snippet. Keyword search keeps working with no AI and no network at all
  (FR-5.5), and so does semantic *retrieval*: only the card needs a provider.
  `SemanticSearchCoordinator` owns the embedder/index/vectors/hybrid/extractor
  stack and is fed from autosave, the watcher and `excludedFolders`. See
  ADR-054…056.

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
  editor lie. Help ▸ **Log Retrieval Outcome…** is **⌃⌥⌘L** (M4-11).
- **Status.** One pill in the toolbar — `Features/Settings/AIStatusPill`, hosted
  by `ShellView.AIStatusPillHost`. It draws *nothing* when connected with an
  empty queue, and otherwise `Queued · N` / `AI offline` / `Key rejected` /
  `Rate limited` / `Connect AI`. Clicking it posts `.filawayOpenAISettings`,
  which `SettingsWindow.observeOpenRequests()` turns into Settings → AI. No
  modal alerts anywhere; queued sessions retry on their own and survive a
  relaunch (ADR-059).
- **Settings** are read through `OrganizeSettingsSource`, whose only
  implementation is now `CoreOrganizeSettings` over `CoreSettings` (M4-02). The
  coordinator's `observe(_:)` subscription pushes every change at
  `SessionTracker`, `Organizer` and `PlanApplier` — FR-8.1's "applies live".
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
Figure-2b and VoiceOver passes need an unlocked screen (M4-06). **Launch timing
is now measured** — `docs/verification/M4-perf.md`.

**M3-05/06/08 are in.** `FilawayCore/Search/Answer*.swift` turns
`SemanticResults.promptChunks` into Figure 2b's answer card via `answer.v1` and
the strict `answer_selection` tool on Haiku 4.5, inside a 5 s budget with a
local heuristic behind it; `SemanticSearchService` is the façade the ⌘K panel
calls, and `Organize/HybridCandidateFinder` swaps the organizer's merge-target
retrieval onto the same hybrid ranker (M3-08). See `docs/core-api.md`
§ "Answers" and `docs/organize.md` § "Finding candidates".

**M2 is wired end to end** (M2-09/10/12): a writing session ends, the plan comes
back from the provider, the Figure 2a card appears, Accept applies it, Activity
records a diff and Undo restores every byte — proved headlessly by the
`organize`, `organize-auto` and `organize-offline` smoke phases against a
committed replay fixture. Settings feeds it live (M4-02, below).

That gap is closed: FR-4.4's raw session text now reaches the Activity row on
both paths (`PlanApplying.apply(_:sessionText:)` with a dropping default;
`docs/organize.md`).

The onboarding folder picker is M4-01, so the notes root is `~/Notes` (override
with `FILAWAY_NOTES_ROOT`) and is not yet stored as a bookmark.

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

**M4-08 reliability hardening is in.** Crash tests for `NoteStore` (a `kill -9`
between the staged write and the rename), `PlanApplier` and `UndoService`; a
`filaway.sqlite` whose bytes are not a database is quarantined as
`<name>.corrupt-<ts>` by `DatabaseFile.open` and the derived half rebuilt from
the folder (**but the Activity history in that same file is not derived** —
ADR-049); 1,200 fuzz cases proving a rejected plan writes nothing and an
accepted one undoes to a byte-identical tree; `MaintenanceScheduler` running
FR-4.4's prune once a day; and Help ▸ **Export Diagnostics…**, whose NFR-4 test
plants a sentinel in a note body, a note filename, a setting, a log line and a
crash report and asserts it is in no file of the zip. Numbers, the two bugs it
found, and the remaining gaps: `docs/verification/M4-reliability.md`.

**Settings is complete and wired (M2-11 + M4-02).** A `Settings` scene (⌘,) with
General / AI / Activity, the AI pane built to Figure 4, and
`FilawayCore/Settings/` holding `AppSettings` (every FR-8.1 preference, typed,
clamped, observable — see `docs/core-api.md`) and `AIConnectionManager` (key
validation, Keychain, `AIStatus`, monthly usage). M4-02 closed every seam M2-11
and M2-12 left open — **there is no longer a UserDefaults stand-in anywhere**:

- The organize pipeline reads `CoreSettings` through `CoreOrganizeSettings` and
  subscribes with `observe(_:)`. Mode, idle interval, excluded folders and
  `effectiveOrganizeModel` reach `SessionTracker.setConfiguration`,
  `Organizer.setSettings` and `PlanApplier.setExcludedFolders` live, no relaunch.
  Probe what the actors actually hold with
  `OrganizeCoordinator.organizerSettingsProbe()` / `sessionConfigurationProbe()`.
- The toolbar carries `AIStatusPill`, fed by `OrganizeCoordinator.status` (which
  folds in `AIConnectionManager.statusChanges()`) plus the queue depth.
  `AIStatusIndicator` is gone — ADR-059.
- `.filawayOpenAISettings` has one listener,
  `SettingsWindow.observeOpenRequests()`, which opens Settings on the AI tab.
  Address a tab from outside with `SettingsWindow.open(tab:)`.
- Settings → General: notes-folder **Change…** (`AppModel.reopenLibrary(at:)` —
  it *opens* a library and moves nothing, ADR-058), Show in Finder, FR-5.4's
  Rebuild index with progress off `IndexStatus`.
- Settings → Activity embeds the last five events and opens the ⌥⌘A window.
- `semanticSearchEnabled` off parks the indexer and drops ⌘K out of Ask mode;
  excluding a folder purges what is already indexed
  (`SemanticSearchCoordinator.purgeExcluded`) — `catchUp()` structurally cannot,
  because an unchanged note is never stale (`ExclusionPurgeTests`).

**M4-06's accessibility and HIG pass is in.** `docs/a11y-checklist.md` is the
audit, item by item, and is explicit about what the `a11y` smoke phase proves
versus what needs a person at an unlocked screen with VoiceOver on.
`Features/Settings/AccessibilityAudit.swift` walks a window's live accessibility
tree and fails on any unlabelled control (ADR-060). The M1 launch warning
"reentrant operation in its NSTableView delegate" is **not fixed**, but it is
now measured and bounded: `make smoke` keeps a transcript and counts it, and
the count says it is once per *population of the sidebar `List`* (empty library:
zero; seeded: one; `semantic`, which repopulates repeatedly: four). Everything
schedulable has been ruled out — see `docs/a11y-checklist.md` § 5 for the full
list and the one experiment left, which needs a debugger that can attach to an
ad-hoc-signed bundle.

**M4-07 / M4-09 / M4-11 are in.** Four verification documents carry the numbers
and the walk-throughs; read them before re-measuring anything:

- `docs/verification/M4-perf.md` — launch (**374 ms to editable at 20,000
  notes**, against NFR-1's 2 s), the first-launch index (52 s at 5k, 235 s at
  20k, now at `.utility` and most-recently-modified first), what ⌘K costs
  *while* that runs (p95 79 ms at 20k, never zero results), app RSS at scale,
  the thresholds where behaviour changes, and which checks CI gates.
- `docs/verification/M2.md`, `docs/verification/M3.md` — the M2 and M3
  Definition-of-Done lists walked clause by clause, with the test name or smoke
  phase that proves each one. Two things are outright failing and both are small:
  FR-4.4's raw session text is never recorded on the automatic path
  (`docs/organize.md` § "Known gap"), and `Settings → Rebuild index` is a
  disabled button with a working `SemanticSearchCoordinator.rebuildAll()`
  behind it.
- `docs/verification/success-criteria.md` — the spec §8 protocol: the
  install→typing stopwatch and the one-week retrieval log.
- `docs/prompts.md` — `organize.v1` / `answer.v1` are frozen; the bump rule,
  how to re-record with a key, and **the list of assumptions no test on this
  machine can falsify** (strict `anyOf`, `["integer","null"]`, adaptive thinking
  with a forced tool, Haiku latency).
- `docs/cost.md` — **~$16/month** for 15 sessions + 30 searches a day, and the
  one unpulled lever (prompt caching would save ~30% of it).

**M4-07's retrieval lever.** `Search/TypoExpansion.swift` repairs query words
whose document frequency is zero, using FTS5's own term index through the new
`v6-vocab` `fts5vocab` view. Typos went 57% → **100%** top-1 and the corpus
overall 91% → **95%**, with nothing regressing (ADR-058).
`filaway-bench retrieval --no-typo-expansion` reproduces the old numbers.

**The real cause of "no MarkdownEditorView", and it is not a locked screen.**
After a run that kills the app — every smoke run, every launch bench — macOS
decides Filaway has a crash history and opens *"Do you want to try to reopen its
windows?"*: an `NSAlert` shown **before** `applicationDidFinishLaunching`, so
SwiftUI never builds the scene, the app prints nothing at all, and the phase
hangs or fails at `library-open`. On a locked screen the dialog is invisible,
which is why it read as a lock problem for so long. The fix is
`-ApplePersistenceIgnoreState YES` plus deleting
`~/Library/Saved Application State/com.tejaspanse.filaway.savedState`;
`Tools/smoke.sh` and `filaway-bench launch` both do it. With it, the window
arrives reliably in a headless session and launch timing is measurable
(`docs/verification/M4-perf.md` §1.3).

## Onboarding, paste intelligence, deferred stubs (M4-01 / M4-03 / M4-10)

**The first-run flow is a modal AppKit window, run before the library opens.**
`AppDelegate` calls `OnboardingPresenter.scheduleIfNeeded()` and
`AppModel.bootstrap()` awaits `waitUntilAnswered()` before it resolves anything.
Reading `AppSettings.notesRoot` deliberately does **not** run the gate any more.
Four traps here, all of them measured, and each one costs a launch that comes up
with no window at all (**ADR-037**, **ADR-049**, **ADR-061**):

- **Never run the modal from inside a SwiftUI update.** That is what "whoever
  reads the root first runs the gate" turned into: `AppModel.shared` is forced
  from `StateObject.Box.update`, and a nested `NSApp.runModal` there wedges the
  AttributeGraph — `NSApp.windows` comes out empty and `ShellView.task` never
  runs. `applicationDidFinishLaunching` is no better: SwiftUI is called there
  from inside `_handleAEOpenEvent:`, and the modal crashes the scene instead.
- **Nothing may resolve the notes root before the gate.** `AppModel.library` is
  resolved on first use, `SettingsModel.shared` is built in `bootstrap()` rather
  than from the App body, and the welcome pane names the folder only once one
  exists. A new eager reader reintroduces the bug silently — the `onboarding`
  and `onboardingskip` phases are what catch it.
- **Never implement `applicationWillFinishLaunching` on the
  `@NSApplicationDelegateAdaptor` delegate.** It replaces SwiftUI's own
  implementation, the scene is never built, and no window ever appears.
- **Never host SwiftUI (`NSHostingController`) in a window shown before the
  scene exists.** It trips an AttributeGraph precondition and aborts the
  process. `OnboardingWindowController` is therefore plain AppKit — and it sets
  `isReleasedWhenClosed = false`, because ARC owns that window and AppKit
  releasing it again crashes the next CA transaction flush.

`scheduleIfNeeded()` uses `RunLoop.main.perform`, not `DispatchQueue.main.async`:
a nested run loop drains the main dispatch queue only when it was not started
from inside a main-queue block, and a `@MainActor` job is one.

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
