# P2 — the local provider, measured

**Task:** P2-04. **Spec:** FR-6.5, NFR-5 (plus FR-4.1, FR-4.4, FR-4.5, FR-5.2).
**Date:** 2026-08-24. **Machine:** M2 MacBook, 16 GB, macOS 26.1, Swift 6.0.3.
**Daemon:** Ollama 0.32.15 at `localhost:11434`, `llama3.1:8b` (8.0B, Q4_K_M,
131,072-token context).

Everything below is reproducible on a machine with the daemon up:

```bash
FILAWAY_TEST_OLLAMA=1 swift test --filter OllamaLiveGoldenTests   # § 1, § 2
make bench ARGS="ollama probe"                                    # § 3
make bench ARGS="retrieval --embedder bge --answer ollama"        # § 4
FILAWAY_SMOKE_OLLAMA=1 FILAWAY_SMOKE_ONLY="organize organize-auto organize-offline organize-ollama organize-ollama-suite" Tools/smoke.sh
```

**Task:** P2-09 added § 4a and § 4b — the live plan-quality suite and the
`folderTooDeep` repair (ADR-073).

Every table here is **content-free** (NFR-4): action kinds, validator issue
kinds, and numbers. No note text, no titles, no paths.

---

## 1. The finding: a plan the validator threw away

P2-03 left the gated `organize-ollama` smoke phase reaching the real model end
to end — provider, model tag and the 180 s budget all verified — and **failing
on plan quality**. The measurement is the nine organize goldens
(`OrganizeGoldenTests.scenarios`) plus the smoke corpus (`AppWiringFixture`),
run through the whole organizer against the daemon.

### 1.1 Before (baseline, `organize.v1` as frozen)

| scenario | usable | outcome | actions | validator errors | s | in | out |
|---|---|---|---|---|---|---|---|
| new-note | yes | proposed | moveSegment | — | 9.4 | 1656 | 118 |
| merge-code-block | **no** | failed | — | titleCollision, segmentNotFound | 14.1 | 1801 | 211 |
| retitle-untitled | **no** | failed | — | segmentNotFound | 13.3 | 1739 | 196 |
| new-folder | yes | proposed | moveSegment, appendToNote | — | 12.1 | 1727 | 179 |
| nothing-to-do | **no** | failed | — | titleCollision, segmentNotFound | 8.6 | 1639 | 121 |
| convergence | **no** | failed | — | unknownFolder | 9.0 | 1737 | 119 |
| excluded-folder | **no** | failed | — | titleCollision, segmentNotFound | 14.1 | 1801 | 211 |
| invalid-action-dropped | yes | proposed | moveSegment | — | 7.7 | 1635 | 113 |
| summary-no-longer-matches | yes | proposed | moveSegment | — | 8.3 | 1707 | 116 |
| **smoke corpus (ask)** | **no** | failed | — | titleCollision, segmentNotFound | 14.2 | 1801 | 211 |
| **smoke corpus (auto)** | **no** | failed | — | titleCollision, segmentNotFound | 14.8 | 1801 | 211 |

**usable: 4/9 goldens, 0/2 smoke.**

Two error kinds account for all of it, and neither is a *filing* mistake — the
model picks the right note and then says the wrong thing about it:

- `titleCollision` — `createNote` (or `moveSegment` into a new note) at a path
  the library already has. Rejected because it is the one way a plan could
  overwrite user text (FR-4.4).
- `segmentNotFound` — a `moveSegment` whose `segment` is not in the source byte
  for byte. On the smoke corpus the model dropped the ```` ```sh ```` fence and
  stitched two non-adjacent lines together.

`unknownFolder` (convergence) is a third, rarer one: the model used a *note's*
path with the extension stripped as a `folderPath`.

Note also what did **not** go wrong: every response was well-formed JSON against
the `format` schema, every plan decoded, and no request came back truncated. The
P2-01 wire work holds.

### 1.2 After the wire-time rules alone (ADR-070, part 1)

`OllamaWire.instructions(for:)` appends a five-line restatement of the rules the
model breaks. Prompt cost: **+200 tokens** (1,656 → 1,855 on the smallest
scenario).

| scenario | usable | outcome | actions | errors | warnings |
|---|---|---|---|---|---|
| new-note | yes | proposed | moveSegment | — | — |
| merge-code-block | no | failed | — | titleCollision, segmentNotFound | — |
| retitle-untitled | **yes** | proposed | retitleNote, moveSegment | — | — |
| new-folder | yes | proposed | moveSegment | — | unreadableAction |
| nothing-to-do | **yes** | proposed | appendToNote | — | — |
| convergence | no | failed | — | unknownFolder | — |
| excluded-folder | no | failed | — | titleCollision, segmentNotFound | — |
| invalid-action-dropped | yes | proposed | moveSegment | — | — |
| summary-no-longer-matches | no | failed | — | segmentNotFound | — |
| smoke corpus (ask/auto) | no | failed | — | titleCollision, segmentNotFound | — |

**usable: 5/9 goldens, 0/2 smoke.** Better, and not enough: the standard corpus
still loses its card, which is exactly what `organize-ollama` needs.

### 1.3 After the wire rules **and** `PlanRepair` (ADR-070, both parts)

| scenario | usable | outcome | actions | errors | warnings | s | in | out |
|---|---|---|---|---|---|---|---|---|
| new-note | yes | proposed | moveSegment | — | — | 9.5 | 1855 | 122 |
| merge-code-block | **yes** | proposed | appendToNote | — | repairedCollision, repairedMerge | 10.0 | 2000 | 128 |
| retitle-untitled | yes | proposed | retitleNote, moveSegment | — | — | 13.4 | 1938 | 186 |
| new-folder | yes | proposed | moveSegment | — | unreadableAction | 12.0 | 1926 | 165 |
| nothing-to-do | yes | proposed | appendToNote | — | — | 6.9 | 1838 | 87 |
| convergence | **no** | failed | — | unknownFolder | — | 9.4 | 1936 | 119 |
| excluded-folder | **yes** | proposed | appendToNote | — | repairedCollision, repairedMerge | 10.0 | 2000 | 128 |
| invalid-action-dropped | yes | proposed | moveSegment | — | — | 8.0 | 1834 | 113 |
| summary-no-longer-matches | **yes** | proposed | createNote | — | repairedMerge | 9.1 | 1906 | 123 |
| **smoke corpus (ask)** | **yes** | proposed | appendToNote | — | repairedCollision, repairedMerge | 10.1 | 2000 | 128 |
| **smoke corpus (auto)** | **yes** | applied | — | — | — | 10.6 | 2000 | 128 |

**usable: 8/9 goldens (was 4/9), 2/2 smoke (was 0/2).**

Summary of the movement:

| | goldens usable | smoke corpus |
|---|---|---|
| baseline | 4/9 | fails |
| + wire-time rules | 5/9 | fails |
| + `PlanRepair` | **8/9** | **passes, both modes** |

### 1.4 What is still failing, and why it is left

`convergence` — `unknownFolder`: the model names `Commands/curl` (a note's path,
extension stripped) as a `folderPath`. Repairing it would mean inferring "you
meant the note" from a folder string: a third rule with a worse ratio of
guesswork to benefit than the two that landed. Recorded in ADR-070 rather than
fixed. On Claude this scenario is a hand-authored golden and passes.

### 1.5 Latency and tokens, organize shape

Warm, whole-organizer wall clock (build the prompt → daemon → decode → repair →
validate): **6.9–13.4 s**, median ~10 s. Prompt 1,834–2,000 tokens, output
87–186. The budget is 180 s (ADR-069), and filing is never on a visible path.

---

## 2. The answer card (FR-5.2)

The five `AnswerGolden` scenarios, live, through `AnswerExtractor`'s own request
and `AnswerSelection.decode`:

| scenario | decoded | outcome | s | in | out |
|---|---|---|---|---|---|
| curl-code-card | yes | best=1 | 5.3 | 977 | 58 |
| temporal-auth | yes | best=2 | 5.9 | 863 | 81 |
| no-answer | yes | best=2 | 3.9 | 827 | 51 |
| trimmed-snippet | yes | best=1 | 4.1 | 861 | 51 |
| invented-snippet | yes | best=1 | 4.5 | 836 | 58 |

**5/5 decode.** Two notes:

- On the *first* (cold) run, `curl-code-card` hit the 8 s request budget and
  returned nothing; on a warm daemon it takes 5.3 s. The app's answer path is a
  **race** against the offline card at 5 s (ADR-054), so a cold local model
  loses it and the user gets the FR-5.5 card instead — a degradation, not a
  failure.
- `no-answer` is a negative scenario: Claude abstains (`best_chunk_id: null`)
  and `llama3.1:8b` picks chunk 2 instead. That is a quality difference, and it
  is reported here rather than gated (ADR-071).

---

## 3. `filaway-bench ollama probe`

Everything it sends is a committed recording's request replayed live, so these
are Filaway's own prompts, not a synthetic stand-in.

```
daemon:   http://localhost:11434
tags:     1 model(s) in 38 ms
          llama3.1:8b · 8.0B · Q4_K_M · ctx 131072

| shape    | load | s    | prompt tokens | output tokens | stop     |
|----------|------|------|---------------|---------------|----------|
| search   | cold | 12.8 | 977           | 58            | tool_use |
| search   | warm |  3.2 | 977           | 58            | tool_use |
| organize | cold | 22.3 | 2000          | 128           | tool_use |
| organize | warm |  7.3 | 2000          | 128           | tool_use |

context:  organize prompt 2000 tokens of 131072 (1.5%) — 129072 tokens of headroom
cost:     $0
```

**The cold load is the whole story**: 4× on the answer shape, 3× on organize.
That is what `keep_alive: "30m"` and the launch warm-up (ADR-069) exist for.
Context length is not a constraint at 1.5% of the window.

---

## 4. `filaway-bench retrieval --answer ollama`

Retrieval itself is offline and unchanged by the provider; what moves is the
**answer** column — which chunk the card points at.

| answer step | note top-1 | top-3 | MRR@10 | **answer top-1** | retrieval p50 | p95 |
|---|---|---|---|---|---|---|
| local heuristic (FR-5.5, the offline card) | 95% | 100% | 0.970 | **94%** | 13 ms | 18 ms |
| live `llama3.1:8b` | 95% | 100% | 0.970 | **78%** | 69 ms | 87 ms |

Per category, live:

| category | n | answer top-1 |
|---|---|---|
| command | 6 | 100% |
| paraphrase | 56 | 77% |
| temporal | 8 | 75% |
| typo | 7 | 71% |
| negative | 12 | rejected 100% |

```
answers:  84/89 answered, 4 abstained, 1 failed · p50 23.8s p95 29.6s · 288,115 in / 7,235 out tokens
          0 of 89 inside the app's 5 s race (NFR-1); the rest would show the offline card
```

**Two findings, and the second is the important one.**

1. **The local model is worse than the offline heuristic at picking the card**
   (78% vs 94%). That is not a failure of the wiring — retrieval is identical to
   the digit in all three columns that measure it — it is `llama3.1:8b` choosing
   a different chunk of the right note. The heuristic has an unfair advantage
   here: M4-07 tuned it on this very corpus ("prefer the winning *note's* code
   chunk", ADR-065), which is exactly the judgement an 8B model gets wrong.
2. **It is far too slow for ⌘K.** p50 **23.8 s** per call — 7× the probe's warm
   3.2 s in § 3, because these prompts are much bigger: 3,237 input tokens on
   average (eight real corpus chunks) against the fixture's 977. **Zero of 89
   calls** came back inside NFR-1's 5 s race.

So on this corpus the local answer step never reaches the user: `AnswerExtractor`
races it against `AnswerHeuristic` and the heuristic always wins. The card the
user actually sees is the 94% one. That is the designed degradation (ADR-054,
FR-5.5) working exactly as specified — but it means **FR-6.5's answer card is
"met warm, on short prompts" rather than "met"**, and it is the honest headline
of this section.

What would change it, in order of effect: a smaller model for search only
(`--answer-model llama3.2:3b`; Settings already has the field), fewer prompt
chunks, or a bigger machine. None of it is code Filaway is missing.

`--answer-timeout` defaults to 60 s here on purpose: the app's 5 s cut-off would
have measured a stopwatch instead of a model. The NFR-1 number is reported
separately, above, which is the only place it belongs.

---

## 4a. The live plan-quality suite (P2-09)

§ 1 measured nine hand-authored goldens over *one* library shape. Three
dogfooding sessions then failed in a row, each on a different validator error,
and **a person found every one of them** — because the shapes that broke were
shapes no golden had: a library with no folders at all, and a session that is a
list of prose lines rather than a code block with an obvious home.

`organize-ollama-suite` is the answer to that (ADR-073). One process, one
Application Support, **a fresh library per scenario**, three live generations:

| scenario | library | session | mode |
|---|---|---|---|
| `feedback-list` | ~8 notes at the root, **no folders** | a numbered list of short app-feedback lines | ask |
| `command-note` | the same folderless library | one OIDC/`curl` invocation plus a line of prose | auto |
| `existing-folders` | two folders, each with notes | a shell recipe whose home is one of them | auto |

Two consecutive full runs on a warm daemon, `llama3.1:8b`:

| scenario | outcome | action kinds | repair warnings | run 1 s | run 2 s |
|---|---|---|---|---|---|
| `feedback-list` | proposed → accepted → applied | `appendToNote` | — | 12.7 | 12.7 |
| `command-note` | applied (auto) | `createFolder`, `createNote`, `retitleNote` | — | 17.7 | 17.6 |
| `existing-folders` | applied (auto) | `createNote` | — | 13.9 | 13.7 |

`SMOKE result failures=0` both times, and the four replayed/live phases beside
it (`organize`, `organize-auto`, `organize-offline`, `organize-ollama`) stayed
at zero as well. End to end the phase is **~55 s** of model time plus three
library rebuilds; the watchdog is 700 s and the per-scenario budget 190 s.

What each scenario proves, beyond "a plan came back":

- bytes changed on disk (a content-free path → byte-count fingerprint of the
  whole library, plus the note count, so a *created* note counts as a change);
- the Activity log has the event, it names `llama3.1:8b`, and it has a diff;
- **Settings → Activity** shows the same event through `ActivityModel` — the
  object `ActivitySettingsView` renders — and shows an `organizeFailed` row when
  one is recorded (scripted through `ActivityLog.recordFailure`: a live model
  cannot be made to fail on demand).

And what it deliberately does **not** pin: the summary, the target note, the
folder, the action kinds. Those are the model's taste, and a suite that pins
them turns every model bump into a red build (ADR-071). The gate is the
*contract* — a usable outcome, and **a plan the validator rejects fails the
phase**, printing `OrganizeCoordinator.lastFailureIssueKinds` so the next repair
rule has a name.

Note what the table does not contain: no `repairedFolderDepth`, on either run.
The wire-time depth rule (§ 4b) is doing the work, and rule 5 is the net
underneath it — which is the intended split, and the reason the repair rules are
pinned by `PlanRepairTests` rather than by this suite.

### 4b. The `folderTooDeep` repair, and the 9/9

The third live failure was
`folderTooDeep: Home/Projects/…/Skills/… is 5 levels deep; the cap is 2`.
`PlanRepair` rule 5 clamps such a path to its **last** `PathRules.maxFolderDepth`
components — the deepest components carry the model's classification, the
leading ones are invented scaffolding — and rule 4 then inserts the
`createFolder` the clamped folder needs. `OllamaWire.smallModelRules` gained the
matching line, which is part of the wire body, so the nine committed Ollama
organize fixtures were re-recorded.

Re-measuring § 1.3 with both in place:

| scenario | usable | outcome | actions | warnings | s | in | out |
|---|---|---|---|---|---|---|---|
| new-note | yes | proposed | moveSegment | — | 13.1 | 1970 | 120 |
| merge-code-block | yes | proposed | appendToNote | repairedCollision, repairedMerge | 10.0 | 2115 | 128 |
| retitle-untitled | yes | proposed | createNote | repairedMerge | 10.6 | 2053 | 139 |
| new-folder | yes | proposed | createNote, tagNote | repairedMerge | 12.6 | 2041 | 176 |
| nothing-to-do | yes | proposed | appendToNote | repairedCollision, repairedMerge | 8.4 | 1953 | 111 |
| **convergence** | **yes** | proposed | moveSegment | — | 9.5 | 2051 | 120 |
| excluded-folder | yes | proposed | appendToNote | repairedCollision, repairedMerge | 10.0 | 2115 | 128 |
| invalid-action-dropped | yes | proposed | moveSegment | — | 8.1 | 1949 | 114 |
| summary-no-longer-matches | yes | proposed | createNote | repairedMerge | 8.7 | 2021 | 115 |
| smoke corpus (ask) | yes | proposed | appendToNote | repairedCollision, repairedMerge | 10.1 | 2115 | 128 |
| smoke corpus (auto) | yes | applied | — | — | 10.5 | 2115 | 128 |

**usable: 9/9 goldens (was 8/9), 2/2 smoke.** `convergence` — ADR-070's one
deliberately-unrepaired case, where the model used a note's path as a
`folderPath` — now comes back correct on its own. The depth line cost ~115
prompt tokens (1,855 → 1,970 on the smallest scenario) and nothing regressed.

| | goldens usable | smoke corpus |
|---|---|---|
| baseline (§ 1.1) | 4/9 | fails |
| + wire-time rules (§ 1.2) | 5/9 | fails |
| + `PlanRepair` rules 1–3 (§ 1.3) | 8/9 | passes |
| + rules 4–5 and the depth line (P2-08/09) | **9/9** | **passes** |

---

## 5. The smoke phases

```
FILAWAY_SMOKE_ONLY="organize organize-auto organize-offline organize-ollama" \
FILAWAY_SMOKE_OLLAMA=1 Tools/smoke.sh
```

| phase | provider | result |
|---|---|---|
| `organize` | replay (Claude fixture) | **failures=0** |
| `organize-auto` | replay (Claude fixture) | **failures=0** |
| `organize-offline` | mock network failure | **failures=0** |
| `organize-ollama` | **live `llama3.1:8b`** | **failures=0** |
| `organize-ollama-suite` | **live `llama3.1:8b`**, three libraries | **failures=0** (§ 4a) |

`SMOKE result failures=0`. The three replayed phases are unchanged by any of
this — the repair is off for Claude, and the wire addendum is Ollama-only — and
the live phase, which P2-03 left failing, now walks the whole rope:

```
SMOKE ok   provider-is-the-local-daemon — ollama
SMOKE ok   model-is-the-local-tag — llama3.1:8b
SMOKE ok   organize-budget-is-the-local-one — 180.0s
SMOKE ok   live-card-appeared — 0s
SMOKE ok   live-card-has-a-summary — Code block merged into Commands / curl.
SMOKE ok   live-plan-has-an-action — 1 actions
SMOKE ok   live-accept-moved-bytes
SMOKE ok   live-activity-has-the-event — 1 events
SMOKE ok   live-activity-names-the-model — llama3.1:8b
```

### A bug the subset run found in `Tools/smoke.sh`

`run_phase` read `$ai_mode` / `$ai_provider` but only *assigned* them in the
`organize-ollama` branch. Under `set -u` that is a fatal expansion error in the
launch command — which runs in a subshell (the `> >(tee …)` process
substitution), so the subshell died, ran the inherited `EXIT` trap, and
**deleted the whole work directory** out from under every later phase. Every
phase before `organize-ollama` failed, and the cause looked like a locked
screen. Fixed by declaring the defaults (`replay`, no provider). The same run
also showed `run_kill_phase` ignoring `FILAWAY_SMOKE_ONLY`, since it has its own
runner; it now honours it.

> The run prints `smoke: WARNING — the screen is locked` on this machine even
> when it is not. The `ioreg` probe is a heuristic; the window arrives
> (`SMOKE window title="Filaway" visible=true size=1000x680`) and every phase
> passes, which is the real signal.

---

## 6. Definition of done

| Clause | Where | Verdict |
|---|---|---|
| **FR-6.5** "optionally use a local model instead of a cloud API" | `OllamaProvider`, Settings → AI, onboarding Figure 3 | **met** — selectable, keyless, and both AI features work on it |
| FR-6.5, filing works locally | § 1.3, `organize-ollama` smoke phase | **met** — 8/9 goldens, the standard corpus proposes and applies |
| FR-6.5, the answer card works locally | § 2, § 4 | **partial** — the pipeline is correct (5/5 goldens decode, 78% top-1 over 89 queries), but at p50 23.8 s on a full-size prompt it loses NFR-1's 5 s race every time and the offline card (94%) is what the user sees. Degradation by design (ADR-054), not breakage — see § 4 |
| **NFR-5** "user data never leaves the machine without consent" | ADR-066's loopback rule, `AIUsageLedger`, the FR-4.5 grep over local recordings | **met** — `http` only to loopback, no key, no telemetry, $0 |
| FR-4.4 "never delete or overwrite user text" | `PlanRepair` is additive-only; `neverDeletesUserText` exhaustive; 600 generated plans | **met** |
| FR-4.5 excluded folders | `GoldenPipelineTests.exclusionsNeverRecordedLocally` | **met** — greps all 14 committed local request bodies |
| FR-4.3 the user is told what happened | `repairedCollision` / `repairedMerge` warnings on the card and the Activity row | **met** |
| `make test` stays offline | every live suite is gated on `FILAWAY_TEST_OLLAMA=1` | **met** |

### Open

- ~~`convergence`'s `unknownFolder` (§ 1.4)~~ — closed by the depth line in
  § 4b; the scenario now returns a correct plan with no repair at all.
- **Plan quality is measured, not gated per scenario.** `organize-ollama-suite`
  gates the *contract* over three library shapes; a fourth shape nobody has
  written down is still a fourth live failure waiting to happen. Adding one is a
  `Scenario` value in `OrganizeSuiteSmokeCheck`.
- **The answer card never wins the 5 s race on a real ⌘K prompt** (§ 4): p50
  23.8 s at ~3,200 input tokens, 0 of 89 inside the budget, even warm. The user
  gets the offline card, which scores better anyway on this corpus. Worth
  another pass with a 3B model for search only, or with fewer prompt chunks;
  both are settings, not code.
- Only one model has been measured. `llama3.2:3b` and a 13–14B model are worth a
  pass; the harness takes `--model` / `--answer-model` and the tables above are
  the format to append to.
