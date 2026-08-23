# M4-07 — the performance pass

**Task:** plan §3 M4-07 (NFR-1, NFR-2). **Date:** 2026-08-23.
**Machine:** Apple M2, 16 GB, macOS 26.1, Swift 6.0.3, release build,
ad-hoc-signed `build/Filaway.app`, warm compiled-model cache.

**Verdict: NFR-1 and NFR-2 are met with an order of magnitude to spare, and
the two M3-perf recommendations are now code.** A 20,000-note library reaches
an editable window in **374 ms** against NFR-1's 2 s; the first-launch index is
background work that costs a concurrent ⌘K search 50 ms; and the typo lever
M3-07 proposed turns out to be worth **+4 points of overall retrieval accuracy**,
not just the typo category.

Everything below is reproducible from the commands in §7.

---

## 1. Launch (NFR-1: cold launch to editable < 2 s)

`LaunchTimer` now receives every stage the shell marks, and `FILAWAY_TIMING=1`
prints one parseable line each. `filaway-bench launch` runs the assembled bundle
N times against a real notes folder and reports the p50 per stage — the
substitute for `XCTApplicationLaunchMetric`, which needs Xcode (plan §8).

The stages, and what each one means:

| Stage | Marked in | Means |
|---|---|---|
| `didFinishLaunching` | `AppDelegate` | dyld, AppKit, Sparkle, the onboarding gate |
| `windowVisible` | `ShellView.configure(window:)` | the window exists |
| `shellAppeared` | `ShellView.task` | SwiftUI built the scene |
| `dbOpen` | `AppModel.bootstrap()` | GRDB open + migrations, off the main thread |
| `libraryOpen` | `AppModel.bootstrap()` | **first sidebar paint** — Recents and the tree have real content |
| `editorReady` | `ShellView.task` | `bootstrap()` returned; the editor takes keystrokes |

**p50 of 5 runs, milliseconds since the kernel exec'd the process:**

| | empty | 5,000 notes cold | 5,000 warm | 20,000 cold | 20,000 warm |
|---|--:|--:|--:|--:|--:|
| `didFinishLaunching` | 178 | 176 | 174 | 176 | 175 |
| `windowVisible` | 236 | 235 | 232 | 236 | 233 |
| `shellAppeared` | 236 | 235 | 233 | 236 | 233 |
| `dbOpen` | 241 | 240 | 233 | 241 | 234 |
| `libraryOpen` | 242 | 241 | 263 | 242 | **374** |
| **`editorReady`** | **242** | **241** | **263** | **242** | **374** |

**"Cold" here means the database is not there yet** — a first launch on an
existing notes folder. **"Warm" means it is** — every launch after that, and the
only one where the sidebar has 20,000 notes to paint. Cold is *faster*, which
is not a paradox: ADR-023's design paints the sidebar from the database alone
and runs the launch reconcile afterwards, so a cold launch paints an empty
sidebar in 241 ms and fills it a second or two later, while a warm launch pays
140 ms to read 20,000 rows before it paints. **The warm number is the honest
one**, and it is 374 ms against a 2 000 ms budget.

Three things worth reading off that table:

* **Library size costs nothing before `dbOpen`.** 176 / 236 / 241 ms are
  identical at 0, 5,000 and 20,000 notes. The first quarter-second is dyld and
  AppKit, and no amount of notes work will move it.
* **The whole of Filaway's own launch is `dbOpen → libraryOpen`** — 1 ms at
  5,000 notes, 140 ms at 20,000. That is the sidebar query, and it is linear.
* **NFR-1 has 5× headroom at 20,000 notes**, so §8's "typing within three
  minutes of installing" is not a performance question at all
  (`docs/verification/success-criteria.md` §1).

### 1.1 What was already right, and was verified rather than changed

ADR-023 claims the sidebar paints from the database before the reconcile. It
does: `bootstrap()` opens the store, opens GRDB on a detached
`.userInitiated` task, calls `refreshSidebarNow()`, sets `isLoaded`, and only
*then* starts the organize pipeline, the reconcile and FSEvents inside a
trailing `Task`. `SemanticSearchCoordinator.start(...)` returns immediately and
does the embedder load, the `catchUp()` and the vector load off the main actor.
None of that needed changing; the marks now prove it.

### 1.2 The one change to `AppModel`

One line: `LaunchClock.mark("dbOpen")` between the `MetadataStore` construction
and the `LibraryWatcher`, so the GRDB open is separable from the sidebar paint.
Without it the two are one 140 ms number and there is no way to tell a slow
migration from a slow query.

### 1.3 Two traps the harness hit, recorded so nobody pays for them twice

* **macOS's restore prompt.** A launch bench kills the app it measures, and
  after a few runs `NSPersistentUIRestorer` decides there is a crash history and
  opens *"Do you want to try to reopen its windows?"* — an `NSAlert` run
  **before** `applicationDidFinishLaunching`. The app then prints nothing at all
  and the run hangs; on a locked screen the dialog is invisible, so it looks
  exactly like "the app is broken". `filaway-bench launch` passes
  `-ApplePersistenceIgnoreState YES` and deletes
  `~/Library/Saved Application State/com.tejaspanse.filaway.savedState`, which
  is where the crash history the prompt counts actually lives.
* **SIGTERM is not enough.** An app sitting in a headless smoke phase does not
  reliably answer `terminate()`, and the survivors made the next run measure a
  machine with a stray app on it. The measured process has an empty editor and
  nothing to flush; SIGKILL it.

---

## 2. The first-launch index (NFR-2, FR-5.4)

Dev-corpus-shaped notes throughout — prose with one command in it, 2.0 chunks
per note. `SyntheticCorpus` is a command-dense worst case at 17 chunks/note and
stays the filesystem and database fixture; NFR-2 is reported against notes a
person would write (ADR-048).

| | 5,134 notes | 20,234 notes |
|---|--:|--:|
| Scan + metadata + FTS | 1.9 s | 5.2 s |
| Chunks | 10,421 (2.0/note) | 41,071 (2.0/note) |
| **Semantic index build** | **52.0 s** (98.7 notes/s) | **234.9 s** (86.1 notes/s) |
| Per embedding | 5.0 ms | 5.7 ms |
| Derived database | 23.6 → 43.1 MB | 89.2 → 169.5 MB |
| Resident vector matrix | 8.4 MB | **32.9 MB** |
| Lazy matrix load, first query | 44 ms | 133 ms |
| Process growth when it loads | +16.8 MB | **+38.0 MB** |
| Re-index one edited note | **8.9 ms** | **11.9 ms** |

Against M3-perf's 49.8 s and 220 s: **4–7% slower**, which is what the
background QoS and the per-note yields cost. §3 is the thing they bought.

The 10% super-linearity M3-perf flagged is still there and still has no cliff:
5.0 → 5.7 ms per embedding between the two sizes (larger transactions, a colder
page cache).

### 2.1 The three scheduling changes

`docs/verification/M3-perf.md` §5 left these as recommendations "at the app's
call site". They are now inside the `Indexer`, where they hold however the
caller arrives — which matters, because the call site is
`SemanticSearchCoordinator`, a `@MainActor` object, and an actor method runs at
its *caller's* priority.

1. **Background QoS.** `Configuration.workPriority` (default `.utility`). The
   debounce loop starts at that priority, and every embedder call runs on a
   detached task pinned to it. Detaching is what makes it independent of the
   caller; it cannot deadlock because the closure touches only the `Sendable`
   embedder, never the actor.
2. **Most-recently-modified first.** `staleNoteIDs(limit:)` was a `UNION` with
   no `ORDER BY`, so SQLite returned rows in whatever order suited it — in
   practice `notes.id`, i.e. random UUIDs. It now joins back to `notes` and
   orders by `mtime DESC`, with the `LIMIT` applied to the ordered set. Four
   minutes of indexing at 20,000 notes is only tolerable if the first minute
   covers what the user actually searches for.
3. **Batch yields.** One `await Task.yield()` per note. A 20,000-note build owns
   the actor for four minutes; without a yield an autosave's `markDirty` and the
   progress row's `status` read queue behind the entire pass.

Progress is already surfaced: `IndexStatus.indexing(completed:total:)` and
`statusStream()` existed before this task, and `SemanticSearchCoordinator`
observes them.

---

## 3. Is the UI usable while it indexes?

The question M3-perf could not answer. `filaway-bench index --with-queries`
runs a search loop at `.userInitiated` against the same database the `Indexer`
is writing — the priority relationship a real ⌘K has to a real catch-up — and
reports the distribution it saw.

| | 5,134 notes | 20,234 notes |
|---|--:|--:|
| Searches during the build | 232 | 902 |
| Query p50 | **16.2 ms** | **49.7 ms** |
| Query p95 | **24.5 ms** | **78.7 ms** |
| Query max | 31.7 ms | 106.4 ms |
| Chunks searchable at 25% / 50% / 75% of the build | 2 599 / 5 224 / 7 867 | 10 441 / 20 811 / 30 920 |
| Notes ranked | 10 (full page) throughout | 4 at 25%, 10 from 50% on |

**No query ever returned nothing.** The indexer commits each note in its own
transaction, so ⌘K gets steadily better while the build runs instead of being
empty until it finishes — which is what "Indexing n of m" is a promise about.

Against the steady state (§4) a query costs about 2× while indexing at 5,000
notes and 2× at 20,000. Both are far inside NFR-1's 5 s, and both are the
*worst* case: the probe queries continuously, where a person types occasionally.

---

## 4. Steady-state query latency (NFR-1)

| | p50 | p95 | max |
|---|--:|--:|--:|
| Keyword, 5,000 notes (`filaway-bench keyword`, the CI gate) | 8.7 ms | **11.3 ms** | 12.3 ms |
| Keyword, 5,000 notes (`SearchScaleTests`) | 17 ms | 29 ms | — |
| Keyword, 20,000 notes (`SearchScaleTests`) | 47 ms | **93 ms** | 104 ms |
| Semantic, 302-note dev corpus, bundled model | 14 ms | 19 ms | — |
| Semantic, 5,000 notes, bundled model | 19 ms | 20 ms | 23 ms |
| Semantic, 20,000 notes | 27 ms | **42 ms** | 45 ms |

NFR-1's 100 ms keyword budget and 5 s semantic budget both hold at 20,000
notes. The semantic figures are the whole offline half — query embedding,
blocked `vDSP_mmul` scan, FTS5 arm, RRF — so **the Claude answer step gets
essentially all of the 5 s**.

The first semantic query after a launch is the number a user feels, and it is
still ~2–3 s cold: the Neural Engine builds its program on the first embed
(`docs/verification/M3-perf.md` §3). Warming the embedder during idle, after the
window is up, would remove it. **Not done** — it belongs in
`SemanticSearchCoordinator`, which is another agent's file this milestone. See
§8.

---

## 5. 20,000 notes: memory, and where behaviour changes

Resident size of the real `build/Filaway.app`, sampled every 10 s from launch,
with the semantic catch-up running (the worst case — it re-embeds the whole
library):

| Library | RSS at 10 s | Peak | Settling to |
|---|--:|--:|--:|
| Empty | 112 MB | 123 MB | **123 MB** |
| 5,134 notes | 226 MB | 239 MB | ~200 MB |
| 20,234 notes | 234 MB | **285 MB** | ~240 MB |

**The increase over an empty library at 20,000 notes is 110–160 MB**, inside
NFR-2's ~200 MB. Two thirds of the *baseline* 123 MB is AppKit, SwiftUI and
Sparkle; the notes themselves are cheap.

Where behaviour changes, in the order a growing library meets them:

| Threshold | What changes |
|---|---|
| Any size | The sidebar paints from the database before the reconcile runs, so launch is flat in library size (§1). |
| First semantic query, ever | The `.mlpackage` is compiled and cached (47–86 ms, once per machine). |
| First semantic query per launch | The embedder loads and the Neural Engine builds its program: **~2–3 s cold**, ~45 ms warm. |
| First semantic query per launch | The vector matrix lazy-loads: 44 ms at 5k, **133 ms at 20k**. A user who never presses ⌘K never pays it. |
| ~5,000 notes | The first-launch index becomes a *minute* of background work rather than seconds. Keyword search is unaffected and available immediately. |
| ~20,000 notes | The first-launch index becomes **four minutes**. Most-recent-first ordering (§2.1) is what makes that tolerable. Concurrent queries cost 50 ms instead of 27 ms. |
| ~20,000 notes | Keyword p95 crosses 90 ms — still inside NFR-1's 100 ms, but this is where the next order of magnitude would break it. |
| ≫ 20,000 notes | Untested. The matrix is linear (1.6 KB/note), the database is linear (8.4 KB/note), and the `vDSP_mmul` scan is linear in chunks; nothing here is a cliff, but nothing here is measured either. |

### 5.1 What is still unmeasured

* **Sidebar scrolling at 20,000 notes.** Frame timing needs Instruments, which
  needs Xcode (plan §8). Query latency and memory are comfortable; the scroll
  is unverified.
* **Sustained-use footprint.** These are launch-and-index samples, not a day of
  editing.
* **Intel.** No universal build is possible without Xcode. Core ML on x86_64 has
  no Neural Engine, so the index build there will be materially slower and needs
  its own measurement.

---

## 6. The typo lever — kept

M3-07 §5 left typos as the weak category: **57% top-1, four of seven queries
missed**, and proposed expanding rare terms when the keyword arm comes back
thin. Two things about that proposal turned out to be wrong, and the corrected
version is worth more than the original.

**The trigger cannot be "few results".** `"the crul command for stagign docs"`
contains `command` and `docs`, which match hundreds of notes, so the OR
expression returns a full page and a result-count trigger never fires. The gate
that does work is **per term**: a term whose document frequency is *zero* cannot
contribute to BM25 by construction, so replacing it can only add recall. There
is no threshold to tune and no "did you mean" judgement to get wrong.

**The keyword arm is not where most of the damage is.** FTS5 simply ignores a
term it has never indexed. A sentence embedder ignores nothing — `"crul"`
tokenises to subword soup and drags the whole query vector away from the note
that answers it. So the repair does both: the corrected sentence is what the
**vector** arm embeds, and the corrections join the keyword arm's `OR` alongside
the original word.

The vocabulary is FTS5's own term index, exposed by a new `v6-vocab` migration
as an `fts5vocab` view (`notes_vocab`). It stores nothing — it is a projection
of the index `notes_fts` already maintains. It is a migration rather than a
`temp.` table created on demand because GRDB's readers run with
`PRAGMA query_only = 1` and refuse DDL even in the temp schema, which is exactly
where this is needed. See ADR-057.

**Measured, `filaway-bench retrieval --embedder bge`, 302-note dev corpus:**

| Category | n | top-1 before | after | answer before | after |
|---|--:|--:|--:|--:|--:|
| command | 6 | 100% | 100% | 100% | 100% |
| paraphrase | 56 | 95% | **95%** | 93% | **93%** |
| temporal | 8 | 88% | 88% | 88% | 88% |
| **typo** | 7 | **57%** | **100%** | **57%** | **100%** |
| **all positives** | **77** | **91%** | **95%** | **90%** | **94%** |

| | before | after |
|---|--:|--:|
| top-3 | 97% | **100%** |
| MRR@10 | 0.939 | **0.970** |
| Negatives rejected | 100% | 100% |
| False rejections among answerable queries | 32% | **23%** |
| p50 / p95 | 13 / 18 ms | 14 / 19 ms |

**Nothing regressed.** Paraphrase and temporal are unmoved to the query, and
top-3 reaching 100% means the right note is now always on the first screen.

**The budget is one edit, never two**, and that was measured rather than
assumed. Every misspelling in the M3-07 set is a single edit or transposition
(`crul`, `pdo`, `loggs`, `rebuidl`, `pluled`, `rsyncc`, `sever`, `rebse`,
`mian`, `opnessl`, `certificat`, `chek`), so two edits buy no recall — and they
cost precision, because the zero-frequency gate cannot tell a *typo* from a word
that is spelt correctly and simply is not in this library. At two edits,
`"upgrading"` and `"squash"` became other people's words and paraphrase dropped
95% → 93%. At one edit it does not move.

**Cost.** The gate is one indexed point lookup per term on every query; the full
vocabulary scan happens only when a query really does contain an unknown word,
and the result is cached against `notes_generation` like `noteMeta`. Query p50
moved 13 → 14 ms on the dev corpus and **not at all** on the 20,000-note corpus
(27.2 / 42.3 ms, against 27.2 / 41.8 before). Vocabularies measured: 1,649 terms
at 5,134 realistic notes, 1,676 at 20,234, 5,098 on the synthetic corpus — the
scale corpora are replications, so their vocabulary does not grow with note
count and a real 20,000-note library would be larger. The flattened form costs
~24 bytes per term and the loader caps at 250,000 terms, so the ceiling is ~6 MB.

`filaway-bench retrieval --no-typo-expansion` reproduces every M3-07 number
exactly, which is how the table above was produced.

---

## 7. Reproducing all of this

```bash
make app                                  # the launch bench needs the bundle

# Launch (NFR-1). --warm primes the database in-process first.
filaway-bench launch --library /tmp/empty            --runs 5
filaway-bench launch --library /tmp/notes-5k         --runs 5
filaway-bench launch --library /tmp/notes-5k --warm  --runs 5
filaway-bench launch --library /tmp/notes-20k --warm --runs 5

# Index build, and ⌘K while it runs.
filaway-bench index --root /tmp/dev-5k  --with-queries
filaway-bench index --root /tmp/dev-20k --with-queries

# Steady-state queries.
filaway-bench keyword  --notes 5000                    # the CI gate
filaway-bench semantic --root /tmp/dev-20k --embedder hashed

# Retrieval accuracy, with and without the typo lever.
filaway-bench retrieval --embedder bge --failures
filaway-bench retrieval --embedder bge --no-typo-expansion
```

The scale corpora are the committed dev corpus replicated with fresh
front-matter ids (`Tests/Fixtures/corpus/dev` × 17 and × 67); a synthetic one
comes from `filaway-bench scan --notes 5000 --keep`. A single launch by hand:

```
FILAWAY_TIMING=1 FILAWAY_NOTES_ROOT=/tmp/notes build/Filaway.app/Contents/MacOS/Filaway
```

---

## 8. What is gated in CI, and what is not

| Check | Where | Gated? |
|---|---|---|
| Keyword p95 < 100 ms @ 5k | `.github/workflows/ci.yml` → `filaway-bench keyword --notes 5000` | **yes**, exits non-zero |
| Keyword p95 @ 5k and 20k | `SearchScaleTests`, in `swift test` | **yes** (< 100 ms / < 500 ms) |
| Retrieval ≥ 90% top-1, answer ≥ 85%, p95 < 1 s | `RetrievalGateTests`, in `swift test` | **yes** |
| Vector matrix under budget at 20k chunks | `VectorStoreTests.memoryAtScale()` | **yes** (14–20 MB) |
| Scan + metadata rebuild of 5k under 3 s | `ScaleTests.scanAndRebuild()` | **yes** |
| Typo repair behaviour | `TypoExpansionTests`, in `swift test` | **yes** (behaviour, not numbers) |
| **Launch < 2 s** | `filaway-bench launch` | **no** — needs `make app` and a windowing session; CI runners are noisy. Run before a release, record here. |
| **Semantic index build time** | `filaway-bench index` | **no** — minutes of Neural Engine work. |
| **Query latency during a build** | `filaway-bench index --with-queries` | **no** — a contention measurement is noise-sensitive. |
| **App RSS** | `Tools`-less shell sampling (§5) | **no** — needs the bundle and a windowing session. |
| **Retrieval report numbers** | `filaway-bench retrieval` | **no** — the *gate* is a test, but nothing runs the bench that produces the tables here. Worth a CI step next to the keyword one. |

Plan §4's rule stands: keyword < 100 ms is a hard CI gate; launch and semantic
latency are local metric runs recorded in the release checklist, because a
shared runner cannot tell a regression from a noisy neighbour.

---

## 9. Left undone, and why

* **Embedder warm-up during idle** — removes the ~2–3 s cold first semantic
  query (§4). One `Task` in `SemanticSearchCoordinator.start`, after the window
  is up so it cannot touch the launch budget. That file belongs to another agent
  this milestone. **TODO for the settings/a11y owner:** after `isReady = true`,
  `Task(priority: .background) { _ = try? await embedder.embed("warm") }`.
* **`SemanticSearchCoordinator`'s `catchUp()` still starts from a main-actor
  `Task`**, so it inherits `.userInitiated`. The `Indexer` now pins its own
  work to `.utility` regardless, so this is cosmetic rather than harmful —
  but `indexTask = Task(priority: .utility) { … }` would make the intent
  visible at the call site.
* **Sidebar scroll profiling** (§5.1) — blocked on Xcode.
* **Intel** (§5.1) — blocked on Xcode.
* **A `--live` semantic latency run** — blocked on an API key; the DoD names
  `filaway-bench semantic --live`, a flag that was never implemented
  (`docs/verification/M3.md` §4.1).
