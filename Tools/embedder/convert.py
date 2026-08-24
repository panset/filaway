#!/usr/bin/env python3
"""Convert a Hugging Face BERT-family sentence embedder to a Core ML .mlpackage.

M1-08 (embedder spike, plan §5 risk #4). Produces, under ``Tools/embedder/out``:

  <name>-s<seq>-b<batch>.mlpackage   fp16 ML Program, fixed input shape
  <name>.vocab.txt                   WordPiece vocabulary for the Swift tokenizer
  <name>-s<seq>-b<batch>.json        metadata (dim, pooling, seq, batch, sizes)
  <name>.golden.json                 tokenizer + embedding fixtures for Swift tests

Pooling and L2 normalisation are baked into the graph, so the Swift side only
has to tokenize and read a [batch, dim] float array back out.

Usage (from the repo root):

    Tools/embedder/.venv/bin/python Tools/embedder/convert.py \
        --model BAAI/bge-small-en-v1.5 --seq 256 --batch 1 --pooling cls

See Tools/embedder/README.md.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import sys
import types
import time

OUT = pathlib.Path(__file__).resolve().parent / "out"

# Sentences used for the golden fixtures and for a quick parity check.
GOLDEN_SENTENCES = [
    "How do I copy a file to a remote host?",
    "scp ./report.pdf user@host:/tmp/",
    "The cat sat on the mat.",
]

GOLDEN_TOKENIZER_CASES = [
    "unaffable",
    "Hello, world!",
    "kubectl get pods -n kube-system",
    "café Ünicode — naïve",
    "docker run --rm -it ubuntu:22.04 /bin/bash",
    "  multiple   spaces\tand\nnewlines ",
    "生活好",
    "supercalifragilisticexpialidocious",
    "",
]


def dir_size(path: pathlib.Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="BAAI/bge-small-en-v1.5")
    ap.add_argument("--name", default=None, help="output basename (default: model basename)")
    ap.add_argument("--seq", type=int, default=256)
    ap.add_argument("--batch", type=int, default=1)
    ap.add_argument("--pooling", choices=["cls", "mean"], default="cls")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    ap.add_argument(
        "--raw-mask",
        action="store_true",
        help="use transformers' own additive attention mask (-3.4e38), which "
        "overflows fp16 and produced all-NaN output at seq 64 — see docs/spikes/embedder.md",
    )
    ap.add_argument("--skip-golden", action="store_true")
    args = ap.parse_args()

    import numpy as np
    import torch
    import coremltools as ct
    from transformers import AutoModel, AutoTokenizer

    name = args.name or args.model.split("/")[-1]
    OUT.mkdir(parents=True, exist_ok=True)

    print(f"[1/6] loading {args.model}")
    tok = AutoTokenizer.from_pretrained(args.model)
    # eager attention: SDPA/flash kernels do not trace into a Core ML-friendly graph.
    model = AutoModel.from_pretrained(args.model, attn_implementation="eager").eval()
    dim = model.config.hidden_size

    class Wrapped(torch.nn.Module):
        """BERT encoder + pooling + L2 normalisation, one graph."""

        def __init__(self, encoder: torch.nn.Module, pooling: str) -> None:
            super().__init__()
            self.encoder = encoder
            self.pooling = pooling

        def forward(self, input_ids, attention_mask):  # type: ignore[no-untyped-def]
            hidden = self.encoder(input_ids=input_ids, attention_mask=attention_mask)[0]
            if self.pooling == "cls":
                pooled = hidden[:, 0]
            else:
                mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
                pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
            return pooled / pooled.norm(dim=-1, keepdim=True).clamp(min=1e-12)

    if not args.raw_mask:
        # transformers builds its additive attention mask with
        # torch.finfo(float32).min ≈ -3.4e38. Core ML's fp16 compute precision
        # turns that into -inf, and the softmax then yields NaN for the whole
        # output (reproduced at seq 64; seq 256 happened to survive). -1e4 is
        # the value Hugging Face itself uses for fp16 models and is far below
        # any real logit, so the result is numerically identical where it is
        # not NaN.
        def fp16_safe_extended_attention_mask(
            self, attention_mask, input_shape, device=None, dtype=None
        ):  # noqa: ANN001
            mask = attention_mask[:, None, None, :].to(torch.float32)
            return (1.0 - mask) * -1e4

        model.get_extended_attention_mask = types.MethodType(
            fp16_safe_extended_attention_mask, model
        )

    wrapped = Wrapped(model, args.pooling).eval()

    shape = (args.batch, args.seq)
    example_ids = torch.zeros(shape, dtype=torch.int64)
    example_mask = torch.ones(shape, dtype=torch.int64)

    print(f"[2/6] tracing at shape {shape}")
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, (example_ids, example_mask), strict=False)

    print("[3/6] converting to Core ML (mlprogram, %s)" % args.precision)
    precision = ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
    t0 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embeddings", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    print(f"      converted in {time.time() - t0:.1f}s")

    mlmodel.short_description = (
        f"{args.model} — {args.pooling.upper()} pooled, L2-normalised sentence embeddings "
        f"({dim}-d, seq {args.seq}, batch {args.batch}, {args.precision})."
    )
    mlmodel.author = "Filaway M1-08 spike (Tools/embedder/convert.py)"
    mlmodel.version = "1"
    mlmodel.input_description["input_ids"] = "WordPiece ids, [CLS] … [SEP], padded with 0"
    mlmodel.input_description["attention_mask"] = "1 for real tokens, 0 for padding"
    mlmodel.output_description["embeddings"] = f"[{args.batch}, {dim}] unit-length embedding"

    stem = f"{name}-s{args.seq}-b{args.batch}"
    pkg = OUT / f"{stem}.mlpackage"
    if pkg.exists():
        shutil.rmtree(pkg)
    print(f"[4/6] saving {pkg}")
    mlmodel.save(str(pkg))

    print("[5/6] writing vocab + metadata")
    vocab_files = tok.save_vocabulary(str(OUT), filename_prefix=name)
    vocab_path = pathlib.Path(vocab_files[0])
    canonical_vocab = OUT / f"{name}.vocab.txt"
    if vocab_path != canonical_vocab:
        shutil.move(str(vocab_path), canonical_vocab)

    meta = {
        "model": args.model,
        "fp16SafeMask": not args.raw_mask,
        "name": name,
        "dimension": dim,
        "pooling": args.pooling,
        "maxSequenceLength": args.seq,
        "batchSize": args.batch,
        "precision": args.precision,
        "normalized": True,
        "lowercase": bool(getattr(tok, "do_lower_case", True)),
        "vocabSize": len(tok.get_vocab()),
        "packageBytes": dir_size(pkg),
        "vocabBytes": canonical_vocab.stat().st_size,
        "coremltools": ct.__version__,
        "torch": torch.__version__,
    }
    (OUT / f"{stem}.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta, indent=2))

    if args.skip_golden:
        return 0

    print("[6/6] golden fixtures + parity check")
    golden = {
        "model": args.model,
        "pooling": args.pooling,
        "maxSequenceLength": args.seq,
        "tokenizer": [],
        "embeddings": [],
    }
    for text in GOLDEN_TOKENIZER_CASES:
        enc = tok(text, truncation=True, max_length=args.seq)
        golden["tokenizer"].append(
            {
                "text": text,
                "tokens": tok.convert_ids_to_tokens(enc["input_ids"]),
                "ids": enc["input_ids"],
            }
        )

    for text in GOLDEN_SENTENCES:
        enc = tok(
            text,
            padding="max_length",
            truncation=True,
            max_length=args.seq,
            return_tensors="pt",
        )
        with torch.no_grad():
            ref = wrapped(enc["input_ids"], enc["attention_mask"])[0].numpy()
        # A batch>1 package only accepts its exact shape: tile the row and read
        # the first result back.
        pred = mlmodel.predict(
            {
                "input_ids": np.tile(enc["input_ids"].numpy(), (args.batch, 1)).astype(np.int32),
                "attention_mask": np.tile(enc["attention_mask"].numpy(), (args.batch, 1)).astype(np.int32),
            }
        )["embeddings"][0]
        cos = float(np.dot(ref, pred) / (np.linalg.norm(ref) * np.linalg.norm(pred)))
        print(f"      torch↔coreml cosine = {cos:.6f}  ({text[:40]!r})")
        golden["embeddings"].append(
            {
                "text": text,
                "ids": enc["input_ids"][0].tolist(),
                "torchCosineWithCoreML": cos,
                "coreml": [round(float(x), 6) for x in pred],
            }
        )

    (OUT / f"{name}.golden.json").write_text(json.dumps(golden, indent=2) + "\n")
    print(f"      wrote {OUT / (name + '.golden.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
