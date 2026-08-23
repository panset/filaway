# Embedder conversion (M1-08)

Converts a Hugging Face sentence-embedding model into a Core ML `.mlpackage`
that `FilawayCore`'s `CoreMLEmbedder` can run. Findings and the M3
recommendation live in [`docs/spikes/embedder.md`](../../docs/spikes/embedder.md).

**Nothing here is required to build or test the app.** The `.mlpackage` files
are 43–66 MB and are *not* committed (`.gitignore`s `out/` and `.venv/`); the
Swift tests that need them skip themselves when they are absent.

## What *is* committed

| Path | Size | Why |
|---|---|---|
| `convert.py`, `regenerate.sh` | — | reproduce every artefact |
| `fixtures/bge-small-en-v1.5.vocab.txt` | 232 KB | the Swift WordPiece tokenizer is tested against the real vocabulary in CI |
| `fixtures/bge-small-en-v1.5.golden.json` | 27 KB | Hugging Face tokenizations + reference vectors for parity tests |

## Regenerate

Needs Python 3.11 (coremltools does not support 3.13) and ~3 GB of wheels.

```sh
uv venv --python 3.11 Tools/embedder/.venv
VIRTUAL_ENV=$PWD/Tools/embedder/.venv uv pip install \
    "coremltools==9.0" "torch==2.7.0" "transformers==4.56.2" "numpy<2"

Tools/embedder/regenerate.sh          # all four packages, ~3 min, ~250 MB of HF downloads
```

The version pins matter:

* `transformers>=5` emits a `new_ones` op that coremltools 9 cannot convert;
* coremltools 9 has only been tested up to torch 2.7 (2.13 warns and may break
  tracing).

One model at a time:

```sh
Tools/embedder/.venv/bin/python Tools/embedder/convert.py \
    --model BAAI/bge-small-en-v1.5 --seq 256 --batch 1 --pooling cls
```

Each run writes to `out/`:

| File | Contents |
|---|---|
| `<name>-s<seq>-b<batch>.mlpackage` | fp16 ML Program: encoder → pooling → L2 normalise |
| `<name>-s<seq>-b<batch>.json` | descriptor (`EmbeddingModelDescriptor` decodes it) |
| `<name>.vocab.txt` | WordPiece vocabulary |
| `<name>.golden.json` | tokenizer cases + reference vectors, and the torch↔Core ML cosine |

The last step of every run predicts three sentences with the freshly saved
package and prints its cosine against the PyTorch original. **Do not ship a
package whose cosine is not ≥0.999.** This check is why `--skip-golden` exists
but should stay unused: it is what caught the fp16 NaN below.

## The fp16 attention-mask trap

`transformers` builds its additive attention mask with
`torch.finfo(float32).min` (≈ −3.4e38). Under `compute_precision=FLOAT16` that
becomes `-inf`, and the softmax then returns **NaN for every output value**.
It reproduced 100% of the time at `--seq 64` while `--seq 256` happened to
survive, so it is a silent, shape-dependent corruption.

`convert.py` therefore replaces `get_extended_attention_mask` with one that uses
−1e4 (what Hugging Face itself uses for fp16 checkpoints). `--raw-mask` restores
the original behaviour if you ever need to reproduce the failure.

## Measure

```sh
swift build -c release
.build/release/filaway-bench embed --recompile        # cold-compile timings
.build/release/filaway-bench embed --compute-units cpu   # Intel proxy
```
