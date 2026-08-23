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

## ADR-012 — Semantic search ships a bundled Core ML bge-small; NaturalLanguage is not a real fallback

**Date:** 2026-08-22 · **Task:** M1-08 (spike, plan §5 risk #4) · **Status:** accepted

**Context.** Plan §1 chose local Core ML embeddings (Anthropic has no
embeddings API) with a bge-small ↔ MiniLM decision deferred to M3-07, and plan
§8 added `NLContextualEmbedding` to the fallback ladder because this machine has
no Xcode and therefore no `coremlcompiler`. None of it had been tried.
Full measurements: `docs/spikes/embedder.md`.

**Decision.**

1. **Ship `BAAI/bge-small-en-v1.5`** converted with `coremltools` to a fixed
   `[1, 256]` fp16 ML Program with CLS pooling and L2 normalisation baked into
   the graph (63.5 MB; 57.9 MB compressed). `all-MiniLM-L6-v2` (43 MB, ~1.5×
   faster) stays converted and benchmarked as a one-line swap for M3-07.
2. **Ship the `.mlpackage`, not a `.mlmodelc`**, and compile it at first launch
   with `MLModel.compileModel(at:)` into Application Support. Measured cost:
   47–86 ms, once. Plan §8's workaround has no downside — adopt it permanently,
   not just until Xcode is installed.
3. **Batch 1, not batch 8.** Core ML pipelines an `MLArrayBatchProvider` over a
   batch-1 package as well as a batch-8 package does (4.06 vs 4.95 ms per
   embedding) without the 10× penalty on single-query latency.
4. **Demote the NaturalLanguage embedders.** `NLContextualEmbedding`
   (mean-pooled) and `NLEmbedding.sentenceEmbedding` answered 4/20 spike queries
   at rank 1, against 20/20 for both Core ML models and 16/20 for a plain BM25
   baseline. They stay implemented behind `Embedder`, but the real degradation
   path is **keyword-only FTS5 + Claude rerank**, which is measurably better
   than either.
5. **Pin the conversion toolchain** (`coremltools==9.0`, `torch==2.7.0`,
   `transformers==4.56.2`, Python 3.11) and **gate every conversion on a
   torch↔Core ML cosine ≥0.999**.

**Consequences.**
- Bundle grows by ~64 MB (plan §1 budgeted 35–65 MB); installs also spend ~64 MB
  in Application Support for the compiled model. Palettization (8-bit ≈ 33 MB)
  is the lever if that becomes a release blocker, gated on an M3-07 re-run.
- `fp16 + transformers' -3.4e38 attention mask = NaN`, silently and
  shape-dependently (every time at seq 64, never at seq 256). `convert.py` now
  overrides the mask with -1e4; the parity check is what caught it, so
  `--skip-golden` must not be used for anything shippable.
- Fixed sequence length makes short and long inputs cost the same, so **chunk
  size is a throughput decision**: M3-02 should target 180–250 tokens using
  `CoreMLEmbedder.tokenCount(_:)`, and a seq-64 bucket is available at 2× the
  throughput if short chunks dominate.
- Intel remains unmeasured on real hardware (no Intel Mac, and universal builds
  need Xcode). CPU-only on the M2 costs bge-small 6.6× on single embeddings and
  1.8× batched, while MiniLM costs only 1.3× — if Intel first-run indexing is
  too slow, the answer is MiniLM on Intel. M3-09/M4-07 must re-measure.
- 20k notes × ~4 chunks ≈ 80k embeddings ≈ 5.4 min of one-time indexing on an
  M2, and 61 MB of Float16 vectors in memory — plan §1's brute-force Accelerate
  matrix holds; `sqlite-vec` stays a Phase-2 option.
- The spike corpus (40 notes / 20 queries) is directional only. The ≥90% top-1
  gate remains M3-07's job on a generated 5k/20k corpus.

## ADR-013 — AI usage lives in its own SQLite file, not in `filaway.sqlite`

**Date:** 2026-08-22 · **Task:** M2-01 · **Status:** accepted

**Context.** FR-6.6 wants a monthly token/request indicator in Settings. The
obvious home is a migration on `MetadataStore`, but `DatabaseSchema.migrator`
already reserves `v2-fts` (M1-06), `v3-chunks` (M3-02) and `v4-activity`
(M2-08) — three milestones being built in parallel worktrees, all appending to
the same registry. More importantly, `filaway.sqlite` is *derived*: `Settings →
Rebuild index` may delete it wholesale, and usage history is not rebuildable
from the notes folder.

**Decision.** `AIUsageLedger` opens
`<supportDirectory>/ai-usage.sqlite` with its own one-migration registry
(`v1-ai-usage`). One table: timestamp, model, purpose, provider, the four token
counts, request id.

**Consequences.**
- Rebuilding the index cannot lose the user's spend history.
- Two database files in the support directory instead of one; both are opened
  lazily and neither blocks launch.
- Replayed and mocked traffic is recorded with its own `provider` value and
  excluded from billed totals by default, so a test run cannot inflate the
  counter.

---

## ADR-014 — Versioned prompts are `FilawayCore` resources, not a top-level `Prompts/`

**Date:** 2026-08-22 · **Task:** M2-01 · **Status:** accepted

**Context.** Plan §2.7 sketches a repository-root `Prompts/` folder "copied as
Core resources". SwiftPM can only declare resources that live *inside* the
target directory, and plan §8 removed the build step (Xcode) that would have
done the copying.

**Decision.** Prompt text lives in `Sources/FilawayCore/AI/Prompts/` as
`<id>.v<N>.txt`, declared with the package's single `resources: [.copy(…)]`
entry and loaded by `PromptLibrary.text(_:in:)` from `Bundle.module`. An
explicit directory argument or `$FILAWAY_PROMPTS_DIR` overrides the bundle, so
`filaway-bench prompts --live` can iterate on wording without a rebuild.
`PromptVersion` (`organize.v1`) is the identity recorded on every plan.

**Consequences.**
- M2-06 writes `Sources/FilawayCore/AI/Prompts/organize.v1.txt`; M3-05 writes
  `answer.v1.txt`. No `Package.swift` change is needed for either.
- `plan-format.v1.txt` ships now: it states the closed-action-set contract that
  `OrganizationPlan.toolSchema` encodes, and `organize.v1` will include it.

---

## ADR-015 — Replay fixtures are keyed by a canonical request hash and store wire bodies

**Date:** 2026-08-22 · **Task:** M2-02 · **Status:** accepted

**Context.** CI must exercise the whole organize pipeline with no API key
(plan §4), and a fixture that silently goes stale after a prompt edit would be
worse than no fixture.

**Decision.** `FILAWAY_AI_MODE` is `replay` (default) | `record` | `live`. A
fixture lives at `Tests/Fixtures/ai-recordings/<purpose>/<key>.json`, where
`key` is a 16-hex digest of the canonicalised request — model, system,
messages, tools, tool choice, sorted-key JSON. Token caps, thinking depth,
effort and timeouts are deliberately *not* in the digest: they are execution
knobs, not part of what was asked. The file holds the decoded `AIRequest`, the
exact wire request body, and the exact wire **response** body.

**Consequences.**
- Editing a prompt changes the key, so replay misses loudly
  (`AIError.missingRecording` names the file and the command to record it)
  rather than replaying an answer to a different question.
- Hand-authored fixtures exercise the real decoder, because what is stored is
  the API's JSON, not our model.
- Storing the request body is what makes the FR-4.5 assertion possible: a test
  greps every committed fixture for excluded note titles and text.

---

## ADR-016 — Merge is `moveSegment`, and the plan carries the segment text verbatim

**Date:** 2026-08-22 · **Task:** M2-04 · **Status:** accepted (implements plan §1 amendment 1)

**Context.** FR-4.1 asks for "append/merge session content into an existing
note"; FR-4.4 forbids deleting user content. Plan §1 amendment 1 resolves this
as "merge = move segment", but leaves open how apply can be sure it is moving
what the model actually saw.

**Decision.** `PlanAction.moveSegment` carries the segment **text**, an optional
SHA-256 of it, and an advisory character range. `PlanValidator` requires the
segment to appear byte-for-byte in the source note's body; if the body was not
loaded, the check downgrades to a warning and M2-07's apply re-runs it. The
whole closed action set is additive by construction — there is no case that
deletes or replaces text — and `PlanAction.neverDeletesUserText` switches
exhaustively so a future destructive case cannot be added by accident.

**Consequences.**
- A paraphrased segment fails validation instead of silently rewriting a note.
- Apply (M2-07) locates the segment by search, not by the offsets, so an edit
  elsewhere in the note does not misplace the cut.
- The plan also carries `preconditions: [NoteID: contentHash]` for the M2-07
  compare-and-swap; the validator rejects a plan that touches a note without
  one, or with one that no longer matches.

---

## ADR-017 — The plan tool schema is a discriminated `anyOf`

**Date:** 2026-08-22 · **Task:** M2-04 · **Status:** accepted (verify live in M2-06)

**Context.** Strict tool use needs `strict: true`, `additionalProperties:
false` and `required` on every object. Seven actions with different fields have
to share one `actions` array.

**Decision.** `OrganizationPlan.toolSchema` is generated from
`Organize/PlanSchema.swift` as an `anyOf` of seven closed objects, each pinning
`action` to a one-value `enum`. `required` lists only the genuinely required
fields rather than every property, which is ordinary JSON Schema and reads far
better to the model. A test lints the document (every object closed, every
`required` name defined) and validates every encoded `PlanAction` against it,
so schema and codec cannot drift.

**Consequences.**
- **Unverified without an API key**: if strict mode rejects `anyOf` or insists
  that every property be `required`, M2-06's first live call will 400 and the
  fix is local to `PlanSchema.swift` (flatten to one object with nullable
  fields). Nothing above the schema changes.
- Adding an action means a `PlanAction.Kind` case, a payload struct and a
  schema branch; the closed-set test fails until all three agree.

## ADR-018 — Two FTS5 indexes over one stored copy of the note text

**Date:** 2026-08-23 · **Task:** M1-06 · **Status:** accepted

**Context.** Plan §1 asks for FTS5 "trigram for substring, unicode61 for
word/prefix" over title and body. FR-5.1 needs both behaviours: `dock` must
match while the word is still being typed, and `pplication/json` must be found
inside a fenced `curl` command, where no word tokenizer can see it. A single
tokenizer cannot do both — unicode61 has no substring matching, and trigram
cannot do prefix or phrase ranking well and is blind to anything under three
characters. The `notes` table holds no body text, so the index has to store the
text itself somewhere.

**Decision.** The `v2-fts` migration adds a `note_text` table (`note_id`
cascading from `notes`, `relpath`, `title`, `body`, `content_hash`) and two
FTS5 tables over it as **external content**: `notes_fts` (unicode61,
`remove_diacritics 2`) and `notes_trigram` (trigram). Three triggers per table
mirror `note_text` into both. Ranking weights are persisted in the index
(`bm25(10.0, 1.0)`), so `ORDER BY rank` is already the order the UI wants. The
body is therefore stored once, indexed twice.

Query-time, the trigram table is a **fallback**, not a peer: it runs only when
the word pass could not express the query at all (an emoji, a mid-word
fragment) or came back with less than a screenful. And where the word pass is
ordered by bm25 — which costs a score for every matching document — the trigram
pass takes an unordered `LIMIT`, so SQLite stops as soon as it has enough rows.

**Consequences.**
- The derived database is roughly 5× the size of the Markdown it indexes: 55 MB
  for a 10 MB / 5,000-note library, 216 MB for 41 MB / 20,000. Almost all of the
  excess is the trigram posting lists. It is derived data in Application
  Support, deletable at any time, and the price of substring search that stays
  under 100 ms. If it ever becomes a complaint, the trigram table can be dropped
  behind a setting and body substring search falls back to the word index.
- Bodies are stored in the database as well as on disk. That is what makes the
  snippet and match range exact (see ADR-019) without re-reading files per
  keystroke.
- Queries shorter than three characters that contain no word tokens (a bare
  emoji) match nothing. Documented limitation of the trigram tokenizer.
- Indexing a 5,000-note library takes ~1.2 s release / ~1.6 s debug on top of
  the metadata rebuild, so `rebuild(from:indexingText:)` can defer it.

---

## ADR-019 — Match ranges are computed in Swift, not taken from FTS5

**Date:** 2026-08-23 · **Task:** M1-06 · **Status:** accepted

**Context.** FR-5.2 wants a click on a result to open the note *scrolled to the
relevant section*, which means the search has to return where in the note the
match is, in UTF-16 units that `NSTextView` can use. FTS5's `snippet()` returns
marked-up text, not offsets, and its offsets — where it has them — are token
positions, not character positions. Folding the text and doing arithmetic on the
folded copy is also wrong: case- and diacritic-folding can change length (ﬁ → fi),
so the range would drift.

**Decision.** FTS5 is used only to select and rank candidate *notes*. For the
handful that survive the limit, `SearchService` fetches the stored body and
finds the best occurrence with Foundation's own matcher
(`range(of:options: [.caseInsensitive, .diacriticInsensitive])`), preferring the
whole query and falling back to its longest term. The result is converted to a
`MatchRange` (UTF-16 location/length, `nsRange` for the app layer) and to a
one-line snippet with the match located inside it for highlighting.

**Consequences.**
- The range is exact by construction, and a test asserts that the returned range
  really does point at the matched text for every query shape.
- Ranges are measured against the *body* — front matter stripped — because that
  is what the editor's buffer holds.
- Cost is bounded by the result limit (25 notes), not the match count.
- A title-only hit has no body range; the UI opens the note at the top and shows
  the note's opening line as the snippet.

---

## ADR-020 — The search index is maintained by `MetadataStore`'s write paths

**Date:** 2026-08-23 · **Task:** M1-06 · **Status:** accepted

**Context.** The index must survive everything that changes the library: the
app's own saves, the reconciler's add/edit/move/delete, folder removal, and a
full `rebuild()`. `LibraryChange` carries a `NoteSummary`, which has no body, so
whoever indexes has to read the file. Making that the caller's job would mean
every future write path could silently forget it.

**Decision.** `MetadataStore` owns it. It holds a `NoteTextLoader` (by default:
read the file, strip front matter) and re-indexes inside the same transaction as
the row it is writing — `upsert`, `apply(_ changes:)`, and `rebuild`. Deletes
need no code at all: `note_text.note_id` has `ON DELETE CASCADE`, so removing a
note or a folder unindexes for free. Bodies are read *outside* the write
transaction and skipped when the stored `content_hash` already matches, so a
reconcile of three notes reads three files.

Two paths need care and got it. A **move** keeps the note's bytes, so the hash
check would skip it — moves are therefore always reloaded, and the `.moved`
handler's delete is guarded by id so it cannot cascade away the row it is about
to update. A **rebuild** drops the triggers, bulk-loads `note_text` in batches of
512, and lets FTS5's own `'rebuild'` command build both indexes in one pass;
row-at-a-time trigger firing was several times slower.

`SearchService` reads through `MetadataStore.reader` — the same GRDB
`DatabaseQueue`, exposed `nonisolated` — so a keystroke never queues behind an
autosave on the store's actor. The two still share one SQLite connection; search
reads are a few milliseconds, and the upgrade path if that ever bites is WAL
plus a `DatabasePool`.

**Consequences.**
- `rebuild(from:)` now reads every note's body. `rebuild(from:indexingText:
  false)` skips it, and `staleTextNotes(limit:)` / `indexText(_:)` are the
  catch-up API for a shell that wants the sidebar on screen first.
- A note whose file is unreadable is left out of the index rather than failing
  the write: one bad file cannot break a reconcile.
- `MetadataStore` bumps a `notes_generation` counter in `meta` on every write.
  A rename changes neither the row count nor any mtime, so a digest of the table
  cannot see it — the counter is what tells `SearchService`'s title cache to
  refresh.

---

## ADR-021 — Fuzzy is titles-only, and the title scan is a flat byte buffer

**Date:** 2026-08-23 · **Task:** M1-06 · **Status:** accepted

**Context.** Plan §1 amendment 6 defines FR-5.1's "fuzzy" as substring/prefix on
the body plus typo tolerance on titles. Typo tolerance means comparing the query
against *every* title on *every* keystroke, and NFR-1 gives the whole search
100 ms — measured on a debug build, which is what CI and the perf gate run.

**Decision.** Damerau-Levenshtein (optimal string alignment) with a budget of 0
edits under four characters, 1 up to seven, 2 beyond; whole-title, plus
word-level for single-word queries at a one-edit penalty. Bodies are matched
literally — only the two FTS indexes see them.

The scan is built for the debug case. All folded titles live in one flat
`[UInt8]` buffer with a parallel array of trivial spans, so 20,000 titles cost no
retains, no allocations and no `String` comparisons; matching is byte-level
(exact for folded UTF-8, which is self-synchronising). Each span caches a 64-bit
signature of the byte classes it contains: since `d` edits can drop at most `d`
distinct classes, `popcount(sig(query) & ~sig(title)) > d` proves the pair is too
far apart, in one instruction, before any matrix is touched. The distance
function itself is allocation-free and abandons a row as soon as every cell
exceeds the budget.

**Consequences.**
- The measured effect on a debug build at 5,000 notes: the title pass went from
  47–100 ms to 2–13 ms, and overall p95 from 132 ms (failing) to 25 ms.
- Distance is measured over UTF-8 bytes, not Characters. For non-ASCII titles it
  over-counts — a conservative direction — and a property test fuzzes the
  signature prefilter against the real distance to prove it never rejects a pair
  that is actually within budget.
- The title cache is a few hundred kilobytes at 20,000 notes and is revalidated
  against the `notes_generation` counter, so a keystroke that changed nothing
  costs one indexed lookup.
