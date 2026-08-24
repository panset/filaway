# Running Filaway on a local model

**Task:** plan Phase 2 (P2-01…04). **Spec:** FR-6.5, NFR-5. **Date:** 2026-08-24.

Filaway can do its two AI jobs — filing a session (FR-4.1) and the ⌘K answer
card (FR-5.2) — against a model running on your own Mac, through
[Ollama](https://ollama.com). No API key, no bill, and **nothing you write ever
leaves the machine**.

Everything else already works with no AI at all: capture, the sidebar, keyword
⌘K, and semantic retrieval itself (FR-5.5). The local model buys you the two
things that need a language model.

---

## 1. Setting it up

```bash
brew install ollama          # or the .app from ollama.com/download
ollama serve                 # leave it running (see § 2)
ollama pull llama3.1:8b      # ~4.9 GB, the model Filaway is developed against
```

Then in Filaway: **Settings → AI → Local model (Ollama)**, or pick it on the
first-run screen. **Test connection** asks the daemon what it has pulled, so a
green line there means the whole path works — address, daemon, model tag.

| It says | What to do |
|---|---|
| `Connected · llama3.1:8b · fully private` | nothing |
| `Model not pulled — run: ollama pull llama3.1:8b` | run that |
| `No daemon at http://localhost:11434` | `ollama serve`, or fix the address |

There is nothing to enter but an address. `http` is accepted **only** for
`localhost` / `127.0.0.1` / `::1`; a daemon on another machine must be `https`,
because otherwise the "your notes never leave the Mac" claim would quietly stop
being true (ADR-066).

## 2. Keeping the daemon up

Filaway never starts Ollama for you. Two ways to have it there:

- **The Ollama app** — it installs a login item and runs in the menu bar. Easiest.
- **`ollama serve` yourself**, from a terminal or a LaunchAgent.

Filaway asks the daemon to keep the model resident for **30 minutes** after each
call (`keep_alive: "30m"`), and fires one empty preload at launch, because a
cold model load costs seconds and the answer card is on ⌘K's path (ADR-069).
A model that has gone cold is not an error — the next call just takes longer.

## 3. What it costs in memory and time

`llama3.1:8b` at Q4_K_M is about 4.9 GB on disk and wants roughly **6 GB of
free RAM** while resident. On a 16 GB M2 laptop, measured on Filaway's own
prompts (`make bench ARGS="ollama probe"`):

| | cold (model not loaded) | warm |
|---|---|---|
| answer card (`answer.v1`, ~980 prompt tokens) | 12.8 s | **3.2 s** |
| organize a session (`organize.v1`, ~2,000 prompt tokens) | 22.3 s | **7.3 s** |

The organize prompt is 2,000 tokens against the model's 131,072-token context —
1.5% of it. Context length is not the constraint; speed is.

**What that means in the app.**

*Filing* is never on a visible path: the card appears when it appears, and the
budget is 180 s. This is where the local model earns its keep.

*The answer card* is on ⌘K's path and gets **5 s**, after which Filaway shows
its own offline card instead (FR-5.5, ADR-054). Measured over the 89-query dev
set, an 8 B model on this machine took **23.8 s at the median** on a real ⌘K
prompt — eight retrieved chunks, ~3,200 tokens — so in practice *the offline
card is what you will see*. It is not a downgrade worth worrying about: on that
same set the offline card picked the right snippet 94% of the time against the
local model's 78%. Keyword and semantic **retrieval** are unaffected either way;
they never involve a model.

If you want the model's card on ⌘K, point search at something small — Settings
→ AI lets you pick the tag, and `llama3.2:3b` is roughly 3× faster.

## 4. Choosing a model

| Model | RAM | What to expect |
|---|---|---|
| `llama3.1:8b` | ~6 GB | the default here. 8 of 9 organize scenarios produce a usable plan; answer cards are reliable |
| `llama3.2:3b` | ~3 GB | faster, weaker plans — try it if 8B is too slow, and read § 5 |
| a 13–14B model | ~10 GB | better plans, roughly 2× the latency. Worth it on 32 GB |
| `claude-sonnet-5` (Settings → AI → Claude) | — | the best plans, ~$16/month (`docs/cost.md`) |

Change the tag in **Settings → AI**; the popup lists what `ollama list` would.

### If the plans are poor

In order of how much they buy:

1. **Use a bigger model.** Plan quality is where model size shows most.
2. **Check the note actually reached the prompt.** Filaway sends the session
   text plus a handful of candidate notes, never the whole library. A merge
   target that was never a candidate cannot be chosen.
3. **Switch to Ask mode** (Settings → AI → "Ask before organizing"), which is
   the default. Then a plan you dislike costs one Escape.
4. **Report it.** Help → Export Diagnostics… is content-free (NFR-4) and
   includes which model produced which plan.

Filaway already repairs the two mistakes small models make most — naming a note
that exists as one to *create*, and paraphrasing a block it meant to move. Both
repairs are strictly additive and are shown on the card as "the plan was
adjusted" (ADR-070). What it will never do is guess about *removing* your text.

## 5. Privacy

With the local provider selected:

- The only network destination is your own daemon; `http` is refused to anything
  that is not loopback.
- No key, no account, no telemetry. `AIUsageLedger` records local calls
  separately from billed ones and reports $0.
- The excluded-folder rule (FR-4.5) applies exactly as it does to Claude:
  a folder marked "never send to AI" is filtered out *before* a prompt is built,
  and the committed local recordings are grepped for it in CI.

Filaway's own AI settings still apply — excluded folders, ask vs auto, the idle
interval — because they are enforced above the provider, not inside it.

## 6. Environment variables

For development and for the smoke suite. None of these are needed to use the app.

| Variable | Effect |
|---|---|
| `FILAWAY_AI_PROVIDER=ollama` | forces the backend for this launch, ahead of the preference (ADR-069) |
| `FILAWAY_AI_MODE=replay\|record\|live` | the harness axis, independent of the backend. `replay` is the default and reaches no network |
| `FILAWAY_AI_FIXTURES=<dir>` | where recordings are read and written. **Record into a scratch directory and diff before committing** (ADR-067) |
| `FILAWAY_TEST_OLLAMA=1` | enables the test suites that talk to the real daemon (`OllamaLiveProbeTests`, `OllamaLiveGoldenTests`) |
| `FILAWAY_OLLAMA_VERBOSE=1` | those suites also print the validator's content-free summary per scenario |
| `FILAWAY_SMOKE_OLLAMA=1` | enables the gated `organize-ollama` smoke phase; without it the phase prints SKIPPED and is not a failure |
| `FILAWAY_SMOKE_OLLAMA_MODEL=<tag>` | what that phase expects to see on the Activity row |
| `FILAWAY_SMOKE_ONLY="a b c"` | run only these smoke phases |

```bash
# is the daemon usable, and how fast on Filaway's own prompts?
make bench ARGS="ollama probe"

# the answer card, live, over the 89-query dev set
make bench ARGS="retrieval --embedder bge --answer ollama"

# the organize goldens against the daemon, with a per-scenario table
FILAWAY_TEST_OLLAMA=1 swift test --filter OllamaLiveGoldenTests

# the end-to-end smoke phase against the daemon
FILAWAY_SMOKE_OLLAMA=1 FILAWAY_SMOKE_ONLY="organize-ollama" Tools/smoke.sh
```

Measured numbers, per scenario and before/after the ADR-070 repair:
`docs/verification/P2-ollama.md`.
