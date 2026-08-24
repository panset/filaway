# M1-08 — Local embedder spike

**Task:** plan §3 M1-08, de-risks §5 risk #4 ("Core ML embedder: conversion,
tokenizer, Intel, quality ≥90%"). Timebox 4 h.
**Date:** 2026-08-22 · **Machine:** Apple M2, 16 GB, macOS 26.1 (25B78),
Swift 6.0.3, Command Line Tools only (no Xcode).
**Verdict: ship it.** Core ML embeddings work end to end on this machine, with
no Xcode, and are decisively better than every zero-download alternative.

## 1. Can we ship a local sentence embedder via Core ML?

Yes, and conversion was not painful — no pre-converted Hugging Face package was
needed.

`Tools/embedder/convert.py` traces `AutoModel` + pooling + L2 normalisation as
one graph and converts it to a fixed-shape fp16 ML Program. Converted and
verified:

| Package | Model | Pooling | Shape | On disk | torch↔Core ML cosine |
|---|---|---|---|---:|---:|
| `bge-small-en-v1.5-s256-b1` | BAAI/bge-small-en-v1.5 | CLS | [1, 256] | 63.5 MB | 0.99998 |
| `bge-small-en-v1.5-s256-b8` | same | CLS | [8, 256] | 64.8 MB | 0.99998 |
| `bge-small-en-v1.5-s64-b1` | same | CLS | [1, 64] | 63.2 MB | 0.99999 |
| `all-MiniLM-L6-v2-s256-b1` | sentence-transformers/all-MiniLM-L6-v2 | mean | [1, 256] | 43.1 MB | 0.99998 |

Pinned toolchain (both pins are load-bearing): `coremltools==9.0`,
`torch==2.7.0`, `transformers==4.56.2`, Python 3.11 via `uv`.
`transformers>=5` emits a `new_ones` op coremltools cannot convert; coremltools
9 is only tested up to torch 2.7.

### The one real trap: fp16 turns the attention mask into NaN

`transformers` builds its additive attention mask with `torch.finfo(f32).min`
(≈ −3.4e38). Under `compute_precision=FLOAT16` that becomes `-inf` and the
softmax returns **NaN for every output element**. At `--seq 64` this happened
every time; at `--seq 256` the same code survived. The failure is silent: the
model loads, predicts, and returns a vector — of NaNs. In the first bench run
it showed up only as a 5% top-1 hit rate.

Fix (now the default in `convert.py`): override `get_extended_attention_mask`
to use −1e4, the value Hugging Face uses for its own fp16 checkpoints.
Re-converted, the same package scores 100% top-1 and 0.99999 cosine.

**Consequence for M3:** the converter's torch↔Core ML parity check runs on every
conversion and must gate shipping (≥0.999). Never trust a conversion that was
not compared against the source model.

## 2. Swift API

`Sources/FilawayCore/Embeddings/` (no AppKit, Swift 6 mode, all actors):

| Type | Role |
|---|---|
| `Embedder` | `identifier`, `dimension`, `embed([String]) async throws -> [[Float]]`; every vector L2-normalised |
| `WordPieceTokenizer` | ~250 lines; HF `BasicTokenizer` + `WordpieceTokenizer` port — clean/CJK-space/lower/strip-accents/split-punctuation, greedy longest-match, `[CLS]`/`[SEP]`, truncate, pad, attention mask |
| `EmbeddingModelDescriptor` | sidecar JSON the converter writes; keeps seq length, pooling, casing in sync with the package |
| `CompiledModelStore` | `MLModel.compileModel(at:)` + cache in `~/Library/Application Support/com.tejaspanse.filaway/Models`, keyed by a package fingerprint |
| `CoreMLEmbedder` | tokenize → `MLArrayBatchProvider` → `[batch, dim]` floats; pads a partial batch for batch>1 packages |
| `NLContextualEmbedder` | `NLContextualEmbedding`, mean-pooled, with `hasAvailableAssets`/`requestAssets` handling |
| `NLSentenceEmbedder` | `NLEmbedding.sentenceEmbedding` |
| `TermOverlapRanker` | BM25 baseline for the spike |
| `RetrievalSpikeCorpus` | 40 developer notes + 20 queries with known answers |

Tokenizer parity with Hugging Face is asserted in CI against the committed
vocabulary and golden fixtures (`Tools/embedder/fixtures/`), including
`unaffable → una ##ffa ##ble`, `café Ünicode — naïve`, CJK, control characters
and truncation. Core ML tests skip themselves when `out/` is empty.

## 3. Measurements

`.build/release/filaway-bench embed`. 30 timed iterations after 3 warm-ups;
"short" = 33 tokens, "long" = 326 tokens (truncated to the model's sequence
length); batched = 32 texts in one call, divided by 32. Memory is the process
footprint delta after embedding the whole corpus.

### Cold (compile + first load), compute units `.all`

| embedder | dim | disk MB | compile ms | load+1st ms | short ms | long ms | batched ms/emb | RSS MB | top-1 | top-3 | MRR |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bge-small s256 b1 | 384 | 63.5 | 86 | 2311 | 4.55 | 5.40 | 4.06 | 27.4 | **100%** | 100% | 1.000 |
| bge-small s256 b8 | 384 | 64.8 | 58 | 3108 | 44.30 | 43.99 | 4.95 | 7.0 | 100% | 100% | 1.000 |
| bge-small s64 b1 | 384 | 63.2 | 61 | 561 | 4.84 | 8.20 | **2.03** | 24.5 | 100% | 100% | 1.000 |
| MiniLM-L6 s256 b1 | 384 | 43.1 | 47 | 1518 | 4.31 | 8.04 | 3.04 | 58.3 | **100%** | 100% | 1.000 |
| NLContextualEmbedding (mean) | 512 | 0 | — | 153 | 13.79 | 30.61 | 15.17 | 20.0 | 20% | 40% | 0.334 |
| NLEmbedding.sentenceEmbedding | 512 | 0 | — | 4 | 9.96 | 106.68 | 13.12 | 26.4 | 20% | 35% | 0.320 |
| BM25 baseline (no model) | — | 0 | — | 0 | 0.03 | 0.03 | 0.03 | 0 | 80% | 95% | 0.869 |

### Warm (second launch: compiled model cached)

| embedder | load+1st embed | short ms | long ms | batched ms/emb |
|---|---:|---:|---:|---:|
| bge-small s256 b1 | **44 ms** | 5.04 | 5.79 | 5.27 |
| bge-small s64 b1 | 67 ms | 4.68 | 7.65 | 1.97 |
| MiniLM-L6 s256 b1 | 47 ms | 2.61 | 3.42 | 2.35 |

### CPU only (`--compute-units cpu`, a proxy for Intel)

| embedder | load+1st | short ms | long ms | batched ms/emb | top-1 |
|---|---:|---:|---:|---:|---:|
| bge-small s256 b1 | 145 ms | 29.95 | 32.28 | 7.16 | 100% |
| MiniLM-L6 s256 b1 | 87 ms | 5.50 | 6.39 | 3.44 | 100% |

### Reading the numbers

* **Compile-at-runtime is a non-issue.** `MLModel.compileModel(at:)` takes
  **47–86 ms** for these packages and is cached; shipping only the `.mlpackage`
  (plan §8) costs nothing measurable. The 1.5–3.1 s "cold load" is the *first*
  `MLModel(contentsOf:)` after a compile — the Apple Neural Engine building and
  caching its own program. It happens once per install; every later launch is
  ~45 ms. Do it off the main thread anyway (NFR-1 wants <2 s to editable).
* **Fixed sequence length means constant cost.** 33-token and 326-token inputs
  cost the same at seq 256 (4.55 vs 5.40 ms — the difference is tokenisation,
  not inference). The seq-64 package is **2× faster batched** (2.03 vs
  4.06 ms/embedding) for the same disk size and identical retrieval on this
  corpus. Length bucketing is real money at 20k notes.
* **Batching only helps the small-batch packages.** The batch-8 package is not
  faster per embedding (4.95 vs 4.06) and is 10× slower for a single query —
  Core ML already pipelines an `MLArrayBatchProvider` over a batch-1 package.
  **Ship batch 1.**
* **Throughput:** at 4 ms/embedding, a 20k-note library at ~4 chunks/note is
  ~80k embeddings ≈ **5.4 minutes** of one-off indexing on an M2 (2.7 min with
  a seq-64 bucket); a single query embedding is ~5 ms against the NFR-1 5 s
  budget.
* **Memory** is a few tens of MB and dominated by the mapped weights; the first
  model measured absorbs allocator growth, so treat the per-row RSS as ±20 MB.
  Vectors themselves are tiny: 80k × 384 × 4 B = 123 MB as Float32, **61 MB as
  Float16** — plan §1's in-memory matrix is fine, `sqlite-vec` stays a
  Phase-2 escape hatch.

### Quality, honestly

Both Core ML models answered **20/20** queries correctly at rank 1 on a corpus
they should find easy. The NaturalLanguage embedders answered **4/20** — they
are not competitive for this task at all (mean-pooling a contextual model is a
weak sentence encoder, and `NLEmbedding.sentenceEmbedding` is a static model).
BM25 got **16/20**, which mostly says the corpus is too small and too topically
separated (40 notes, one per topic): the queries avoid the notes' vocabulary,
but "container", "commit" and "certificate" still leak through.

So: this is a **directional** result. It proves the pipeline is correct and that
bge-small/MiniLM understand developer English; it does **not** establish the
≥90% top-1 gate, and it does not separate bge-small from MiniLM. M3-07 must do
that on a 5k/20k generated corpus with real chunking and hybrid ranking.

## 4. Recommendation

**Ship `bge-small-en-v1.5`, fp16, CLS-pooled, fixed seq 256, batch 1, bundled
as an `.mlpackage` compiled on first launch.**

Why bge-small over MiniLM despite MiniLM being 20 MB smaller and ~1.5× faster:
same 384-d output, both perfect here, but bge-small is the stronger model on
MTEB and has an asymmetric-query convention (see M3-01 below) that fits
"question → note" retrieval. MiniLM stays a one-line swap
(`RetrievalSpikeCorpus` + `filaway-bench embed` already measure both) and is the
right answer if M3-07 finds them equal — 20 MB and 1.5× throughput are worth
having.

### Fallback ladder (plan §5 risk #4, updated)

1. **`CoreMLEmbedder` (bge-small)** — the shipped path.
2. **`CoreMLEmbedder` (MiniLM-L6)** — same code, swap the package; also the
   answer if bundle size becomes a release blocker.
3. **`NLContextualEmbedder`** — *demoted*. 4/20 here, needs a several-hundred-MB
   OS asset download, and is slower than the Core ML model. Keep the code (it
   costs nothing and Apple may improve it), but do **not** present it as an
   equivalent option in Settings.
4. **`NLSentenceEmbedder`** — same story, marginally worse.
5. **Keyword-only (FTS5 BM25) + Claude rerank** — the honest fallback. It scored
   16/20 here, i.e. better than either NL embedder. If the Core ML model cannot
   load, degrade to hybrid-without-vectors and say so in the UI (FR-5.5,
   FR-6.4), rather than silently using a worse embedder.

### Bundle size

* `.mlpackage` in the app: **63.5 MB** (+232 KB vocab), **57.9 MB** in the DMG
  after compression. MiniLM would be 43.1 MB / ~39 MB.
* Application Support gains a **64 MB** compiled `.mlmodelc` on first launch —
  budget ~128 MB of disk per install, and delete the cache on "Rebuild index".
* Plan §1 estimated 35–65 MB bundled; bge-small lands at the top of that range.
  If it must shrink, coremltools palettization (8-bit → ~33 MB, 6-bit → ~25 MB)
  is the lever, gated on an M3-07 quality re-run. Untested in this spike.

### Intel caveat

No Intel Mac was available, and this machine cannot build universal binaries
(plan §8: needs Xcode's `xcbuild`). CPU-only on the M2 is the closest proxy:
bge-small goes from 4.55 → 30 ms per single embedding, 4.06 → 7.16 ms batched;
MiniLM only 4.31 → 5.50 ms. Extrapolating ~2–3× again for older Intel silicon,
a full 20k-note index would be roughly 30–60 minutes of background work on
Intel, and a query embedding ~50–100 ms — acceptable for NFR-1's 5 s, painful
for a first-run reindex. Nothing here is *blocking*: Core ML runs everywhere,
which is why the plan chose it over MLX.

**Action:** on Intel, prefer MiniLM (its CPU penalty is small), throttle the
initial index build, and re-measure on real hardware before the first public
release. This must be a line item in M3-09/M4-07.

## 5. How M3-01 should proceed

1. **Take this code as the starting point.** `Embeddings/` is written to be the
   real implementation, not throwaway: protocol, tokenizer, descriptor, compile
   cache, three embedders, tests. M3-01 adds resource bundling and wiring.
2. **Bundle the package as a SwiftPM resource** on `FilawayCore`
   (`.copy("Embeddings/Resources/bge-small-en-v1.5-s256-b1.mlpackage")`) plus
   the vocab and descriptor JSON, and resolve it through `Bundle.module`. Keep
   `Tools/embedder/out` as the regeneration source; add a `make model` target
   that copies `out/` into the resource folder so the 63 MB blob is built, not
   committed. Confirm `Tools/make_app.sh` copies package resources into
   `Filaway.app/Contents/Resources`.
3. **Compile on a background task at first launch**, not lazily inside the first
   query: `CompiledModelStore.compiledModel(forPackageAt:)` then hold the
   `CoreMLEmbedder` in the `Indexer` actor. Surface "Preparing semantic
   index…" if it is not ready.
4. **Use bge's query prefix.** bge-small-en-v1.5 expects
   `"Represent this sentence for searching relevant passages: "` before a
   *query* (not before documents). It is not applied anywhere in this spike;
   M3-07 must measure with and without it, and whichever wins becomes part of
   `identifier`.
5. **Chunk to the model, not to the prose.** Fixed seq 256 means a 40-token
   chunk costs the same as a 250-token chunk: aim chunks at 180–250 tokens
   using `CoreMLEmbedder.tokenCount(_:)`, and consider shipping the seq-64
   package as a second bucket for short chunks (2× throughput, measured above).
6. **Store `Embedder.identifier` next to every vector** and re-embed when it
   changes; store vectors as Float16 BLOBs.
7. **Extend, don't replace, `filaway-bench embed`.** M3-07's benchmark should
   reuse `evaluateRetrieval` and add the generated corpus, the query prefix
   variants, hybrid RRF and the ≥90% gate.
8. **Keep the parity check in the loop:** any re-conversion must print a
   ≥0.999 torch↔Core ML cosine before the package is used.

## 6. Reproduce

```sh
Tools/embedder/regenerate.sh                      # ~3 min, needs the venv from Tools/embedder/README.md
swift build -c release
.build/release/filaway-bench embed --recompile    # cold numbers
.build/release/filaway-bench embed                # warm numbers
.build/release/filaway-bench embed --compute-units cpu --skip-nl
swift test                                        # Core ML tests activate once out/ exists
```
