# Prompts — versioning, the freeze, and what a live run still has to prove

**Task:** plan §3 M4-09 (spec §9 prompt versioning). **Date:** 2026-08-23.

`organize.v1` and `answer.v1` are **frozen**. Every golden and replay suite
passes against them, and the retrieval benchmark has been re-run since the last
prompt edit. What has *never* happened is a single call to the real API: this
machine has no `ANTHROPIC_API_KEY`, so every response in
`Tests/Fixtures/ai-recordings/` is hand-authored. The requests are not — they
are captured from the real builders — but the assumptions in §4 below are
untested against Anthropic's servers and are the first thing to check when a
key exists.

---

## 1. What exists

| Prompt | File | Model | Tool | Built by |
|---|---|---|---|---|
| `organize.v1` | `Sources/FilawayCore/AI/Prompts/organize.v1.txt` (3.6 KB) | `claude-sonnet-5` (`claude-opus-5` as the Advanced override) | `organization_plan`, `strict: true` | `Organize/OrganizeRequestBuilder.swift` |
| `plan-format.v1` | `…/plan-format.v1.txt` (1.6 KB) | — | — | included into `organize.v1` by `{{include:plan-format.v1}}` |
| `answer.v1` | `…/answer.v1.txt` (2.5 KB) | `claude-haiku-4-5` | `answer_selection`, `strict: true` | `Search/AnswerExtractor.swift` |

They are SwiftPM resources of `FilawayCore` (`Package.swift`,
`.copy("AI/Prompts")`), loaded by `PromptLibrary`, and each is identified by a
`PromptVersion` — `"organize.v1"` parses to `(id: "organize", version: 1)`.
`plan-format.v1` is a separate version on purpose: it mirrors
`OrganizationPlan.toolSchema`, so a schema change bumps *it* and the prompt that
includes it, and the include mechanism keeps the two from drifting.

Every activity event records the `promptVersion` that produced it
(`ActivityLog`, FR-4.3), so a plan applied last month can be traced to the
wording that produced it even after a bump.

---

## 2. The versioning rule

**A prompt file is immutable once a fixture has been recorded against it.**
Whitespace included: the replay key is a hash of the whole rendered prompt
(ADR-035), so a single changed character is a new key and every fixture misses.
That is the mechanism, not a side effect — it is what makes "the prompt changed"
impossible to do by accident.

To change a prompt:

1. **Bump the version.** Copy `organize.v1.txt` to `organize.v2.txt`, edit
   *that*, and change `PromptVersion.organize` to `version: 2`. Leave `v1` on
   disk: activity events from before the bump still name it, and
   `PromptLibrary` must be able to load it.
2. **Re-record the fixtures.** With a key:
   ```
   FILAWAY_AI_MODE=record swift test --filter "Organize goldens"
   FILAWAY_AI_MODE=record swift test --filter "Answer goldens"
   ```
   Without one (this machine, today), hand-author them:
   ```
   FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "Organize goldens"
   FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "Answer goldens"
   FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter OrganizeWiringTests/regenerateFixture
   ```
   The last one matters and is easy to forget: `OrganizeSmokeCheck` and
   `AppWiringFixture` share a corpus, and `wiringHitsTheCommittedFixture` pins
   the key so drift is a test failure rather than a mystery smoke failure.
3. **The goldens must pass.** Not "pass after adjusting the expectations" —
   the scenarios in `OrganizeGoldenTests.scenarios` are the contract
   (`new-note`, `merge-code-block`, `retitle-untitled`, `new-folder`,
   `nothing-to-do`, `convergence`, `excluded-folder`, `invalid-action-dropped`,
   `summary-no-longer-matches`), and a prompt that stops satisfying one of them
   is a regression regardless of how much better it reads.
4. **Re-run the retrieval benchmark** and paste the numbers into
   `docs/verification/M3-retrieval.md`:
   ```
   swift run -c release filaway-bench retrieval --embedder bge --failures
   ```
   A prompt bump can only move the *answer* columns — retrieval is offline —
   but the answer column is half of spec §8.
5. **Re-run the smoke phases that replay a fixture**: `organize`,
   `organize-auto`, `organize-offline` (`make smoke`).
6. **Record the bump in `docs/decisions.md`**, with what moved and by how much.

`AIPurpose` decides which model and budget a prompt runs under; the prompt file
never names a model.

---

## 3. The freeze run (2026-08-23)

Everything below was run on this machine at the freeze, in replay mode, on the
committed fixtures.

| Suite | Command | Result |
|---|---|---|
| Whole test suite | `make test` | **734 passed**, 0 failed |
| Organize goldens (9 scenarios) | `swift test --filter "Organize goldens"` | pass |
| Answer goldens (5 scenarios) | `swift test --filter "Answer goldens"` | pass |
| App wiring / replay e2e | `swift test --filter OrganizeWiringTests` | pass |
| Provider + harness | `swift test --filter AIProviderTests`, `AIHarnessTests` | pass |
| Retrieval gate (real bge-small over 302 notes) | in `swift test`, `RetrievalGateTests` | pass — note top-1 **95%**, answer top-1 **94%**, MRR **0.970** |
| Retrieval benchmark | `filaway-bench retrieval --embedder bge --failures` | pass, gate met |
| Exclusion leak check over every committed fixture | `AIHarnessTests.exclusionsNeverRecorded` | pass |

The retrieval numbers are higher than M3-07's because M4-07's typo repair
landed in the same milestone, not because a prompt changed. See
`docs/verification/M4-perf.md` § "Typos".

Fixture inventory at the freeze:

```
Tests/Fixtures/ai-recordings/organize/   13 files   claude-sonnet-5
Tests/Fixtures/ai-recordings/search/      5 files   claude-haiku-4-5
Tests/Fixtures/ai-recordings/validate/    1 file    GET /v1/models
```

`merge-code-block` and `excluded-folder` deliberately **share** one fixture:
the second scenario's assertion is that adding an excluded note leaves the
request byte-identical, so a shared key is the proof.

---

## 4. What only a live run can settle

Each of these is an assumption the code makes about the Messages API that no
test on this machine can falsify. They are ordered by how much would have to
change if the assumption is wrong.

### 4.1 Strict tool use accepts a discriminated `anyOf` (ADR-017)

`organization_plan`'s schema is an `anyOf` of seven closed objects, each
pinning `action` to a one-value `enum`, with `required` listing only the
genuinely required fields.

* **If wrong:** the first live organize call returns 400.
* **Fix:** flatten `PlanSchema.swift` to one object with nullable fields.
  Nothing above the schema changes — `PlanDecoder` already tolerates unknown
  and unreadable actions.
* **How to check:** one live organize call. `AIProviderTests` proves a 400 maps
  to `.badRequest` and is not retried, so the failure will be legible.

### 4.2 Strict tool use accepts `"type": ["integer", "null"]`

`answer_selection.best_chunk_id` is `["integer", "null"]`
(`Search/AnswerSelection.swift:47`) because "none of these answers it" has to be
a first-class tool output — `docs/verification/M3-retrieval.md` §4 shows why a
cosine floor cannot do that job (the answerable and unanswerable distributions
overlap; the floor that rejects 100% of negatives also suppresses a third of
real answers).

* **If wrong:** the first live answer call returns 400, and the search falls
  back to the local heuristic — a degradation, not an outage (FR-5.5).
* **Fix:** an `answered: boolean` discriminator plus a non-nullable
  `best_chunk_id`, and one branch in `AnswerSelection`'s decoder.

### 4.3 `thinking: {"type": "adaptive"}` + `output_config.effort` + a forced tool

`ClaudeWire` sends adaptive thinking and an effort level, *and*
`tool_choice: {"type": "tool", "name": …}`. Some APIs refuse to force a tool
while thinking is on.

* **If wrong:** 400, or the model returns a `thinking` block and no `tool_use`.
  `AnswerExtractor` already treats "no tool call" as a degradation rather than
  a crash, so search survives it; organize would queue the session.
* **Fix:** drop `thinking` for the forced-tool calls, or move to
  `tool_choice: auto` plus a retry. `ClaudeWire` already drops both fields for
  models that do not declare support (`AIModel.supportsEffort`).
* **Watch also:** whether thinking tokens are billed as output. §`docs/cost.md`
  assumes they are, which is the conservative reading.

### 4.4 Haiku 4.5 answers inside the 5 s budget

`AnswerExtractor` gives the answer step 5 s (NFR-1) and falls back to the local
heuristic on timeout. The whole offline half of a semantic query costs 14 ms at
p50 (`docs/verification/M4-perf.md`), so essentially the entire budget belongs
to this call — but no measurement of it exists.

* **How to check:** `filaway-bench retrieval --answer replay` measures the
  pipeline with a recorded answer step; a live variant needs a key.
* **If it overruns:** the user sees the ranked list with a local answer card,
  which is the FR-5.5 experience. The lever is `promptChunkLimit` (20 today),
  which is also the thing M3-07 raised from 8 to buy +25 points of answer
  accuracy — so trade it away only against a measurement.

### 4.5 Prompt caching is not used, and probably should be

`AIUsage` already carries `cacheCreationInputTokens` and
`cacheReadInputTokens`, and the ledger stores both, but nothing sets
`cache_control`. `organize.v1`'s system block plus the tool schema is a
**constant 3,337 tokens on every session** (§`docs/cost.md`), which is exactly
the shape prompt caching exists for.

* **Not done because** it cannot be verified without a key, and a cache-write
  that never gets read costs more than no cache at all.
* **First thing to measure live**, and the single biggest cost lever available.

### 4.6 The model IDs resolve

`claude-sonnet-5`, `claude-haiku-4-5`, `claude-opus-5`. `AIProviderTests` proves
a 404 maps to `.modelNotFound` and names the model; `AIConnectionManager` fetches
the live list from `GET /v1/models` (FR-6.1, amendment 4), and
`Tests/Fixtures/ai-recordings/validate/models-list.json` is a *hand-authored*
stand-in for that list.

### 4.7 A live pass over the eight golden scenarios (M2 DoD)

M2's Definition of Done asks for the goldens to pass "with replay (automated)
**and** live (manual, one pass with a real key)". The replay half is done; the
live half has never run. It is the same command as §2 step 2 with
`FILAWAY_AI_MODE=live`, and it is tracked as the outstanding M2 item in
`docs/verification/M2.md`.

---

## 5. Re-recording with a real key

```bash
export ANTHROPIC_API_KEY=sk-ant-…          # or Keychain, via Settings → AI
FILAWAY_AI_MODE=record swift test --filter "Organize goldens"
FILAWAY_AI_MODE=record swift test --filter "Answer goldens"
git diff --stat Tests/Fixtures/ai-recordings/    # read every changed response
swift test                                        # replay must now be green
swift run -c release filaway-bench retrieval --embedder bge --failures
make smoke                                        # organize* phases replay
```

Three things to check by eye in the diff, because no assertion covers them:

1. **No note content from an excluded folder** anywhere in a request.
   `AIHarnessTests.exclusionsNeverRecorded` scans every committed fixture for
   the sentinel strings, but only a human notices a *new* kind of leak.
2. **`usage` becomes real.** The committed fixtures carry hand-authored usage
   blocks (organize: 2 400 in / 180 out; answer: 1 190 in / 96 out). Once
   recorded these are the API's own numbers, and `docs/cost.md` should be
   recomputed from them rather than from `chars / 4`.
3. **`thinking` blocks appear in the responses** if adaptive thinking is on.
   The hand-authored fixtures have none, so the first live recording is also
   the first evidence that §4.3 holds.

`record` writes into `Tests/Fixtures/ai-recordings/<purpose>/<key>.json` and
never deletes; a bump leaves the old files behind, and removing them is a
deliberate second step once nothing replays them.

---

## 6. Known gaps

* **No live call has ever been made** — §4 in its entirety.
* **`filaway-bench prompts --live`**, named in plan §1 and §2.7, was never
  built. Re-recording goes through `swift test` with `FILAWAY_AI_MODE=record`,
  which is what §5 documents; the plan's line is stale.
* **`organize.v2` has no reason to exist yet**, which is the point of a freeze,
  but it also means the bump path in §2 is untested end to end.
* **Prompt caching is unimplemented** (§4.5).
