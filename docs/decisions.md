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

## ADR-022 — Autosave is a Core state machine with an app-side timer

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

## ADR-023 — Launch paints from the database, then reconciles

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

## ADR-024 — The quit-time flush runs off the main actor

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

---

## ADR-025 — The Activity log *is* the apply journal

**Date:** 2026-08-23 · **Task:** M2-07, M2-08 · **Status:** accepted

**Context.** M2-07 needs a durable record written before the first file
operation so that `kill -9` mid-apply cannot leave a half-organized library
(NFR-3). M2-08 needs a user-visible history of every AI action with timestamps
and before/after diffs (FR-4.3). Both want the same three things: what the plan
was, which notes it touched, and what those notes looked like on each side.

**Decision.** One table, `activity_events`, with a `kind` (what the row is) and
a `status` (how far it got). `PlanApplier` inserts the row with
`status = 'inProgress'` and the before-images *already in it*, executes, writes
the after-images, and only then flips the status to `'applied'`. Per-note text
lives in a separate `activity_note_images` table rather than a JSON blob,
because Undo's ordering rule asks "did a later event touch this note?", which
wants an index.

`recoverIncompleteEvents()` repairs what is left over at launch:

* **Roll forward** when every note has a durable after-image *and* the file on
  disk still matches its hash — the work was done and only the status flip was
  lost. The event becomes a normal, undoable entry.
* **Roll back** otherwise: notes the event created go to the Trash, every
  before-image is written back to the path it came from, files left at
  intermediate paths are trashed, and empty folders the event made are removed.

Which is why the after-images and the status flip are two separate writes: it
gives the recovery a state to roll *forward* from, instead of a window where a
finished apply looks like a failed one.

**Consequences.**
- A crash is never worse than "the plan did not happen", and never leaves a note
  half-appended. The tests inject the crash through an `ApplyFailureHook` at a
  named `ApplyStep`, so the path is exercised without killing the process.
- Rollback is expressed entirely in terms of before-images plus a durable
  progress list (`progress_json`, appended after every file operation), so it
  works identically inline (an error) and at launch (a crash).
- The log grows one row per organization event forever. Only text is pruned
  (ADR-026), and the row count is a handful per day.
- `MetadataStore` is untouched by an apply: the writes go through `NoteStore`,
  whose own-operation ledger the watcher already reconciles into the database.

---

## ADR-026 — Undo restores bytes, patches when it must, and never drops text

**Date:** 2026-08-23 · **Task:** M2-08 · **Status:** accepted

**Context.** FR-4.3 wants a single Undo over ≥10 events; FR-4.4 says the AI
never deletes user content. Between those two sits the case the plan calls out
as risk #2: the user edited a note *after* the AI touched it, and then pressed
Undo. Restoring the before-image wholesale would destroy the user's edit —
exactly the failure the whole design exists to prevent.

**Decision.** Images are the note's **raw file bytes**, front matter included,
and Undo works entirely in that space. Per note, in order:

1. current hash == after-image hash → write the before-image back verbatim. The
   file is byte-identical to what it was before the AI saw it.
2. otherwise → replay the reverse patch (a line diff from after back to before,
   hunks located by context nearest their old position) onto the *current* text.
3. any hunk that will not land → keep the user's text and append what the hunk
   was carrying under a `## Restored by Undo (conflict)` heading; report
   `.partial`.

Creates become Trash, a trashed empty source is written back, a move or retitle
is reversed through `NoteStore.move`/`rename` (so the file keeps its identity
rather than being rewritten), and the undo records its own event, marking the
original non-undoable. Redo is out of scope for Phase 1.

Ordering is LIFO, but only against *organization* events: undoing event N is
refused with `.blockedByLaterEvent` when a later `applied` event touched one of
the same notes. Undo events themselves never block, or a ten-deep unwind would
stop after its first step.

Retention follows from this: raw session text is dropped once it is older than
30 days (FR-4.4's floor), and before/after images are kept for as long as the
event is undoable — an event that has been undone, and is out of the ten-deep
window, may lose its images. The event row itself is never deleted.

**Consequences.**
- Ten stacked events unwind to byte-identical trees, asserted by fingerprinting
  the whole `.md` tree before every apply and after every undo.
- The diff is a small LCS over lines with the common prefix and suffix trimmed —
  a few hundred lines of Swift, no dependency, and the same code powers both the
  Activity window's unified diff and the reverse patch.
- Because images are raw bytes, front-matter churn is invisible to the user: the
  diff *view* strips front matter, while the *restore* keeps it.
- A conflicted undo leaves a note the user must reconcile by hand. That is the
  deliberate trade: a visible, marked duplication rather than a silent loss.

---

## ADR-027 — `ActivityLog` opens its own connection, with WAL and a busy timeout

**Date:** 2026-08-23 · **Task:** M2-08 · **Status:** accepted

**Context.** The activity, undo and baseline tables live in `filaway.sqlite`
(migration `v4-activity`), the same file `MetadataStore` owns. `MetadataStore`
keeps its `DatabaseQueue` private, and threading every activity write through it
would tie the AI pipeline to the indexer's actor for no benefit.

**Decision.** `ActivityLog` is its own actor with its own `DatabaseQueue` on the
same path, configured with `busyMode = .timeout(5)` and `PRAGMA journal_mode =
WAL`. Both are properties of the *file*, so switching WAL on here means
`MetadataStore`'s readers no longer block behind an activity write. The GRDB
default (`.immediateError`) would have surfaced normal contention as an error.

**Consequences.**
- Two connections, one migrator: both types run `DatabaseSchema.migrator`, which
  is idempotent, so whichever opens the file first migrates it.
- `-wal` and `-shm` files appear beside `filaway.sqlite` in Application Support.
  Nothing is added to the user's notes folder (DS-1 holds).
- `MetadataStore` still carries GRDB's default busy mode. It should adopt the
  same timeout when the app wires both up — a one-line change, noted for the
  integration pass rather than made here to avoid a conflicting edit.
- `note_baselines` rides along on the same connection: `DatabaseBaselineStore`
  is a thin `BaselineStore` façade over `ActivityLog`, so the session tracker
  never opens a third connection.

## ADR-028 — A session starts on an edit, and returning to the app does not cancel the grace

**Date:** 2026-08-23 · **Task:** M2-03 · **Status:** accepted (implements plan §1 amendment 2)

**Context.** FR-3.1 says a session "begins when the user starts editing any
note" and ends when there are no keystrokes for the idle interval *and* the note
is not being actively scrolled or selected; switching away ends it immediately.
Amendment 2 delays the *pipeline* by 30 s after a deactivation or window close,
"cancelled if activity resumes". Two things are left open: whether scrolling can
*start* a session, and whether coming back to the app counts as resuming.

**Decision.** `SessionMachine` — a pure state machine with three phases (idle,
active, end-pending) — settles both:

- Only `edit` starts a session and only `edit` marks a note as *touched*.
  Scroll, selection and note switches sustain a session but never open one, and
  a session with no touched notes is discarded rather than organized.
- `appDidBecomeActive` is **inert**. The grace is cancelled by touching the
  editor (edit, scroll, selection, note switch), not by the app becoming
  frontmost.
- A second deactivation while the grace is running does not extend it.
- `appWillTerminate` fires a pending session immediately, keeping its original
  end time and reason.

**Consequences.**
- The ⌘-Tab-to-Terminal-and-back loop that amendment 2 exists for still files
  the session, 30 s later, if the user comes back only to read. If `becomeActive`
  cancelled the grace, that session would never be filed at all.
- Every rule is a synchronous table test; the actor's only extra job is a timer
  on an injected `SessionClock` and the flush hook, so the suite spends no real
  seconds on a 3-minute interval.
- The idle interval is clamped to FR-3.1's 1–15 minutes on the way in, so a
  malformed setting cannot disable filing.

---

## ADR-029 — Autosave flush, then baseline snapshot, then organize

**Date:** 2026-08-23 · **Task:** M2-03 / M2-05 · **Status:** accepted

**Context.** Autosave is debounced 750 ms (plan §1), so when a session ends the
file on disk can be a keystroke or two behind the editor buffer. The organizer
computes its delta from the file. Nothing in the type system stops the app from
starting the pipeline before the flush.

**Decision.** `SessionTracker` owns a `flushHook` and **awaits it before
publishing `SessionEvent.ended`**. The organizer takes its snapshot (current
text + organized baseline) when it receives that event, and compare-and-swap
preconditions are recorded from that same snapshot. The ordering is documented
on the actor and in `docs/organize.md`, and a test asserts the hook runs first.

**Consequences.**
- The last burst of typing is always in the delta.
- A hook that hangs delays filing but blocks nothing else — the tracker is an
  actor and the app never awaits it.
- The app must not call `Organizer.sessionEnded(_:)` from anywhere but the
  `.ended` event.

---

## ADR-030 — Baselines and the pending-session queue are protocols with in-memory implementations

**Date:** 2026-08-23 · **Task:** M2-05 · **Status:** accepted

**Context.** The organized baseline per note and the offline session queue are
both durable state that belongs in `filaway.sqlite` (plan §1 "Derived DB", and
migration `v4-activity` which owns `note_baselines`). M2-05 has to be finished,
tested and reviewable before that migration exists, and its race-matrix tests
must not need a database.

**Decision.** `BaselineStore` and `PendingSessionStore` are `Sendable`
protocols in `FilawayCore`, with `InMemoryBaselineStore` and
`InMemoryPendingSessionStore` actors shipping now. `PlanApplying`,
`OrganizeLibrarySource` and `CandidateFinder` follow the same rule: the
organizer names what it needs and owns none of it.

**Consequences.**
- Losing baselines is a **cost** problem, not a correctness one: an absent
  baseline makes the next session look like "the whole note is new", so the AI
  re-reads text it has already filed. Nothing is lost or double-applied, because
  the plan still goes through validation and compare-and-swap.
- The GRDB implementations drop in without touching the organizer, and the
  in-memory ones stay as the reference behaviour for their tests.
- `CandidateFinder` is the seam M3-08 replaces with the hybrid ranker.

---

## ADR-031 — An invalid action is dropped, unless that would make the summary a lie

**Date:** 2026-08-23 · **Task:** M2-05 · **Status:** accepted

**Context.** `PlanValidator` can reject part of a plan (a hallucinated note id,
a folder three levels deep) while the rest is perfectly good. Throwing the whole
plan away costs the user real filing; keeping the good actions changes what
happens without changing `plan.summary` — and FR-4.2 requires the card to state
*exactly* what happened or will happen (risk #6).

**Decision.** `Organizer.repair(plan:unknownActions:context:)`:

1. drops every action the validator pinned an error to, and re-validates;
2. discards the whole plan if a plan-level error has no action index, if
   nothing survives, or if the reduced plan still fails;
3. **checks the summary against what is left**: if it names a note title or
   folder path that only the dropped actions touched, the plan is discarded.

Actions the *decoder* could not read at all stay warnings — they never entered
the plan.

**Consequences.**
- The common case (one bad target among five good actions, summary unaffected)
  still files the good ones, and `ProposedPlan.droppedActions` records what went.
- The card never describes an action that will not happen.
- The rule is mechanical and testable — two golden fixtures pin both branches —
  rather than a judgement call about "does the summary still read right".

---

## ADR-032 — The organize prompt is one rendered system string, and candidates are the first thing cut

**Date:** 2026-08-23 · **Task:** M2-06 · **Status:** accepted

**Context.** `organize.v1` and `plan-format.v1` are versioned separately
(spec §9), but the API takes one `system` string. Separately, the request has a
token budget (~6 k input) that a large library or a long note will blow through,
and something has to give.

**Decision.** `organize.v1.txt` carries `{{include:plan-format.v1}}` and
`OrganizeRequestBuilder.systemPrompt()` splices the two together, so either
prompt moving moves the request hash and the golden fixtures. The user message
is built by `OrganizeContextBuilder` and reduced, when over budget, in a fixed
order: candidate previews (20 → 10 → 5 lines), then candidates from the
lowest-ranked up, then the library's note titles, then session note bodies
truncated *around* the delta. **The delta itself is never truncated.** Every
reduction is recorded in `truncations`. Token estimation is `bytes / 4` — crude,
pessimistic, free.

**Consequences.**
- Losing a candidate costs a possible merge; losing session text would cost the
  plan and could break `moveSegment`'s byte-exact segment, so it goes last.
- `Prompt: organize.v1` is rendered into the message body, which makes every
  recorded request self-describing and gives the golden tests something to
  assert on.
- The FR-4.5 gate shows up as a property of the fixtures: the scenario whose
  session touched an excluded note hashes to the *same request* as the one
  without it.

---

## ADR-033 — One `PlanApplying` / `BaselineStore` contract, owned by the implementer

**Date:** 2026-08-23 · **Task:** M2-05 / M2-07 integration · **Status:** accepted

**Context.** M2-05 (organizer) and M2-07/M2-08 (applier, activity log) were
written in parallel, and each declared the seam between them: two `PlanApplying`
protocols, two `AppliedPlan` structs, two apply-error enums, and two
`BaselineStore` protocols over two baseline value types. Merged, the package did
not compile — every name was ambiguous. ADR-030 predicted the shape of the seam
correctly; it did not say who gets to name it.

**Decision.** One of each, and the side that *implements* a contract owns its
definition, while the side that calls it names what it needs:

* **`PlanApplying`, `AppliedPlan`, `ApplyError`** live in
  `Organize/ApplyModel.swift`, beside `PlanApplier`. `AppliedPlan` is the rich
  one — `eventID`, per-action `outcomes`, `createdNotes`, `createdFolders`,
  `trashedNotes`, `changedPaths` — because the card and the Activity row need
  all of it and the organizer needs none of it. It gains one field the organizer
  does own: `sessionID`, stamped after a successful apply, and one derived
  `removedNoteIDs` (the trashed notes) so a baseline can be dropped rather than
  advanced.
* **The error kept is `ApplyError`**, the applier's, because it is what 61 tests
  and every throw site already say. M2-05's `PlanApplyError` is gone; its
  `preconditionFailed` maps onto `ApplyError.preconditionFailed(_:)` (same
  meaning, no argument label) and its `io(String)` catch-all was added to
  `ApplyError` for whatever a third-party `PlanApplying` might throw.
  `conflict(String)` was dropped: `invalidPlan` and `noteMissing` already say it.
  **The organizer's semantics are unchanged** — a precondition failure is still
  `OrganizerEvent.stale`, still writes nothing, still leaves the baseline where
  it was.
* **`BaselineStore` and `OrganizedBaseline`** live in `Session/BaselineStore.swift`,
  keeping the four-method protocol the organizer actually uses (batch read and
  `removeBaseline` included) and the value type that carries `sessionID` and
  derives its own hash. `ActivityLog` and `DatabaseBaselineStore` conform;
  `Activity/ActivityEvent.swift`'s `NoteBaseline` and its two-method protocol are
  gone. A column-shaped `setBaseline(noteID:hash:text:at:)` stays as a protocol
  extension, so callers holding a hash need not rebuild the value.

**Consequences.**
- `Organizer` + the real `PlanApplier` + `ActivityLog`-as-`BaselineStore` +
  `UndoService` are exercised together in
  `Tests/FilawayCoreTests/OrganizeIntegrationTests.swift`, on a temp library:
  auto mode end to end, and ask mode through propose → accept → applied → undo
  with a byte-identical tree at the end. That test is the thing that would have
  caught the divergence on day one.
- `note_baselines` has no session column, so a baseline round-tripped through the
  database loses `OrganizedBaseline.sessionID`. It labels the last advance; no
  delta is computed from it. Adding the column can wait for a migration that has
  another reason to exist.
- The app wiring (M2-10) has one name for each thing: `PlanApplier` as the
  `PlanApplying`, `ActivityLog` (or `DatabaseBaselineStore`) as the
  `BaselineStore`, `InMemoryPendingSessionStore` until M2-09.

## ADR-034 — The ⌘K results panel is a non-focusable overlay, not a popover

**Date:** 2026-08-23 · **Task:** M1-12 · **Status:** accepted

**Context.** FR-1.3 puts one search bar in the toolbar; Figure 2b shows the ⌘K
surface as a field with a results list under it. macOS offers three obvious
shapes for the list: an `NSPopover` anchored to the toolbar item, a separate
Spotlight-style floating `NSPanel`, or an overlay drawn inside the window.

The deciding constraint is **focus**. The search has to be fully operable from
the keyboard: ↑/↓ move the selection, ⏎ opens it, Esc closes and returns to the
editor, and every character typed in between has to keep reaching the field. A
popover takes first responder when it appears, so the arrow keys would land in
the popover's list and the letters would have to be forwarded back to a field
that no longer has focus — a two-way relay that AppKit's popover dismissal
policies then fight. A separate panel has the same problem plus its own window
level, key-window handling and screen placement.

**Decision.** The panel is a plain SwiftUI overlay on the window
(`ShellView.searchOverlay`), horizontally centred so it hangs under the
toolbar's `.principal` search field. It never becomes first responder: the text
field keeps focus for the whole interaction and forwards keys to
``SearchCoordinator`` (`moveSelection(by:)`, `openSelected()`,
`handleEscape()`), which owns both `results` and `selectedIndex`. The panel is a
pure function of that state. A transparent full-window backdrop closes it on a
click outside, Spotlight-style.

⌘K goes through `AppModel.focusSearch()`, which both moves focus and calls
`SearchCoordinator.activate()` — so the shortcut works even where SwiftUI's
`FocusState` has nowhere to move focus to (the headless smoke run), and the
field editor's contents are selected so the next keystroke replaces the old
query.

**Consequences.**
- Every keyboard path is a method call on a `@MainActor` object, which is why
  the `search` smoke phase can drive ↑/↓/⏎/Esc with no synthetic key events and
  no unlocked screen (plan §8).
- The panel is clipped to the window. That is the trade against a real panel,
  and it is the right one at 460 pt wide.
- The overlay is hosted by its own small `SearchOverlay` view with its own
  `@ObservedObject`: `ShellView` observes `AppModel`, and `SearchCoordinator` is
  a separate object, so without it the overlay would never see the panel open.
- Debounce is 80 ms and only the newest *generation* of a query may publish, so
  a slow search for `cur` cannot overwrite a fast one for `curl`. Cancellation
  alone would nearly always be enough; the counter makes it unconditional.
- `SearchMode.semantic` exists as a documented, unimplemented case. M3-06 adds a
  second backend, the Find/Ask toggle and the answer card above the list at the
  marked extension point; nothing about the focus model has to change.

---

## ADR-035 — Settings are a Core value store, and the app spells it `CoreSettings`

**Date:** 2026-08-23 · **Task:** M2-11 · **Status:** accepted

**Context.** FR-8.1's preferences drive Core objects — the organizer's mode, the
session tracker's idle interval, the exclusion filter's folder list, the
indexer's semantic toggle — but the obvious home for "preferences" is the app
target, which Core is forbidden to import. `FilawayApp` also already has an
`AppSettings` (window frame, sidebar width, last-open note), and `FilawayCore`
is the name of both the module *and* an enum inside it, so
`FilawayCore.AppSettings` does not resolve to the module's type.

**Decision.** `AppSettings` lives in `FilawayCore/Settings`, backed by an
injected `UserDefaults` suite, with typed and clamped accessors and Combine-free
change notification (`observe(_:)` returning a token, plus `changes()` as an
`AsyncStream`). Core exports `public typealias CoreSettings = AppSettings`, and
the app uses that name. The shell's `AppSettings` keeps its own scope: window
and sidebar geometry, which is AppKit state and belongs there.

**Consequences.**
- Every preference is unit-testable with `swift test` alone, against a throwaway
  suite — no app, no window.
- Consumers subscribe rather than poll, so a mode or interval edit takes effect
  without a restart. Handlers run synchronously on the writing thread.
- Two `AppSettings` types coexist. The alias makes the Core one unambiguous;
  merging them is a later cleanup, not a Phase 1 one.
- The clamp is applied on read as well as write, so a hand-edited plist cannot
  put `idleInterval` outside 1–15.

---

## ADR-036 — The API key reaches the Keychain only after it validates

**Date:** 2026-08-23 · **Task:** M2-11 · **Status:** accepted

**Context.** FR-6.1 wants paste → validate → confirm. The naive order is to
store the key and then check it, which is simpler but means a typo in Settings →
AI → Change… replaces a working credential with a broken one, and the user's
next writing session silently fails to file.

**Decision.** `AIConnectionManager.connect(apiKey:)` validates the *entered*
key through a provider bound to `APIKeySource.fixed(_:)`, and writes to the
`SecretStore` only on success. A blank key is rejected without a network call.
On failure nothing is written and the previously stored key is untouched.
Validation is `GET /v1/models`, which is free (plan §1 amendment 4), so the
check costs nothing to repeat.

**Consequences.**
- The stored credential is always one that worked at least once; `.invalidKey`
  afterwards means the key was revoked, not mistyped.
- `refresh()` re-validates on every Settings open, so the pill is never stale —
  one free request per visit.
- Losing connectivity never removes a key: `.network` folds to `.offline`, and
  FR-6.4's degradation applies rather than a disconnect.
- A smoke run gets an `InMemorySecretStore`. An unsigned bundle querying the
  real Keychain can prompt or fail, and a scripted run has no business writing
  the user's credential.

## ADR-037 — The bge-small `.mlpackage` is committed as a `FilawayCore` resource

**Date:** 2026-08-23 · **Task:** M3-01 · **Status:** accepted

**Context.** ADR-012 chose `BAAI/bge-small-en-v1.5` and settled on shipping the
`.mlpackage` (not a `.mlmodelc`) compiled at first launch. It did not settle how
the 63.5 MB package *reaches* the app. The spike suggested a `make model` step
that copies `Tools/embedder/out/` into a resource folder at build time, keeping
the blob out of git.

**Decision.** Commit the package. `Package.swift` gains
`.copy("Resources/Models")` on the `FilawayCore` target, and
`Sources/FilawayCore/Resources/Models/` holds three files:
`bge-small-en-v1.5-s256-b1.mlpackage` (63.5 MB), its `EmbeddingModelDescriptor`
JSON, and `bge-small-en-v1.5.vocab.txt`. `BundledEmbeddingModel` resolves them
through `Bundle.module`; `Tools/embedder/install-model.sh` refreshes them after
a re-conversion.

A build-time copy step would have meant that a fresh clone does not build a
working app, that CI cannot run the Core ML tests without a 3 GB PyTorch
install, and that "which weights are in this build?" has no answer in the
repository. One binary that changes only when `convert.py` changes is the
cheaper problem.

**Consequences.**
- The repository gains ~64 MB, once. Every clone pays it; every later commit
  does not, because the file only changes on a re-conversion. Git LFS is the
  escape hatch if the model starts changing per release — it is not needed for a
  file that has changed twice.
- `swift build` now copies 64 MB into `.build`, and `Tools/make_app.sh` already
  copies SwiftPM resource bundles into `Contents/Resources`, so the app picks it
  up with no change.
- The Core ML tests in CI stop being conditional: `EmbedderFactoryTests` asserts
  the resource is present, so a build that loses the model fails loudly instead
  of silently degrading to keyword-only. `EmbeddingsTests` keeps its
  `Tools/embedder/out` skip, because that path also measures MiniLM.
- Palettization (8-bit ≈ 33 MB) remains the lever if the DMG gets too big, still
  gated on an M3-07 quality re-run.

**Regeneration.** `Tools/embedder/regenerate.sh` was re-run for this task:
torch↔Core ML cosine 0.999983–0.999988, over ADR-012's 0.999 gate.

## ADR-038 — Vectors are binary16 bytes, converted with vImage, not Swift `Float16`

**Date:** 2026-08-23 · **Task:** M3-03 · **Status:** accepted

**Context.** Plan §1 stores embeddings as "vectors as BLOBs in SQLite + an
in-memory Float16 matrix". The obvious Swift spelling is `[Float16]`. But
`Float16` is **unavailable on x86_64 macOS** — the standard library guards it
out — and plan §1 keeps Intel in scope (NFR-5, universal builds once Xcode is
installed). Code that compiles on this arm64 machine would have failed the first
universal build, months later, in a file nobody was looking at.

**Decision.** Carry halves as `UInt16` bit patterns. `HalfVector.encode/decode`
converts with `vImageConvert_PlanarFtoPlanar16F` /
`vImageConvert_Planar16FtoPlanarF`, which exist on both architectures and are
vectorised on both. `VectorStore` holds one hand-managed
`UnsafeMutablePointer<UInt16>` (wrapped in a small class so the `deinit` is
legal on an actor) and converts a block at a time into a Float32 scratch buffer
for `vDSP_mmul`.

`vDSP_mmul` rather than `cblas_sgemv`: the CBLAS entry points are deprecated
without the ILP64 headers, and it is the same BLAS kernel underneath.

**Consequences.**
- Half the memory of Float32 for no measurable ranking cost: binary16 rounds at
  the third decimal, which can swap two chunks whose cosines are within 5e-3.
  `VectorStoreTests` asserts the *scores* match a Float32 brute-force reference
  rather than the exact id order, which is the honest invariant.
- The buffer is grown by doubling for incremental upserts and sized **exactly**
  on a load — doubling on a 20,000-row load would have left 10 MB of slack and
  made the memory report a lie.
- Deletes tombstone a slot and the next upsert reuses it, so a note being edited
  repeatedly never memmoves the matrix.
- Measured: 20,000 chunks × 384-d = 15.4 MB resident, including the side arrays
  and the chunk-id map; a real 20,000-note library on the synthetic corpus's
  chunk density (340,000 chunks) is 273 MB, which is over NFR-2's ~200 MB. See
  ADR-039 for why that density is a worst case and what the levers are.
- Loading is lazy, so a user who only ever uses ⌘K keyword search pays none of
  it — which is also what keeps the NFR-1 2 s launch budget intact.

## ADR-039 — A heading starts a chunk only when the run in progress is big enough

**Date:** 2026-08-23 · **Task:** M3-02 · **Status:** accepted

**Context.** The obvious chunker splits at every heading and at every fence. Run
that over a real corpus and the chunk count explodes: `filaway-bench index`
produced **22 chunks per 2 KB note**, most of them 20–40 tokens. Because the
bundled model is traced at a *fixed* sequence length of 256 (ADR-012), a
40-token chunk costs exactly as much to embed as a 250-token one — so the
explosion is a straight multiplier on index-build time and on the resident
matrix.

**Decision.**

1. **A heading starts a new chunk only if the run in progress has reached
   `minTokens` (64).** Otherwise the heading is absorbed and the run keeps
   growing. A chunk that spans several small sections is filed under the heading
   that introduces the bulk of it, and its text still contains every heading it
   covers. This took the same corpus from 22 to 17 chunks per note, and a
   changelog-shaped note from 9 chunks to 2.
2. **Every fenced code block is still its own chunk**, unconditionally, with its
   language, its heading path and the nearest preceding paragraph as context.
   That is the FR-5.2 retrieval unit and is not negotiable for size.
3. **Ranges are whole lines, in UTF-16.** swift-markdown reports columns as
   UTF-8 byte offsets, which would need a second mapping to reach the editor's
   coordinates; whole lines need only a line table, and a chunk boundary can
   never land inside a grapheme.

**Consequences.**
- On the synthetic corpus (a code fence every fifth block — far denser than real
  prose) 5,000 notes produce ~87,000 chunks. Real notes are nearer the plan's
  ~4 per note. If a user's library really is that command-dense, the next levers
  are raising `minTokens`, folding a sub-`minTokens` prose run into the code
  chunk that follows it, and the seq-64 package for short chunks (2× throughput,
  measured in the spike).
- `maxChunks` (400) caps one pathological note; a 4,000-section note is
  truncated rather than allowed to fill the index.
- A chunk's `headingPath` is a breadcrumb and a weak retrieval signal, not an
  index key — nothing depends on it being the deepest heading in the chunk.

## ADR-040 — Hybrid ranking is RRF, and a date range filters before the top-k cut

**Date:** 2026-08-23 · **Task:** M3-03 · **Status:** accepted

**Context.** Plan §1 specifies "RRF(FTS5 BM25, vector) + temporal filter +
recency prior". Two details it does not settle: why RRF rather than a weighted
sum of normalised scores, and where in the pipeline the temporal filter goes.

**Decision.**

1. **RRF with k = 60**, over the *positions* in each candidate list. A cosine in
   [-1, 1] and a BM25 score in (-∞, 0] are not on the same scale, and their
   distributions move with every query — any fixed weighting is tuned to one
   corpus and wrong on the next. RRF needs no normalisation and no per-corpus
   tuning, and it gives a document both retrievers rank highly a win over one
   that either ranks first alone, which is the whole point of a hybrid index.
2. **The keyword arm ORs its terms**, where `SearchService.keyword` ANDs them
   with a prefix on the last. As-you-type search is a *filter*; a
   natural-language question is a *bag of evidence* that shares only a few words
   with the note answering it. ANDing "what was the curl command for documents"
   returns nothing, always.
3. **A parsed date range is applied inside `VectorStore.topK`**, as an admission
   filter, not after the cut. Filtering afterwards makes "the thing I edited
   yesterday" come back empty whenever fifty newer chunks scored higher — the
   exact query FR-5.3 exists for. The same gate carries FR-4.5's excluded
   folders and any folder scope, so nothing excluded can reach M3-05's prompt.
4. **The recency prior is a bounded multiplier and is off inside a hard range.**
   `1 ... 1.2` on a 30-day half-life; inside a date range every note is equally
   "when the user meant", so the prior would only add noise. "recently" swaps in
   a 7-day curve with a 1.6 ceiling and no filter.
5. **Note-level score is the best chunk's**, times a small bonus for extra
   matching chunks (+8% each, capped at three). Three matching sections is
   better evidence than one, but never enough to overturn a clearly better
   single answer.

**Consequences.**
- `SemanticResults.usedVectors` is the FR-5.5/FR-6.4 signal. With no embedder
  the whole path still works on BM25 alone, and says so.
- The admission gate is resolved **once per note, into a `Set<NoteID>`**, not
  evaluated per chunk. The first implementation called
  `ExclusionFilter.isExcluded(path:)` — and therefore `PathRules.normalize` —
  inside the vector scan, once per resident row: a date-filtered query over
  20,000 notes took **580 ms**, of which 500 ms was string normalisation, against
  80 ms for the same query unfiltered. Anything added to that gate must stay a
  hash lookup.
- `HybridSearch` caches note identity (title, path, mtime) against the
  `notes_generation` counter, the way `SearchService` caches titles: the vector
  arm needs every note's mtime *before* the cut, and one query per candidate
  would be worse than one query per generation.
- `promptChunks` (top 8) is the contract M3-05 builds `answer.v1` on; nothing
  else about the shape of `RankedChunk` is load-bearing for it.

## ADR-041 — The app's AI mode defaults to `live`, and the smoke suite replays

**Date:** 2026-08-23 · **Task:** M2-12 · **Status:** accepted

**Context.** `AIMode.current()` defaults to `replay` because that is right for
`swift test` and CI: no key, no network, no cost. The app cannot inherit that
default — a shipped `Filaway.app` with no `FILAWAY_AI_MODE` set would serve
fixtures that are not in the bundle, and quietly organize nothing.

**Decision.** `OrganizeCoordinator.makeProvider(environment:)` reads
`FILAWAY_AI_MODE` itself and defaults to **`live`** with
`APIKeySource.storeThenEnvironment(KeychainStore())`. `replay` additionally
requires `FILAWAY_AI_FIXTURES`, which `Tools/smoke.sh` sets to
`Tests/Fixtures/ai-recordings`. A fourth, app-only lever, `FILAWAY_AI_FAIL`,
returns a `MockProvider` that always fails with a network error (or an invalid
key), because there is no way to unplug the network from inside a test and
FR-6.4's degradation is exactly the path worth proving end to end.

**Consequences.**
- Every smoke phase runs with `FILAWAY_AI_MODE=replay`, so no phase can reach
  the network even by accident — including the ones that predate M2.
- The `organize` phases replay a **committed** fixture, so they assert the real
  card text rather than a mock's.
- A missing fixture surfaces as `AIError.missingRecording`, which the organizer
  does *not* queue: the phase fails loudly instead of hanging.
- `FILAWAY_AI_FAIL` is app-layer only. Nothing in `FilawayCore` knows about it.

## ADR-042 — One prompt behind the goldens and the smoke phase, and the card sits bottom-trailing

**Date:** 2026-08-23 · **Task:** M2-10, M2-12 · **Status:** accepted

**Context.** Two things had to be decided to make M2 visible and testable: where
the organization card lives on screen, and how a headless phase can replay a
recorded model answer when the fixture's filename is a hash of the whole
rendered prompt — library tree, note ids, session delta, candidate ranking and
the session's end time.

**Decision (the card).** Bottom-trailing of the editor pane, stacked, newest at
the bottom. The top strip already belongs to `BannerView` — "the file changed
under you" and "the AI has a suggestion" are different enough to deserve
different places — and the caret is usually in the upper half of the pane, where
a top banner would cover the words the card is talking about. Ask mode is a
question that waits indefinitely (**Accept** ⏎ / **Edit** / **Dismiss** ⎋); auto
mode is a statement that fades after 20 s (**Undo** / **View changes**), with
Undo living on in the Activity window. Nothing ever takes first responder.

**Decision (the fixture).** The smoke corpus is chosen so the app's own wiring
renders **exactly** M2-06's `merge-code-block` prompt: seeded front matter pins
the note ids, and `OrganizeCoordinator.endSessionNow(noteID:endedAt:)` rewinds
the tracker's last activity by the idle interval and ticks, so the session ends
at a named instant with reason `idle`. One recording therefore stands behind the
Core goldens, the Core end-to-end wiring test and the smoke phase.
`OrganizeWiringTests.wiringHitsTheCommittedFixture` asserts the key, so drift is
a named test failure at `make test` rather than a bare `missingRecording` in a
smoke run half an hour later. Auto mode renders `Mode: auto` and so has its own
fixture, `122cfeeded98ffbb.json`.

**Consequences.**
- `KeywordCandidateFinder` normalises keyword scores over *eligible* hits only.
  Letting the session's own note (top hit, never a candidate) set the divisor
  would make the prompt depend on indexing order.
- The `organize` phases wait for `MetadataStore.textIndexCount()` to catch up
  before ending the session, for the same reason.
- Changing the prompt, the ranker or the corpus moves the key: regenerate with
  `FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter OrganizeWiringTests/regenerateFixture`,
  which writes only fixtures that do not exist and never overwrites a golden.
- The auto-mode card shows the *plan's* summary, read back off the Activity row,
  not `AppliedPlan.summary` — the latter is the applier's account of what it did
  ("Moved a section from Scratch."), where FR-4.2 asks for the model's
  plain-language sentence.

---

## ADR-043 — Sparkle comes from SPM, and it brings its own command-line tools

**Date:** 2026-08-23 · **Task:** M4-04 · **Status:** accepted

**Context.** Plan §1 picks Sparkle 2 via SPM. The risk was that it would not
resolve on this machine at all: there is no Xcode, only the Command Line Tools
(Swift 6.0.3), and GRDB already had to be pinned below 7.9.0 because its
manifest declares swift-tools-version 6.1 (ADR-003). The brief allowed a
fallback of downloading the release xcframework into `Tools/sparkle/` and
wiring it up as a local `binaryTarget`.

**Decision.** Plain SPM: `.package(url: "…/sparkle-project/Sparkle", from:
"2.9.0")`, resolved at 2.9.6. The fallback is not needed. Sparkle's own manifest
is **swift-tools-version 5.3** — far below anything 6.0.3 objects to — and its
single target is a `binaryTarget` pointing at a checksummed
`Sparkle-for-Swift-Package-Manager.zip` on the GitHub release, containing a
prebuilt `Sparkle.xcframework` with a `macos-arm64_x86_64` slice. Nothing has to
be compiled, so the toolchain's age is irrelevant. Verified by building and
linking `SPUStandardUpdaterController` before touching the real package.

The second, more useful discovery: that zip is the *whole* Sparkle
distribution, so `swift build` also unpacks
`.build/artifacts/sparkle/Sparkle/bin/{generate_keys,sign_update,generate_appcast,BinaryDelta}`.
`Tools/lib.sh` locates them there. There is no separate download step, no
`Tools/sparkle/bin` to gitignore, and CI gets the tools from the same
`swift build` it already runs.

**Consequences.**
- `swift build` now downloads a ~32 MB binary artifact on a cold cache. It is
  cached by `Package.resolved` hash in both workflows.
- The framework is universal already, so embedding it does not constrain the
  app's own architecture — only `make_app.sh`'s build flags do.
- Sparkle links into `FilawayApp` only. `FilawayCore` stays UI-free and
  Sparkle-free, so `swift test` is unaffected.
- If a future Sparkle raises its tools-version above the local toolchain, the
  documented fallback (download the xcframework, local `binaryTarget`) is still
  open; pin the last working tag rather than vendoring in a hurry.

---

## ADR-044 — "Updates not configured" is a real implementation, not an error path

**Date:** 2026-08-23 · **Task:** M4-04 · **Status:** accepted

**Context.** Sparkle needs `SUFeedURL` and `SUPublicEDKey` in the Info.plist.
Neither exists on this machine and neither will until the user generates keys
and publishes an appcast (plan §8). Meanwhile every `make app`, every CI run and
every one of the six smoke phases launches the app. `SPUStandardUpdaterController`
with no feed logs an error and leaves an updater that can never succeed, so the
unconfigured build cannot simply construct one and hope.

**Decision.** A two-line protocol, `UpdaterProviding`, with two real
implementations: `SparkleUpdaterProvider` wrapping
`SPUStandardUpdaterController`, and `UnconfiguredUpdaterProvider` whose
`unavailableReason` is `"Updates not configured in this build"`.
`UpdaterController` reads the Info.plist — both keys present, non-empty, and not
an unsubstituted `@…` placeholder — and picks one. The menu item is disabled
with that reason as its tooltip.

The provider is built **lazily, and never during launch**. SwiftUI evaluates
`commands` while the first window is coming up, which is precisely the interval
NFR-1 budgets for "cold launch to editable"; constructing Sparkle's controller
there would put its bundle and Keychain work on the critical path for no
benefit, since nothing can be checked before the app is running anyway. The
menu item reads only the plist; the controller appears on
`didFinishLaunching`, or on the first click, whichever comes first.

`startIfPossible()` is additionally a no-op under `FILAWAY_SMOKE`: a smoke phase
must never reach the network, and `Tools/smoke.sh` launches the app six times in
a row, which would otherwise look like six update checks.

**Consequences.**
- The app-side footprint is one new file plus one line
  (`UpdaterCommands()`) in `FilawayApp.swift` — `AppDelegate` is untouched,
  because `UpdaterController` observes `didFinishLaunching` itself.
- `make app` on a machine with no Sparkle key produces a working app with a
  disabled, self-explaining menu item rather than a broken updater.
- The seam is the natural place for a fake in a future test; nothing about
  `UpdaterProviding` assumes Sparkle.

---

## ADR-045 — Not sandboxed, so Sparkle's XPC services are stripped

**Date:** 2026-08-23 · **Task:** M4-04 / M4-05 · **Status:** accepted

**Context.** `Sparkle.framework` ships `XPCServices/Installer.xpc` and
`XPCServices/Downloader.xpc`. They exist so a **sandboxed** app can still
install an update and reach the network, and they are activated by the
`SUEnableInstallerLauncherService` / `SUEnableDownloaderService` Info.plist
keys. Filaway is deliberately not sandboxed: spec §3 ships outside the App Store
so the app can read and write an arbitrary user-chosen notes folder with plain
POSIX calls, which a sandbox would turn into security-scoped bookmarks on every
note.

**Decision.** `Tools/make_app.sh` deletes `XPCServices` (and the framework's
`Headers`, `PrivateHeaders` and `Modules`, which are build-time artefacts) after
`ditto`-ing the framework into `Contents/Frameworks`, and the two Info.plist
keys stay unset — which is what Sparkle's sandboxing guide prescribes for a
non-sandboxed app. `Tools/Filaway.entitlements` states
`com.apple.security.app-sandbox = false` explicitly rather than omitting it, so
the reasoning is visible at the point of decision.

The entitlements file is otherwise close to empty, and deliberately so.
Specifically **no** `allow-unsigned-executable-memory` and no `allow-jit`:
`FilawayCore/Embeddings` calls `MLModel.compileModel(at:)` at first launch and
then `MLModel(contentsOf:)`, and Core ML compilation runs out of process in the
system's compiler service while the compiled `.mlmodelc` it loads back is data,
not code. Neither exception applies. Also no
`disable-library-validation`: every bundled executable — the app,
`Sparkle.framework`, `Autoupdate`, `Updater.app` — is signed by the same
Developer ID in one inner-out pass, so library validation is satisfied rather
than switched off.

**Consequences.**
- Signing is explicit and inner-out (`Autoupdate`, `Updater.app`, the framework,
  then the app), never `codesign --deep`, which is deprecated and cannot apply
  entitlements to nested code.
- Ad-hoc builds are signed **without** `--options runtime`. An ad-hoc signature
  carries no team identifier, so a hardened ad-hoc app would fail library
  validation against the equally ad-hoc `Sparkle.framework` and refuse to
  launch. Hardened runtime switches on with a real `$DEVELOPER_ID`.
- The app binary needs an `@executable_path/../Frameworks` rpath that SwiftPM
  does not emit (it gives only `@loader_path`); `make_app.sh` adds it with
  `install_name_tool` and drops the Command Line Tools' developer-frameworks
  rpath. `ci.yml` asserts `otool -L` still resolves Sparkle, because this breaks
  silently and only at launch.
- Should Filaway ever be sandboxed, this is the ADR to reverse: restore
  `XPCServices`, sign each `.xpc` with its own entitlements, and set both keys.

---

## ADR-046 — CFBundleVersion is the commit count, and the appcast is signed per tag

**Date:** 2026-08-23 · **Task:** M4-05 · **Status:** accepted

**Context.** Sparkle decides "is this newer?" by comparing `CFBundleVersion`,
not `CFBundleShortVersionString`. It has to increase monotonically and never
repeat. The marketing version fails both — 0.1.0 can plausibly ship twice — and
a timestamp is not reproducible from a checkout.

**Decision.** `CFBundleShortVersionString` comes from `$FILAWAY_VERSION`, else
an exact `v*` tag on HEAD, else the `VERSION` file (a dirty tree or a commit
past the tag falls through, so a local build never claims to be the tagged
release). `CFBundleVersion` is `git rev-list --count HEAD`.

GitHub Releases put assets under `…/releases/download/<tag>/`, which is a
different prefix for every release, while `generate_appcast` takes one
`--download-url-prefix` per run. `Tools/sparkle/make_appcast.sh` therefore
passes *this* tag's prefix each time: the tool applies it only to new items and
leaves existing entries' URLs alone, which is exactly the required behaviour.
`build/releases/` accumulates recent DMGs so binary deltas can be built against
them; `release.yml` re-downloads the last three releases' assets for that.

**Consequences.**
- A shallow clone produces the wrong build number, so `release.yml` uses
  `fetch-depth: 0`.
- Two silent failure modes were found by building it both ways, and are now
  asserted in CI and documented in `docs/release.md`:
  `generate_appcast` writes `sparkle:edSignature` **only** when the archived
  app declares `SUPublicEDKey` (otherwise the entry is silently unsigned and
  every client rejects it), and it stamps `sparkle:hardwareRequirements` from
  the slices in the archive, so an arm64-only release is never offered to Intel
  Macs at all.
- `build/releases/` is gitignored: the DMGs live on the GitHub Release.

## ADR-047 — Retrieval constants are measured on a corpus, not derived from first principles

**Date:** 2026-08-23 · **Task:** M3-07 · **Status:** accepted (amends ADR-040)

**Context.** ADR-040 set three constants by reasoning: RRF's `k = 60` because
that is what the paper used, a recency ceiling of +20% because it sounded
"mild", and a prompt slice of eight chunks because plan §3 M3-05 says eight.
M3-07 built the first corpus that could test them — 302 notes, 62 of them
hand-written around a real command, and 89 queries with a known answer — and
all three were wrong in the same way: each was chosen without reference to the
*scale of the thing it acts on*.

**Decision.**

1. **`RecencyPrior.maxBoost` 0.2 → 0.05** (`recent` 0.6 → 0.15,
   `window(_:maxBoost:)` likewise). The ceiling multiplies an RRF score, where
   adjacent ranks differ by ~1.6% (`1/61` vs `1/62`). "+20%" is therefore worth
   about twelve rank positions, and thirteen of 77 queries lost to a note that
   was merely newer. Note top-1 78% → 90% on this change alone.
2. **`HybridSearch.Options.rrfK` 60 → 20.** The paper's 60 was tuned for lists
   of thousands. With fifty candidates per arm, `1/61 … 1/110` is under a 2×
   spread, so fusion degenerates into "how many arms found it" and rank stops
   carrying information. `k = 20` spans 3.3×. Worth +1 note top-1, +6 answer
   top-1, and it halves the damage the recency prior can do.
3. **`SemanticResults.promptChunks` 8 → `promptChunkLimit` (20).** The chunk
   holding the answer was inside the top eight only **65%** of the time and
   inside the top twenty **94%**. The cause is structural, not a ranking bug: a
   short note splits into a prose chunk written in the language of the
   *question* (so it ranks first) and a code chunk carrying the command, which
   shares almost no vocabulary with the question (so it ranks tenth). No
   reranking inside eight chunks can recover a chunk that was never in them.
4. **The offline answer heuristic picks the winning *note's* code block**, not
   the best-scoring code block. Globally-best picks a different note's command
   most of the time; same-note took answer top-1 from 42% to 86%.

Result on the bundled bge-small model: note top-1 **91%**, top-3 97%, MRR@10
**0.939**, answer-card accuracy **90%**, p95 **17 ms**. Spec §8 asks for ≥ 90%
under ten seconds. Full table and ablations: `docs/verification/M3-retrieval.md`.

**Consequences.**
- ADR-040's points 1 and 4 are amended; its points 2, 3 and 5 stand unchanged.
- **A cosine threshold cannot carry the "no answer" decision.** Measured, the
  two distributions overlap (answerable 0.57–0.88, unanswerable 0.59–0.70): the
  floor that rejects every negative also suppresses a third of the real
  answers. The abstain decision belongs to M3-05's extractor, which can read
  the chunks; the floor is only the FR-5.5 offline backstop.
- The prompt grows from ~8 to ~20 chunks (~3,000 tokens). That is still a small
  Haiku call, and it is the difference between an answer card that is right 70%
  of the time and one that is right 90% of the time.
- **Open gap:** typo'd queries are the weak category at 57% top-1. FTS5 matches
  terms exactly and WordPiece turns `"crul"` into subword soup, so both arms
  fail together. Proposed for M4: expand rare terms to their nearest
  in-vocabulary neighbours (the `Fuzzy` machinery `⌘K` already uses) when the
  OR expression matches fewer than *k* notes.

## ADR-048 — The dev corpus is generated from curated tables, and scale numbers are measured on it

**Date:** 2026-08-23 · **Task:** M3-07 / M3-09 · **Status:** accepted

**Context.** Two questions the earlier tasks left open. Where does a *realistic*
corpus live, given that `SyntheticCorpus` (ADR-011) exists for scale and is not
realistic? And which corpus do the NFR-2 numbers describe?

The second question turned out to matter a great deal. `SyntheticCorpus` writes
a fenced block every fifth paragraph, and every fence is unconditionally its own
chunk (ADR-039), so it produces **17 chunks per note**. Every M3-03 number
derived from it — a 409 s index build at 5,000 notes, a 273 MB matrix at 20,000
— is a function of that density and not of anything a user would have.

**Decision.**

1. **`Tests/Fixtures/corpus/dev` is committed Markdown** (302 notes, 236 KB),
   generated by `filaway-bench corpus generate --seed` from
   `DevCorpusContent` (62 curated golden notes) plus a deterministic distractor
   generator. Curation happens in the Swift tables; the Markdown is the
   artefact. `RetrievalFixtureTests` asserts the generator still reproduces what
   is committed, so a hand-edit to a fixture file fails the suite instead of
   silently drifting.
2. **The corpus and the benchmark runner live in `FilawayCore/Bench`**, for
   ADR-011's reason: a SwiftPM executable target cannot be imported by a test
   target, and the CI gate and the CLI must measure exactly the same thing.
3. **Timestamps travel in front matter.** Git does not preserve mtimes and every
   FR-5.3 query is answered from `notes.mtime`, so each note carries `created`
   and `modified`, and `DevCorpus.materialize` stamps them onto the files.
   Dates are midday UTC and the runner parses with a fixed UTC, Monday-first
   calendar, so "last week" means the same thing on a laptop and on CI.
4. **NFR-2 numbers are reported on a corpus of dev-corpus shape**, with
   `SyntheticCorpus` kept as the explicit worst case. Measured (M3-09):
   5,000 notes index in **50 s** (not 409 s) and 20,000 notes hold a **33 MB**
   matrix (not 273 MB).

**Consequences.**
- Two corpora with two jobs: `SyntheticCorpus` for filesystem and database
  scale, `DevCorpus` for retrieval quality and for realistic index cost. Any
  number quoted from either must name which.
- The repository gains 236 KB of Markdown that changes only when the tables do.
- ADR-039's chunk-density levers (`minTokens`, folding small prose runs) are
  **not** needed: measured on realistic notes the chunker produces 2.0 chunks
  per note, and raising `minTokens` from 64 to 128 moves the synthetic corpus by
  only 4.6% because its density is code fences, which never fold.

---

## ADR-049 — An unreadable database is quarantined, not deleted; diagnostics carry no path under the notes root

**Date:** 2026-08-23 · **Task:** M4-08 · **Status:** accepted

**Context.** M4-08 asked for crash hardening and a diagnostics export. Two
questions had no answer yet.

*What happens when `filaway.sqlite` is not a database?* SQLite recovers from a
torn write on its own — that is what the WAL is for. It cannot recover from a
file whose header no longer says `SQLite format 3`, which is what a truncated
restore, an interrupted copy or a cloud-sync conflict produces. Before this task
every opener simply threw, which surfaced as "Filaway could not open your
library" for a problem that costs a rebuild, not data.

Except that it is no longer *only* a rebuild. DS-3 and `Migrations.swift` still
say "deleting it is always safe: everything in it is rebuildable from the notes
folder", and that stopped being true at `v4-activity`: `activity_events`,
`activity_note_images` and `note_baselines` live in the same file, and the
Activity history and the organized baselines are not derived from anything.

*And what may a diagnostics bundle contain?* NFR-4 is zero-content telemetry.
The obvious reading is "no note text". But DS-1 makes a note's title its
filename, so **a path is a title**, and a crash report full of absolute paths is
a list of what the user has been writing about.

**Decision.**

1. **`DatabaseFile.open` wraps every SQLite open in Filaway.** On
   `SQLITE_NOTADB` / `SQLITE_CORRUPT` the file and its `-wal` / `-shm` sidecars
   are moved aside as `<name>.corrupt-<timestamp>` and the open is retried once
   against an empty file. `MetadataStore`, `ActivityLog`, `AIUsageLedger` and
   `PendingSessionStoreGRDB` all go through it.
2. **Moved, never deleted.** The derived half rebuilds from the notes folder;
   the Activity history in the same file does not. Keeping the bytes leaves a
   salvage path, and costs a few megabytes the user can delete.
3. **The fact is reported, not swallowed.** `recoveredFromCorruption` on each
   store says where the old file went, and `database.txt` in a diagnostics
   export lists every quarantined file — which is the entire explanation for
   "my Activity history is empty".
4. **The diagnostics redactor collapses the whole path, not the prefix.**
   `<notes-root>/Commands/curl.md` would still name a folder and a title, so
   anything under the root becomes `<notes-root>/…`. Settings report
   `excludedFolders` as a **count**; the database section is `sqlite_master` DDL
   plus a row `COUNT` per table and never a row.
5. **The export is structural first and scrubbed second.** It never opens a
   note, never reads `activity_events`, never touches `PromptLibrary`. The
   redactor exists for the files *other people* wrote — crash reports and the
   `log show` excerpt — and a leak sweep drops any staged file that still
   contains a library path rather than shipping it.

**Consequences.**
- A corrupt `filaway.sqlite` now costs the user their Activity history and their
  organized baselines, silently but recoverably. Splitting the non-derived
  tables into their own file is the obvious follow-up and is **not** done here:
  it is a migration, and M4-08 is a hardening task.
- `DatabaseSchema`'s "deleting it is always safe" comment is now qualified in
  `docs/core-api.md`.
- Two bugs the tests found on the way in: an Undo the process killed half-way
  through reported `.partial` on retry (the reverse patch was replayed onto text
  that was already the before-image), and the redactor's account-name rule,
  applied as a bare substring, turned `com.tejaspanse.filaway` into
  `com.<user>.filaway` in every log line. Both fixed, both with a named
  regression test.
- The `<user>` rule now only fires on a path component, which means an account
  name appearing in prose inside a crash report is *not* masked. Judged the
  right trade: mangling every line is a worse failure than leaving a username
  that macOS has already put in a dozen paths the export keeps as `~`.
