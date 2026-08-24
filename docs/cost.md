# What Filaway costs to run

**Task:** plan §3 M4-09 ("document per-session cost estimate"), FR-6.2, FR-6.6.
**Date:** 2026-08-23. **Prices:** the list prices this estimate was built on —
Sonnet 5 **$3 / $15** per MTok in/out, Haiku 4.5 **$1 / $5**, Opus 5
**$5 / $25**.

**Headline: about **$16 a month** for a heavy day repeated every day** — 15
writing sessions filed and 30 natural-language searches, seven days a week.
A five-day week is **$11**. The plausible worst case, with every session
hitting its context budget and its thinking cap, is **$44**; the floor, on
sessions the size of the committed fixtures, is **$8**.

The user pays their own API bill (FR-6.1), so this document exists to answer
"is that a coffee or a phone bill?" before they connect a key. It is a coffee.

---

## 1. Where the numbers come from

Two request shapes reach Anthropic, and nothing else does.

| | `organize.v1` | `answer.v1` |
|---|---|---|
| When | once per writing session that changed something (FR-3.1) | once per **Ask** search — never while typing |
| Model | `claude-sonnet-5` | `claude-haiku-4-5` |
| Built by | `OrganizeRequestBuilder` | `AnswerExtractor` |
| Output cap | `max_tokens: 4096` | `max_tokens: 512` |

Token counts below are **`bytes / 4`** on the exact JSON the builders emit,
measured on the committed fixtures in `Tests/Fixtures/ai-recordings/`. Four
bytes per token is the same crude over-estimate `OrganizeContextBuilder` uses
for its own budget (`bytesPerToken = 4`), which keeps this document and the
code that enforces the budget on one scale. It over-counts code and
punctuation-heavy text, so these are ceilings rather than best guesses.

The `usage` blocks inside the fixtures are **hand-authored**, not billed
figures — this machine has no API key (`docs/prompts.md` §4). Recompute this
document from real `usage` the first time the fixtures are recorded live.

### 1.1 `organize.v1`, part by part

Measured on `organize/122cfeeded98ffbb.json`, the largest committed request:

| Part | Bytes | ≈ tokens | Varies with |
|---|--:|--:|---|
| `system` (`organize.v1` + `plan-format.v1`, rendered) | 5,355 | **1,339** | never |
| `tools` (`organization_plan` strict schema) | 7,892 | **1,973** | never |
| `messages` (the session context) | 1,533 | 383 | the library and the session |
| framing (`model`, `max_tokens`, `thinking`, `tool_choice`, `output_config`) | ~105 | ~25 | never |
| **total (this fixture)** | **14,997** | **3,749** | |

**3,337 of those tokens are constant on every single session.** The schema is
the larger half of it, and it is the same 1,973 tokens whether the session
moved one line or rewrote a folder.

The variable half is bounded: `OrganizeContextBuilder.tokenBudget` is **6,000**
estimated tokens, and over budget the builder sheds candidate previews, then
candidates, then the library note list, then truncates session bodies *around*
the delta. So the input cannot run away:

| | context tokens | request tokens |
|---|--:|--:|
| Fixture-shaped session (two short notes, tiny tree) | 383 | 3,749 |
| **Typical session** (one ~1.5 KB delta, ~60-note tree, 6 candidates × 20 preview lines) | ~2,500 | **~5,800** |
| Budget ceiling | 6,000 | **~9,300** |

Output is a plan — 100–250 tokens of tool-call JSON in the committed
fixtures — plus adaptive thinking, which is billed as output. Assume **~600
tokens** typical and the 4,096 cap as the ceiling.

### 1.2 `answer.v1`, part by part

Measured on `search/927d285cf367bb5a.json`:

| Part | Bytes | ≈ tokens | Varies with |
|---|--:|--:|---|
| `system` (`answer.v1`) | 2,550 | **638** | never |
| `tools` (`answer_selection`) | 1,204 | **301** | never |
| `messages` (the ranked chunks + the question) | 1,144 | 286 | the number and size of chunks |
| framing | ~60 | ~15 | never |
| **total (this fixture)** | **5,044** | **1,261** | |

The fixtures carry a handful of chunks; production sends
`SemanticResults.promptChunkLimit` = **20** (M3-07 raised it from 8 and bought
+25 points of answer accuracy — ADR-047, so this is not a knob to turn back for
cost without re-measuring). Chunks average **428 bytes** of text across both
the 5,000- and 20,000-note scale corpora — 107 tokens — plus ~25 tokens each of
framing (ordinal, title, folder, heading breadcrumb):

| | chunk tokens | request tokens |
|---|--:|--:|
| Fixture-shaped | 286 | 1,261 |
| **Typical Ask search** (20 chunks × ~132 tokens) | ~2,640 | **~3,600** |

Output is 60–150 tokens: a chunk id, an optional trimmed snippet, a ranked id
list. `AnswerRequest` sends **no thinking for Haiku**, so there is no hidden
output. Assume **~120 tokens**.

---

## 2. Per call

| | input tok | output tok | input $ | output $ | **per call** |
|---|--:|--:|--:|--:|--:|
| Organize, fixture-shaped (Sonnet 5) | 3,749 | 200 | $0.0112 | $0.0030 | **$0.014** |
| **Organize, typical (Sonnet 5)** | 5,800 | 600 | $0.0174 | $0.0090 | **$0.026** |
| Organize, worst case (Sonnet 5, budget + cap) | 9,300 | 4,096 | $0.0279 | $0.0614 | **$0.089** |
| Organize, typical (**Opus 5** override) | 5,800 | 600 | $0.0290 | $0.0150 | **$0.044** |
| Answer, fixture-shaped (Haiku 4.5) | 1,261 | 96 | $0.0013 | $0.0005 | **$0.002** |
| **Answer, typical (Haiku 4.5)** | 3,600 | 120 | $0.0036 | $0.0006 | **$0.004** |
| Answer, worst case (Haiku 4.5, 512 cap) | 4,500 | 512 | $0.0045 | $0.0026 | **$0.007** |

Two and a half cents to file a writing session; four tenths of a cent to ask a
question.

---

## 3. A month

The day plan §3 M4-11 uses for the dogfood week: **15 sessions + 30 searches**.
That is a heavy day — a session is "typed something, then went away for three
minutes" (FR-3.1's default idle interval), so fifteen of them is most of a
working day spent writing.

| Scenario | Organize | Answer | **Day** | **30 days** | 22 working days |
|---|--:|--:|--:|--:|--:|
| Fixture-shaped floor | $0.21 | $0.05 | $0.26 | **$7.9** | $5.8 |
| **Typical (Sonnet 5)** | $0.40 | $0.13 | **$0.53** | **$15.7** | **$11.5** |
| Typical, Opus 5 override | $0.66 | $0.13 | $0.79 | **$23.6** | $17.3 |
| Worst case (budget + caps) | $1.34 | $0.21 | $1.55 | **$46.4** | $34.0 |

Typical monthly volume, for the Settings → AI counter to be sanity-checked
against (FR-6.6):

```
organize   450 requests   2.61 MTok in    0.27 MTok out
answer     900 requests   3.24 MTok in    0.11 MTok out
           ------------------------------------------
total    1,350 requests   5.85 MTok in    0.38 MTok out
```

Modes that cost nothing at all, and are worth saying out loud:

* **Keyword search is free and offline.** Typing in ⌘K never leaves the
  machine; only pressing ⏎ on an Ask query does (FR-5.5).
* **Semantic *retrieval* is free.** Embeddings are local Core ML; the 14 ms
  p50 hybrid ranking costs nothing. Only the answer *card* is billed.
* **A session that changed nothing sends nothing.** `Organizer` computes the
  effective delta first and skips the request entirely
  (`OrganizerTests`: "no effective delta → no request at all").
* **Dismissing or undoing costs nothing extra** — the plan was already paid for.
* **`Settings → AI → Off` and airplane mode cost nothing**, and capture,
  browsing and keyword search are unaffected (FR-6.4).

---

## 4. The lever nobody has pulled: prompt caching

`organize.v1` sends **3,337 identical tokens** on every session and
`answer.v1` sends **954** on every search. Over the typical month that is:

```
organize   3,337 × 450 = 1.50 MTok  of input that is byte-identical every time
answer       954 × 900 = 0.86 MTok
```

At Sonnet's $3/MTok and Haiku's $1/MTok that constant costs **$5.36 a month**,
a third of the whole bill. Cache reads are normally billed at a tenth of base
input, so caching it would leave about **$0.54** — **a saving of roughly $4.80
a month, ~30% of the total**, with no change to behaviour.

`AIUsage` already carries `cacheCreationInputTokens` and
`cacheReadInputTokens` and `AIUsageLedger` already stores both. Nothing sets
`cache_control`, because a cache write that is never read costs *more* than no
cache (writes are billed above base rate), and that trade cannot be verified
without a key. This is the first optimisation to make once one exists —
`docs/prompts.md` §4.5.

The second lever, if the bill ever matters more than the quality, is the
answer step's 20 prompt chunks. Do not touch it without re-running
`filaway-bench retrieval`: M3-07 measured that the answer is inside the top
eight chunks only 65% of the time and inside the top twenty 94%, and dropping
back to eight cost 25 points of answer accuracy to save a fifth of a cent per
search.

---

## 5. Does `AIUsageLedger` surface this?

Yes, and it is the right shape for it. `Sources/FilawayCore/AI/AIUsageLedger.swift`:

* **Every billed request is one row** — `timestamp`, `model`, `purpose`,
  `provider`, `input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`, `request_id`.
  The four token columns are exactly the four the Messages API returns, so
  when caching does land the ledger already distinguishes the three input
  prices.
* **`monthlyTotals(...)` and `monthlyTotalsByPurpose(...)`** are what
  FR-6.6's Settings → AI counter reads. The by-purpose split is what makes
  §3's table checkable against reality: the shipped app can say
  "organize 450 requests / 2.6 MTok, answer 900 / 3.2 MTok" and those are the
  two rows above.
* **`provider` defaults the totals to `"claude"`**, so replayed and mocked
  traffic — every test, every smoke phase — is excluded from the counter
  rather than inflating it. A dogfood week's ledger is therefore real money
  only.
* **Its own SQLite file** (`ai-usage.sqlite`, beside `filaway.sqlite`), so
  `Settings → Rebuild index` deleting the derived database does not delete the
  billing history.

**Two gaps.**

1. **The ledger stores tokens, not money.** There is no price table anywhere in
   the code, so Settings can show "2.6 MTok this month" but not "$0.40". A
   price map keyed by model id — the three rows at the top of this document —
   would let the AI pane show a currency figure, which is what FR-6.2's
   "balance cost and quality" actually asks the user to reason about. Deferred:
   prices change, and a stale hard-coded price is worse than no price.
2. **Nothing verifies the ledger against the API's own `usage` endpoint.**
   Plan §3 M4-02 says "tokens/requests/month from API `usage`"; what is
   implemented sums the per-response `usage` blocks, which is the same number
   only if no request is lost. A request that fails after the model produced
   output is billed and not recorded.

---

## 6. How to redo this

```bash
# request/response sizes, per fixture, by part
python3 - <<'EOF'
import json, glob, os
for d in ("organize", "search"):
    for f in sorted(glob.glob(f"Tests/Fixtures/ai-recordings/{d}/*.json")):
        j = json.load(open(f)); b = json.loads(j["requestBody"])
        parts = {k: len(json.dumps(v, ensure_ascii=False)) for k, v in b.items()}
        print(os.path.basename(f), j["model"], {k: v // 4 for k, v in parts.items()})
EOF

# average chunk size, which sets the answer request's variable half
sqlite3 <library>/filaway.sqlite "SELECT COUNT(*), AVG(LENGTH(text)) FROM chunks;"
```

Recompute from real `usage` blocks once the fixtures have been recorded live
(`docs/prompts.md` §5) — `bytes / 4` is deliberately pessimistic, so the real
bill should come in under every figure here.
