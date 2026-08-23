# M3-09 — semantic performance and scale

**Task:** plan §3 M3-09 (NFR-1, NFR-2). **Date:** 2026-08-23.
**Machine:** Apple M2, 16 GB, macOS 26.1, Swift 6.0.3, release build, warm
compiled-model cache.

**Verdict: NFR-1 and NFR-2 are met, and the alarming M3-03 numbers were an
artefact of the corpus they were measured on.** A 5,000-note library of
realistic notes indexes in **50 seconds**, not 409; a 20,000-note library holds
a **33 MB** vector matrix, not 273 MB. Queries are 20 ms at p95 over 5,000
notes and 42 ms over 20,000, against NFR-1's 5 s budget — the Claude answer step
gets essentially all of it.

## 1. The finding: which corpus you measure decides the answer

`SyntheticCorpus` writes a fenced code block every fifth paragraph, and ADR-039
makes every fence unconditionally its own chunk. That produces **17.3 chunks per
2 KB note**. Index-build time and resident memory are both *linear in chunk
count*, so every M3-03 number inherits that density.

The M3-07 development corpus is hand-written developer notes — prose with one
command in it — and the same chunker produces **2.0 chunks per note**. Measured
side by side at 5,000 notes with the bundled bge-small model:

| | `SyntheticCorpus` (2 KB/note) | Dev-corpus shape |
|---|--:|--:|
| Chunks | 85,130 (17.0/note) | **10,163 (2.0/note)** |
| Index build | 409 s | **49.8 s** (100 notes/s) |
| Per embedding | 4.8 ms | 4.9 ms |
| Derived database | 55 → 179 MB | 23.2 → **42.3 MB** |
| Resident matrix | 68.3 MB | **8.2 MB** |
| Re-index one edited note | 12.7 ms | **8.1 ms** |

The per-embedding cost is identical, as it must be. Everything else differs by
the chunk ratio. Both corpora are legitimate — `SyntheticCorpus` is a
command-dense worst case and stays the scale fixture for the filesystem and
database work — but **NFR-2 should be reported against notes a person would
write** (ADR-042).

The scale corpora here are the dev corpus replicated with fresh front-matter
ids (`Tests/Fixtures/corpus/dev` × 17 and × 67).

## 2. NFR-2: 5,000 and 20,000 notes

Dev-corpus shape throughout. The 20,000-note query row was measured with
`--embedder hashed`, so add ~5 ms for the real model's query embedding;
everything else on that path is embedder-independent.

| | 5,000 notes | 20,000 notes |
|---|--:|--:|
| Notes scanned + metadata rebuilt | 1.0 s | 6.3 s |
| Chunks | 10,163 | 40,611 |
| Index build (bundled bge-small) | **49.8 s** (100 notes/s) | **220 s** (91 notes/s) |
| Resident matrix | **8.2 MB** | **32.6 MB** |
| Process growth on first load | +16.8 MB | +37.9 MB |
| Lazy matrix load (first query) | **43.5 ms** | **131.5 ms** |
| Derived database | 23.2 → 42.3 MB | 89.5 → 168.2 MB |
| Query p50 / p95 (both arms + RRF, no Claude) | **18.6 / 20.1 ms** | **27.2 / 41.8 ms** |
| Re-index one edited note | 8.1 ms | 20.8 ms |

NFR-2 asks for smooth at 5,000 and graceful at 20,000. The matrix at 20,000
notes is 33 MB — an order of magnitude inside the ~200 MB budget that the
synthetic corpus appeared to blow through — and it is **loaded lazily**, so a
user who only ever presses ⌘K never pays any of it.

## 3. NFR-1: the query path

| | p50 | p95 | max |
|---|--:|--:|--:|
| 5,000 notes, bundled model | 18.6 ms | **20.1 ms** | 22.5 ms |
| 20,000 notes, hashed (+~5 ms for the real query embedding) | 27.2 ms | **41.8 ms** | 45.7 ms |
| M3-07 dev corpus, 302 notes, bundled model | 12 ms | 17 ms | — |

Breakdown at 5,000 notes: ~5 ms to embed the query, the rest split between the
blocked `vDSP_mmul` scan and the FTS5 arm. NFR-1 allows 5 s *including* the
Claude answer step, so the offline half uses 0.4% of the budget.

**First-query cost** is the number a user actually feels, and it is three
things stacked:

| | Cost | When |
|---|--:|---|
| Compile the `.mlpackage` | 47–86 ms | Once, ever (cached in Application Support) |
| Load the model + first embed | 1.5–3 s cold, ~45 ms warm | First query after launch |
| Lazy-load the vector matrix | 43 ms at 5k, 132 ms at 20k | First semantic query after launch |

So a cold first semantic query is ~2–3 s, dominated by the Neural Engine
building its program, and every subsequent one is ~20 ms. Warming the embedder
off the main actor during idle — after the window is up, so it cannot touch
NFR-1's 2 s launch budget — removes it. That is an M4-07 item.

## 4. Index build: which levers are real

`filaway-bench index --notes 500` with the bundled model, varying one thing.

**Compute units — not a lever.**

| `--compute-units` | ms/embedding | 500-note build |
|---|--:|--:|
| `all` (default) | 4.4 | 37.5 s |
| `cpuAndNeuralEngine` | 4.3 | 37.4 s |
| `cpuAndGPU` | 6.8 | 58.7 s |

`.all` already picks the Neural Engine. The GPU is 55% slower; leave the
default alone.

**Batch size — not a lever.**

| `--embed-batch` | ms/embedding |
|---|--:|
| 1 | 4.8 |
| 32 (default) | 4.8 |
| 128 | 4.7 |

ADR-012 traced the package at a fixed batch of 1, so `MLArrayBatchProvider`
only pipelines; the Swift-side batching saves loop overhead that is already
noise. A batch-8 package was measured in the M1-08 spike at 4.95 ms/embedding
against 4.06 for batch-1 — *worse*, and it costs 10× on single-query latency.
Nothing to win here.

**Chunk density — not a lever on realistic notes.**

| `--min-tokens` (ADR-039) | chunks / 1,000 synthetic notes |
|---|--:|
| 64 (default) | 17,262 |
| 128 | 16,461 (−4.6%) |

Raising `minTokens` barely moves it, because the synthetic corpus's density is
*code fences*, which never fold (ADR-039 point 2). On realistic notes there is
nothing to fold in the first place — 2.0 chunks per note is already the floor.
ADR-039's "next levers" are therefore **not needed**, and the ADR-038 note
about 273 MB at 20,000 notes should be read as the synthetic worst case.

**Skipping unchanged chunks — already implemented, and it is the big one.**
`Indexer` embeds only chunks whose `textHash` changed. Editing a note costs
**8.1 ms** — one embedding recomputed, two chunks reused — against 10 ms if
everything were re-embedded. Inserting a paragraph at the top of a note
renumbers every ordinal and re-embeds nothing. FR-5.4's budget is 5 s.

## 5. What to do about the first-launch index build

Fifty seconds at 5,000 notes and 220 s at 20,000 are fine as background work
and unacceptable as a wait. It should not be a wait at all:

1. **Never block launch on it.** The metadata scan and the FTS5 index are ready
   in 1 s at 5,000 notes, so ⌘K keyword search works immediately (FR-5.5 is
   already the designed degradation). The semantic index is a background
   catch-up, and `Indexer.status` / `statusStream()` already publish
   `.indexing(n, of:)` for a progress row in Settings.
2. **Run it at background QoS.** `Indexer.rebuildAll()` inherits the caller's
   priority; the app should start it from a `Task(priority: .utility)` so it
   never competes with typing. Recommended, not implemented here — it is one
   line at the call site in `FilawayApp`, which this task does not own.
3. **Index most-recent-first.** A user searches for what they wrote last week,
   not what they wrote in 2019. `staleNoteIDs(limit:)` ordering by mtime
   descending would make the first minute of indexing cover the notes that
   matter. Proposed for M4-07.
4. **Do not re-index across launches.** Already true: chunks and embeddings are
   persistent, `catchUp()` only touches what is stale, and a model change
   re-embeds without re-chunking (`synchronizeModel()`).

With (1) and (2), a first launch on a 20,000-note library is: window in under
2 s, keyword search immediately, semantic search progressively better over
about four minutes, at no cost to interactivity.

## 6. Gaps

* **The 20,000-note index build is one measurement, not a distribution.** It
  came in at 220 s against 199 s extrapolated from the 5,000-note run — 5.4 ms
  per embedding rather than 4.9 — so there is roughly a 10% super-linearity to
  account for (larger transactions, a colder page cache), but no cliff.
* **Memory was measured as the matrix plus the process delta on first load**,
  not as a footprint under sustained use. M4-07's Instruments pass owns that.
* **Background QoS and most-recent-first indexing are recommendations**, not
  code: both live at the app's call site (M4-07).
* **Intel is unmeasured.** No universal build is possible without Xcode
  (plan §8); Core ML on x86_64 has no Neural Engine, so the index build there
  will be materially slower and needs its own measurement once the toolchain
  allows it.
