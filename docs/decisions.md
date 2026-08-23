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

---

## ADR-004 — The editor runs on TextKit 2

**Date:** 2026-08-22 · **Task:** M1-10 · **Status:** accepted

**Context.** Plan §1 picks `NSTextView` (TextKit 2) for the styled-Markdown-source
editor and plan §5 lists it as risk #1, with "fall back to TextKit 1 if TK2
fragments misbehave". The two things TK2 was suspected of making hard are the
fenced-code background and the hover `Copy` overlay.

**Decision.** TextKit 2 (`NSTextView(usingTextLayoutManager: true)`), **no**
custom `NSTextStorage` subclass and **no** custom `NSTextLayoutFragment`
subclass. Instead:

- Attributes are applied from `NSTextStorageDelegate`'s
  `textStorage(_:didProcessEditing:range:changeInLength:)` over the range the
  highlighter reports as invalidated (re-entrancy guarded by a flag). TK2 keeps
  an `NSTextStorage` behind `NSTextContentStorage`, so this classic path works
  unchanged and no storage subclass is needed.
- The code-block background is drawn in `NSTextView.drawBackground(in:)` as a
  rounded rect, sized from the union of `NSTextLayoutFragment.layoutFragmentFrame`
  for the block's range (`enumerateTextLayoutFragments`), widened to the text
  container. A layout-fragment subclass would tie the drawing to element
  boundaries; drawing from the frames keeps the block a single rounded rect
  even when one block spans several fragments.
- The language tag and hover `Copy` button are ordinary `NSView`s added as
  subviews of the text view (so they scroll with the text), pooled and
  repositioned on layout, scroll, and text change. Hover is tracked with one
  `NSTrackingArea` on the text view and hit-tested against the cached block
  rects, so no per-block tracking areas.
- Only blocks overlapping the TK2 viewport range (± 4 000 characters) get a
  rect computed — computing one forces layout, so touching every block would
  make a large note O(document) per relayout.

The TextKit 1 branch survives in one place (`blockRect(for:)` falls back to
`NSLayoutManager.boundingRect(forGlyphRange:in:)`), so a downgrade is a
one-line change to the initializer, not a rewrite.

**Consequences.**
- No TK2 problems were hit: fragment frames, viewport range and
  `characterIndexForInsertion(at:)` all behave. Risk #1's "TK2 fragments
  misbehave" branch is closed.
- Measured on this machine (`FILAWAY_SMOKE=1`, release build, 50 KB note with
  723 code blocks): highlight + attribute application **0.004 ms per
  keystroke**; whole `insertText` round trip 3.1 ms mean / 3.2 ms p95 (the rest
  is AppKit's own undo + layout invalidation); decoration pass 0.68 ms
  steady-state, coalesced to at most once per run-loop turn.
- Attribute application happens inside `didProcessEditing`, so an edit that
  arrives while attributes are being applied is ignored by design (attributes
  never change characters).
- A programmatic whole-document swap (`setMarkdown`) skips the incremental path
  and re-parses once, because `isRichText = false` re-applies typing attributes
  over the whole string after `string = …`.

---

## ADR-005 — Styling is spans over the source, never a transformed document

**Date:** 2026-08-22 · **Task:** M1-10 · **Status:** accepted

**Context.** FR-2.1 leaves "renders Markdown live or shows styled text" to the
design spec; plan §1 commits to WYSIWYM — the text storage *is* the file bytes.
The temptation in every Markdown editor is to hide syntax marks or replace
`- [ ]` with a checkbox glyph.

**Decision.** `MarkdownHighlighter` (in `FilawayCore`, no AppKit) returns
**UTF-16 style spans**; the editor only ever adds attributes. Nothing is
inserted, removed, substituted or attachment-ised. Syntax marks (`#`, `**`,
backticks, fences, `[`, `](`) are dimmed to `tertiaryLabelColor`, never hidden;
clicking a checkbox rewrites the three source characters `[ ]` ↔ `[x]` through
the normal undoable edit path.

The highlighter mirrors the document as a `[UInt16]` array plus a line index
carrying the fenced-code state at each line start. An edit re-tokenizes only
the touched lines; when the fence state at the end of those lines changes it
keeps going forward until the state re-converges (the only O(document) case,
measured at 0.2 ms on 1 MB in release).

**Consequences.**
- DS-1 is trivially true: what is saved is what was typed. External edits and
  AI-applied merges reconcile as plain text.
- Offsets are UTF-16 throughout, matching `NSTextStorage`/`NSRange`, so emoji
  and other multibyte text need no conversion layer (covered by tests).
- Release perf on a 1 MB document: full parse 12.5 ms, **0.064 ms mean /
  0.088 ms p95 per edit** (debug: 2.8 ms mean, still inside the 5 ms gate).
  Both are asserted by tests in `Tests/FilawayCoreTests`.
- The highlighter is not a CommonMark parser and does not try to be: setext
  headings, reference links, HTML blocks and indented (4-space) code blocks are
  not styled. `swift-markdown` remains the source of truth for structure
  (chunking, code extraction) per plan §1.

## ADR-006 — Front-matter is a hand-rolled, lossless, minimal YAML subset

**Date:** 2026-08-22 · **Task:** M1-03 · **Status:** accepted

**Context.** DS-2 lets metadata live in front-matter *or* a sidecar; plan §1
picks the hybrid (user-meaningful fields in front-matter, derived/AI fields in
SQLite). The tolerance requirement is the hard part: a note may already carry
Obsidian, Jekyll or a colleague's script's front-matter, and Filaway must not
reformat, reorder or drop any of it. A real YAML library (Yams) would parse the
block into a dictionary and re-emit it in *its* style, silently rewriting the
user's file — and it would be a new dependency for three keys.

**Decision.** Hand-roll the codec (`FrontMatter`, `MarkdownDocument`, ~250 LOC).
The block is modelled as an ordered list of entries, each holding a key and its
**raw lines with their original terminators**. Filaway understands `id`,
`created` and `tags`; every other entry is opaque and re-emitted verbatim.
Setting a known key to the value it already holds is a no-op, so saving a note
whose metadata did not change does not perturb its bytes. Parsing never throws:
an unterminated or unparseable block is simply body text.

The invariant, asserted by a 400-case fuzz test:
`MarkdownDocument.parse(text).serialized() == text` for every input — LF, CRLF,
mixed line endings, a UTF-8 BOM, a `...` terminator, no block at all.

ISO-8601 is likewise hand-rolled (`ISO8601`): `ISO8601DateFormatter` is not
`Sendable`, and allocating one per note is measurable across a 5,000-note scan.
The formatter is checked against Foundation's over a ±60-year range.

**Consequences.**
- No Yams dependency; no reformatting of anyone's front-matter.
- The subset is deliberately narrow. Flow mappings, anchors and multi-line block
  scalars parse as opaque lines — correct, but Filaway cannot *read* values in
  those forms. If a later milestone needs to read a foreign key, extend the value
  parser, not the block model.
- `tags` accepts block sequences, flow sequences and a bare comma-separated
  scalar on read, and always writes a block sequence.

---

## ADR-007 — Notes without an `id` get a deterministic, path-derived identity

**Date:** 2026-08-22 · **Task:** M1-05 · **Status:** accepted

**Context.** DS-2 writes `id` only when *the app* saves a note, so an adopted
folder (FR-7.1) is full of notes with no identity — but the `notes` table needs a
primary key, and DS-4 move detection is defined in terms of `id`. Minting a fresh
UUID on each scan would make every scan look like a library of new notes.

**Decision.** `NoteID.derived(fromRelativePath:)` hashes the relative path into a
version-8 UUID. A scan of an id-less file yields the same identity twice, and
`isDerived(fromRelativePath:)` recomputes it, which tells the reconciler "this
file has never been saved by Filaway". Where a derived identity meets a database
row for the same path, the database's identity wins, so an external edit never
re-keys a note. Move detection falls back from `id` to content hash for these
notes. A file that *does* carry an `id` is authoritative — except when that id is
already claimed by a live path, which means the user duplicated a note: the copy
gets a fresh identity so the library never holds two notes with one id.

**Consequences.**
- An external rename *and* edit of an id-less note in one go is indistinguishable
  from delete + create, and is reported that way. It loses `last_opened` only.
  Once the app saves a note it carries an `id` and is immune.
- Derived identities are stable but not globally unique across libraries; that is
  fine — they are scoped to one database, and the first app save replaces them.

---

## ADR-008 — Atomic writes stage outside the notes root; deletes never hard-delete

**Date:** 2026-08-22 · **Task:** M1-03 · **Status:** accepted

**Context.** DS-1 says nothing but `.md` files and folders lives in the user's
tree, and NFR-3 wants crash safety. `Data.write(options: .atomic)` satisfies the
second but not the first: Foundation stages its temp file *in the destination
directory*, so a Finder window open on `~/Notes` would flicker dotfiles, and any
crash mid-write leaves one behind. NFR-5 also forbids assuming the root is on the
boot volume, so a fixed `/tmp` staging area is not safe either (cross-volume
renames are not atomic).

**Decision.** Stage in an OS-provided `.itemReplacementDirectory` obtained with
`appropriateFor:` the destination — guaranteed to be on the same volume — then
`replaceItemAt` (or `moveItem` when the file is new). Deletes go to the macOS
Trash via `FileManager.trashItem`, which returns the item's new URL for undo. On
a volume with no Trash (some network shares) the fallback is a timestamped folder
under `Library.recoveryBinURL`, never `removeItem`.

**Consequences.**
- `deleteNote` / `deleteFolder` return a `URL`; the UI can say where the note
  went, and M2-08's Undo has somewhere to look.
- Tests assert both halves: `strayEntries()` stays empty across 20 saves, and the
  trashed file's bytes are intact.

---

## ADR-009 — Echo suppression is by (path, content hash), consumed once

**Date:** 2026-08-22 · **Task:** M1-05 · **Status:** accepted

**Context.** FSEvents cannot distinguish Filaway's own autosave from the user
editing the same file in another app. Without suppression, every autosave would
bounce back into the editor as an external `.modified`, and the 750 ms autosave
debounce (FR-2.3) would produce a steady stream of spurious changes.

**Decision.** `NoteStore` records every write, move and delete in a bounded,
self-pruning `OwnOperationLedger` (path, content hash, mtime, timestamp; 30 s
TTL, 512 entries). The watcher *consumes* a matching record instead of emitting
the change — matching on path **and** content hash for writes, so a genuine
external edit that lands after our own write is not swallowed. Suppressed changes
are still applied to the database; only the emission is skipped.

**Consequences.**
- The UI needs no filtering of its own: anything on the stream is external.
- A record expires after 30 s, so a crash mid-reconcile cannot suppress a real
  change indefinitely.
- Two different apps writing byte-identical content within the TTL would be
  mistaken for an echo. Harmless: the file and the database agree either way.

---

## ADR-010 — The external-edit conflict rule is an API the UI calls, not a watcher heuristic

**Date:** 2026-08-22 · **Task:** M1-05 · **Status:** accepted

**Context.** Plan §1 (DS-4): when a file changes on disk while the app holds
unsaved edits, keep the in-app buffer and preserve the external version as
`<Title> (external edit <timestamp>).md`. The buffer lives in the editor, in the
app target — `FilawayCore` cannot see it and must not try to guess.

**Decision.** `LibraryWatcher.resolveExternalChange(noteID:inMemoryText:)` is
called by the autosave layer when it knows its buffer is dirty. It writes the
external bytes to the conflict copy **with a fresh `id`** (otherwise the library
would hold two notes with one identity), saves the buffer over the original path,
emits `.conflict` plus an `.added` for the copy, and updates the database. It is
a no-op when the buffer matches the file, and it simply restores the buffer when
the file was externally deleted.

**Consequences.**
- M1-11 (autosave) owns the "am I dirty?" decision and must call this on a
  `.modified`/`.removed` for the open note.
- Repeated conflicts in the same minute get ` 2`, ` 3` suffixes from the normal
  collision ladder, so nothing is overwritten.
- The timestamp is `yyyy-MM-dd HHmm` in the *local* time zone, which is what the
  user sees in Finder.

---

## ADR-011 — Corpus generation lives in `FilawayCore`, not the bench target

**Date:** 2026-08-22 · **Task:** M1-05 / M1-07 · **Status:** accepted (revisit at M1-07)

**Context.** Plan §4 puts the corpus generator in `filaway-bench`, but a SwiftPM
executable target cannot be imported by a test target, and the NFR-2 scale test
needs exactly the same corpus as the benchmark for the numbers to be comparable.

**Decision.** `SyntheticCorpus.generate(noteCount:into:…)` lives in
`FilawayCore/Util`, seeded by a deterministic SplitMix64 PRNG. `filaway-bench
scan` and `ScaleTests` both call it.

**Consequences.**
- A little development-support code ships in the library. It is ~120 lines, pure
  Foundation, and M1-07 extends it for the keyword and retrieval corpora.
- Release-build numbers (M-series, 2026-08): 5,000 notes / 48 MB scan 413 ms +
  rebuild 191 ms; 20,000 notes 1.62 s + 751 ms. `ScaleTests` gates the 5,000-note
  case at 3 s on a debug build, where it currently runs in ~1.1 s.

---

## ADR-012 — Autosave is a Core state machine with an app-side timer

**Date:** 2026-08-23 · **Task:** M1-11 · **Status:** accepted

**Context.** FR-2.3/NFR-3 make autosave the one thing that must never lose text:
750 ms debounce, flush on note switch / window resign key / app resign active /
terminate, and the ADR-010 conflict route when the file changed under a dirty
buffer. Timing rules verified by sleeping in a test are slow and flaky, and
`FilawayCore` may not import AppKit, so the obvious "actor with a timer" would
have been untestable where it matters.

**Decision.** `FilawayCore/Session/AutosaveScheduler` is a pure state machine:
`bufferChanged(…, at:)` takes the clock as a parameter, `jobsDue(at:)` /
`flushAll(trigger:)` / `flush(noteID:trigger:)` return `AutosaveJob` values, and
`finish(_:)` / `fail(_:)` report the outcome. It owns no timer and no file
handle. `FilawayApp/Features/Editor/AutosaveController` supplies the `Timer`
(in `.common` mode) and performs the writes against `NoteStore`.

**Consequences.**
- Every rule is a fast, deterministic Swift Testing case, including the two that
  matter most: a keystroke landing mid-write leaves the note dirty at the newer
  text (`finish` returns false on a stale revision), and a terminate flush
  replays notes in the order they went dirty.
- `AutosaveJob` carries a `revision`, so the controller can be naive.
- The debounce is the scheduler's, so M2-03's session tracker can call
  `flushNow()` without knowing about timers.

---

## ADR-013 — Launch paints from the database, then reconciles

**Date:** 2026-08-23 · **Task:** M1-09 / M1-13 · **Status:** accepted

**Context.** NFR-1 wants a window that is visible and editable fast, but DS-4
wants a full stat-scan of the notes folder on launch, which is ~400 ms at 5,000
notes (and seconds at 20,000).

**Decision.** `AppModel.init` does no I/O. `bootstrap()` opens `NoteStore`,
opens GRDB on a detached task, subscribes to the watcher's change stream, then
paints the sidebar and restores the last note **from `MetadataStore` alone** —
`recents()`, `tree()` and `note(id:)` never touch the disk. Only afterwards does
a background task run `watcher.reconcile()` and `watcher.start()`; the sidebar
is refreshed again if that produced changes.

**Consequences.**
- Observed on this machine (release build, empty library): window visible ~230
  ms, editor ready ~240 ms, both from the kernel's process start time.
- The first frame can be up to one reconcile stale. Since the reconcile emits
  ordinary `LibraryChange` values, the sidebar corrects itself through the same
  code path as any external edit — no special first-launch handling.
- Restoring the last note counts as opening it, so it leads Recents after a
  relaunch (FR-1.2 orders by `max(lastOpened, mtime)`).

---

## ADR-014 — The quit-time flush runs off the main actor

**Date:** 2026-08-23 · **Task:** M1-11 · **Status:** accepted

**Context.** FR-2.3 requires that quitting waits for unwritten buffers, and the
write path is `async` (it goes through the `NoteStore` actor). Neither obvious
approach works. Returning `.terminateLater` and calling
`reply(toApplicationShouldTerminate:)` from a `Task` deadlocks: AppKit waits in
a private run-loop mode that never runs main-actor jobs. Pumping the run loop
from inside `applicationShouldTerminate` deadlocks too, because the main
dispatch queue will not drain reentrantly. Both were reproduced with the smoke
driver, which hung until its watchdog killed it.

**Decision.** `AutosaveController.terminateFlush()` snapshots the main-actor
keystroke buffers synchronously, then returns a `Task.detached` that touches
only actors (`AutosaveScheduler`, `NoteStore`, `LibraryWatcher`).
`applicationShouldTerminate` blocks the main thread on a `DispatchSemaphore`
with a 5 s budget and returns `.terminateNow`.

**Consequences.**
- The main thread blocking is safe precisely because the flush never needs it.
- A wedged write cannot prevent quitting; it is logged and the app exits.
- This is also why `AutosaveController` keeps its own main-actor `pending`
  dictionary: a burst typed in the same run-loop turn as ⌘Q has not reached the
  scheduler actor yet, and the snapshot picks it up. `smoke.sh` phase 1 types a
  line and quits immediately; phase 2 asserts it came back.
