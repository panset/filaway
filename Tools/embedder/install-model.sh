#!/bin/bash
# Copies the freshly converted shipping package into the FilawayCore resource
# folder (M3-01). Run after `Tools/embedder/regenerate.sh`, from the repo root.
#
# The `.mlpackage` IS committed (ADR-022): one 63.5 MB binary, refreshed only
# when `convert.py` changes. Never install a package whose torch↔Core ML cosine
# was below 0.999 — `convert.py` prints it as its last step.
set -euo pipefail

STEM="bge-small-en-v1.5-s256-b1"
VOCAB="bge-small-en-v1.5.vocab.txt"
OUT="Tools/embedder/out"
DEST="Sources/FilawayCore/Resources/Models"

for file in "$OUT/$STEM.mlpackage" "$OUT/$STEM.json" "$OUT/$VOCAB"; do
    [ -e "$file" ] || { echo "missing $file — run Tools/embedder/regenerate.sh first"; exit 1; }
done

mkdir -p "$DEST"
rm -rf "${DEST:?}/$STEM.mlpackage"
cp -R "$OUT/$STEM.mlpackage" "$DEST/"
cp "$OUT/$STEM.json" "$DEST/"
cp "$OUT/$VOCAB" "$DEST/"

# The tokenizer fixtures are committed separately so the parity tests run in CI.
cp "$OUT/$VOCAB" Tools/embedder/fixtures/
cp "$OUT/bge-small-en-v1.5.golden.json" Tools/embedder/fixtures/

echo "installed into $DEST:"
du -sh "$DEST"/*
