#!/bin/bash
# Regenerates every Core ML package the M1-08 spike measures.
# Run from the repo root, after Tools/embedder/README.md's venv setup.
set -euo pipefail

PY="Tools/embedder/.venv/bin/python"
[ -x "$PY" ] || { echo "missing $PY — see Tools/embedder/README.md"; exit 1; }

"$PY" Tools/embedder/convert.py --model BAAI/bge-small-en-v1.5 --seq 256 --batch 1 --pooling cls
"$PY" Tools/embedder/convert.py --model BAAI/bge-small-en-v1.5 --seq 256 --batch 8 --pooling cls
"$PY" Tools/embedder/convert.py --model BAAI/bge-small-en-v1.5 --seq 64  --batch 1 --pooling cls
"$PY" Tools/embedder/convert.py --model sentence-transformers/all-MiniLM-L6-v2 \
    --seq 256 --batch 1 --pooling mean

# The tokenizer fixtures ARE committed (265 KB) so the parity tests run in CI.
cp Tools/embedder/out/bge-small-en-v1.5.vocab.txt Tools/embedder/fixtures/
cp Tools/embedder/out/bge-small-en-v1.5.golden.json Tools/embedder/fixtures/

echo
echo "Packages in Tools/embedder/out (not committed — 43-66 MB each):"
du -sh Tools/embedder/out/*.mlpackage
