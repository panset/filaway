# FilawayCore AI layer — provider, harness, plans

What M2-01, M2-02 and M2-04 landed: the Claude provider, the record/replay test
harness, and the organization-plan model with its validator. Everything is in
`FilawayCore` (Swift 6, no AppKit/SwiftUI). Requirement IDs refer to
`docs/spec/functional-spec.html`.

Nothing here needs an API key to build, test or reason about. `replay` is the
default mode, the whole error taxonomy is covered by a `URLProtocol` stub, and
the fixtures are committed.

---

## The shape of it

| Type | Kind | Owns |
|---|---|---|
| `AIProvider` | protocol | One request in, one response out (NFR-5, FR-6.5). |
| `ClaudeProvider` | struct | The raw Messages API over `URLSession`. |
| `ReplayProvider` / `RecordingProvider` / `MockProvider` | structs | The test harness. |
| `KeychainStore` behind `SecretStore` | struct | The API key (FR-6.1, NFR-4). |
| `AIUsageLedger` | actor | Monthly tokens and requests (FR-6.6). |
| `AIHealth` → `AIStatus` | value types | The toolbar pill (FR-6.4). |
| `OrganizationPlan` + `PlanValidator` | value types | FR-4.1's closed action set. |
| `ExclusionFilter` | struct | FR-4.5, applied *before* any prompt is built. |

```swift
let provider = ClaudeProvider(keySource: .storeThenEnvironment(KeychainStore()))
let models = try await provider.validateKey()            // GET /v1/models — free
let response = try await provider.complete(request)      // POST /v1/messages
```

---

## `AIProvider`

```swift
protocol AIProvider: Sendable {
    var identifier: String { get }                        // "claude", "replay", "mock"
    func complete(_ request: AIRequest) async throws -> AIResponse
    func validateKey() async throws -> [AIModelInfo]
}
```

Every failure is an `AIError` — never a raw `URLError`, never a `DecodingError`.

### `AIRequest`

```swift
AIRequest(
    model: .defaultOrganize,          // AIModel — a parameter of every request
    purpose: .organize,               // ledger bucket, fixture folder, default timeout
    system: promptText,
    messages: [.user(context)],       // text only in Phase 1
    tools: [OrganizationPlan.tool],
    toolChoice: .tool(name: OrganizationPlan.toolName),
    maxTokens: 4096,
    thinking: .adaptive(),            // dropped for models that reject it
    effort: .medium,
    timeout: 60
)
```

Model identifiers carry **no date suffix** (plan §1 amendment 5). Defaults:

| Job | Model | Why |
|---|---|---|
| Organization plans | `claude-sonnet-5` | cost/quality balance (FR-6.2) |
| Advanced override | `claude-opus-5` | Settings → AI |
| Search answer extraction | `claude-haiku-4-5` | keeps the card under 5 s (NFR-1) |

`AIModel.supportsAdaptiveThinking` is what makes a house default safe: Haiku 4.5
is on the pre-4.6 `budget_tokens` contract, which Filaway never sends, so
`thinking` and `output_config` are simply omitted for it.

### Wire format

`ClaudeWire.body(for:)` produces exactly:

```json
{
  "model": "claude-sonnet-5",
  "max_tokens": 4096,
  "system": "…",
  "messages": [{"role": "user", "content": [{"type": "text", "text": "…"}]}],
  "tools": [{"name": "organization_plan", "description": "…",
             "strict": true, "input_schema": { "additionalProperties": false, … }}],
  "tool_choice": {"type": "tool", "name": "organization_plan"},
  "thinking": {"type": "adaptive"},
  "output_config": {"effort": "medium"}
}
```

Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type:
application/json`. Three things are deliberately absent and asserted absent by
`ClaudeRequestEncodingTests`: an assistant **prefill** (a 400 on current
models), `thinking.budget_tokens` (removed), and sampling parameters (removed).

### `AIResponse`

```swift
response.text                                  // joined text blocks
response.toolUse(named: "organization_plan")   // (id, name, input: JSONValue)
response.stopReason                            // .endTurn .toolUse .maxTokens .refusal .other(…)
response.stopDetails?.category                 // only ever set on a refusal
response.usage                                 // input/output + both cache counters
response.requestID                             // the `request-id` header
```

`stop_reason` is checked before content everywhere: a refusal and a `max_tokens`
truncation both mean "there is no usable plan here", and `PlanDecoder` throws
rather than applying half of one. Tool input is always **parsed** — current
models vary their JSON escaping inside `input`, so string-matching it is a bug
waiting to happen.

### Errors, retries, timeouts

| HTTP / condition | `AIError` | Retried? |
|---|---|---|
| 401, 403 | `.invalidKey` | no |
| 404 | `.modelNotFound` | no |
| 400, 413 | `.badRequest` | no |
| 429 | `.rateLimited(retryAfter:)` | yes |
| 500…, 529 | `.serverOverloaded` | yes |
| `URLError` | `.network` / `.timedOut` / `.cancelled` | yes (not cancelled) |
| undecodable body | `.malformedResponse` | no |
| no key at all | `.notConfigured` | no |

`RetryPolicy` is exponential with half jitter, 3 attempts, capped at 30 s, and a
server `retry-after` always wins. The clock is injected (`AIClock`), so the
backoff tests assert the delays instead of waiting them out. Default timeouts
come from `AIPurpose`: 60 s for plans, 8 s for search, 15 s for validation.

`AIHealth` folds outcomes into `AIStatus` for the pill — `connected`,
`notConfigured`, `invalidKey`, `offline`, `rateLimited(until:)`, `error(String)`
— and a rate limit heals itself once its deadline passes. `AIStatus.label` is
content-free by construction.

### Privacy (NFR-4)

* Prompts and note text are **never** logged, at any level. `Log.ai` sees the
  model id, the purpose, byte counts, token counts and the stop reason.
* The session is `.ephemeral` with no URL cache and no cookie storage, so the
  URL loading system never writes a prompt to disk.
* TLS only: a non-`https` base URL is a precondition failure, and the session
  floor is TLS 1.2.
* The key is resolved per request through `APIKeySource` and never held in a
  long-lived property.

### The key

```swift
protocol SecretStore: Sendable { … }                     // get / set / delete
KeychainStore(service: "com.tejaspanse.filaway")         // kSecClassGenericPassword
//   account "anthropic-api-key", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
InMemorySecretStore(apiKey: "sk-ant-…")                  // tests, previews, bench
```

`KeychainStore` is only ever reached through the protocol: a Keychain query from
an unsigned `swift test` binary can prompt or fail outright, so its own test is
gated on `FILAWAY_TEST_KEYCHAIN=1` and uses a throwaway service name.

Resolution order in the app is `APIKeySource.storeThenEnvironment(KeychainStore())`
— Keychain first, then `$ANTHROPIC_API_KEY`, which is what makes `record` and
`live` modes work for a developer who has not been through onboarding.

### Usage (FR-6.6)

```swift
let ledger = try AIUsageLedger(library: library)          // <support>/ai-usage.sqlite
try await ledger.record(response: response, purpose: .organize)
let month = try await ledger.monthlyTotals()              // requests + tokens
let split = try await ledger.monthlyTotalsByPurpose()     // organize vs search
```

Its own database file, not a `MetadataStore` migration — see ADR-013. Replayed
and mocked calls are recorded with a non-`claude` `provider` and excluded from
billed totals, so a test run cannot inflate the counter.

---

## The record/replay harness (M2-02)

```
FILAWAY_AI_MODE = replay   (default — tests and CI, no network, no key)
                | record   (real API + write fixtures; needs ANTHROPIC_API_KEY)
                | live     (real API, record nothing)
```

```swift
let provider = try AIProviderFactory.make(
    mode: AIMode.current(),
    store: AIRecordingStore(directory: fixturesURL),
    keySource: .storeThenEnvironment(KeychainStore())
)
```

### Fixture format

`Tests/Fixtures/ai-recordings/<purpose>/<key>.json`, where `<key>` is a 16-hex
digest of the canonicalised request: **model, system, messages, tools,
toolChoice**, encoded with sorted keys. Token caps, thinking depth, effort and
timeouts are excluded — they are execution knobs, not part of what was asked.

```json
{
  "version": 1,
  "purpose": "organize",
  "key": "87da92a3c20ef72a",
  "model": "claude-sonnet-5",
  "recordedAt": "2026-08-22T21:00:00Z",
  "note": "hand-authored (M2-02) — organize: a valid plan",
  "request":     { …the decoded AIRequest, for reading and diffing… },
  "requestBody": { …the exact JSON that was POSTed… },
  "responseBody":{ …the exact JSON the API returned… }
}
```

Storing **wire** bodies is the point: a hand-authored fixture goes through the
same `ClaudeWire.response(from:)` a live call does, and the committed request
body is what the FR-4.5 exclusion test greps.

A miss in replay throws `AIError.missingRecording`, whose message names the file
and the command that would record it. It never falls through to the network.

### Committed fixtures

| File | Scenario |
|---|---|
| `validate/models-list.json` | key validation succeeds, three models |
| `organize/87da92a3c20ef72a.json` | a valid plan (moveSegment + retitleNote) |
| `organize/32ec1410dbe6c865.json` | a plan the validator must reject (depth 3, unknown id, unsafe title, paraphrased segment, an invented `deleteNote`) |
| `organize/4f70a56d54dd90e1.json` | nothing to do — an empty, valid plan |
| `organize/872b5453e4c26ce8.json` | `stop_reason: "refusal"` with `stop_details` |

Rate limiting is deliberately *not* a fixture: it is a transport behaviour, and
lives in the `URLProtocol` stub suite (429 + `retry-after`, 529 backoff, network
failure, non-JSON body) instead.

These are stand-ins written by hand, with a placeholder system prompt. M2-06
records real ones against `organize.v1`; when it does, the keys change and these
can go.

### Recording, once a key exists

```bash
export ANTHROPIC_API_KEY=sk-ant-…          # or put it in the Keychain
FILAWAY_AI_MODE=record swift test --filter "…"
git diff Tests/Fixtures/ai-recordings      # review what changed before committing
```

Recording costs money and is a manual job — CI never sets `FILAWAY_AI_MODE`.
To rewrite the hand-authored set (no key needed):

```bash
FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "regenerate"
```

---

## The organization plan (M2-04)

### The closed action set (FR-4.1)

```swift
enum PlanAction {
    case createNote(title, folderPath, content, tags)
    case appendToNote(target, content, heading?, divider?)
    case createFolder(path)
    case moveNote(note, toFolderPath)
    case retitleNote(note, newTitle)
    case tagNote(note, tags)                      // additive only
    case moveSegment(source, segment, segmentHash?, sourceRange?, destination, heading?, divider?)
}
```

**Nothing here can delete or overwrite user text, and that is a property of the
type** — there is no `deleteNote`, no `replaceContent`, no `setBody`.
`PlanAction.neverDeletesUserText` switches exhaustively over every case, so
adding a destructive one cannot compile without someone deciding it on purpose.

`moveSegment` is plan §1 amendment 1's "merge = move segment" (ADR-016): the
segment text travels **with the action**, byte-for-byte, so apply can verify it
still exists before touching anything.

A plan also carries what the model cannot be trusted to report:

```swift
plan.summary          // one plain sentence for the card
plan.promptVersion    // e.g. organize.v1 — recorded per Activity event
plan.model            // the model that produced it
plan.preconditions    // [NoteID: contentHash] — the M2-07 compare-and-swap
```

### The tool

```swift
OrganizationPlan.toolName    // "organization_plan"
OrganizationPlan.tool        // AITool, strict: true
OrganizationPlan.toolSchema  // generated by Organize/PlanSchema.swift
```

The schema is a discriminated `anyOf` of seven closed objects (ADR-017 — the one
thing here that cannot be verified without a key). It is generated rather than
hand-written, and a test lints the document and validates every encoded action
against it, so schema and codec cannot drift.

```swift
let decoding = try PlanDecoder.decode(response: response, context: context)
decoding.plan            // OrganizationPlan, preconditions attached from `context`
decoding.unknownActions  // actions that could not be read — reported, not fatal
```

One hallucinated action does not cost the user the good ones: unknown or
unreadable entries are collected and surfaced as validator warnings.

### `PlanValidator`

```swift
let context = OrganizeContext(snapshot: snapshot, excludedFolders: excluded, bodies: sessionBodies)
let result = PlanValidator(context: context).validate(plan, unknownActions: decoding.unknownActions)
result.isValid      // errors.isEmpty — an empty plan is valid ("nothing to do")
result.errors       // [PlanIssue] — kind, action index, content-free detail
result.warnings
```

Errors: unknown note or folder, contradictory or empty reference, depth > 2, a
target inside an excluded folder, an unsafe path (`..`, absolute, unsafe
component) or title, a create/retitle/move that would land on an existing note,
duplicate or contradictory actions, an empty append, a segment that is not in
the source verbatim, a segment-hash mismatch, a missing or stale precondition, an
empty tag, a runaway action count.

Warnings: nothing-to-do, an identical action twice, a no-op, a folder that
already exists, an unverified segment, an action the decoder dropped.

Collisions are judged against the library **as the plan leaves it**: the
validator projects each note's path forward through the plan, so a move followed
by a retitle cannot quietly land on an existing file.

### `ExclusionFilter` (FR-4.5)

```swift
let filter = ExclusionFilter(excludedFolders: ["Private", "Work/Confidential"])
filter.isExcluded(path: "Private/Salary.md")    // true
filter.isExcluded(path: "Private notes/ok.md")  // false — folder boundaries, not prefixes
filter.filter(snapshot)                          // notes and folders stripped
```

The gate is structural: `OrganizeContext(snapshot:excludedFolders:)` runs the
filter first, so an excluded note is never in the context a prompt is built
from — including its body map. The excluded folder *paths* stay, so a plan
targeting one is rejected as `.excludedTarget` rather than `.unknownFolder`.
`filter.leaks(in:bodies:notes:)` is the test-side belt and braces, run over every
committed fixture.

---

## Prompts

```swift
PromptVersion.organize          // organize.v1
try PromptLibrary.text(.planFormat)
```

Files live in `Sources/FilawayCore/AI/Prompts/` as `<id>.v<N>.txt` and are
SwiftPM resources of `FilawayCore` (ADR-014 — this is the package's only
`resources:` entry). `$FILAWAY_PROMPTS_DIR` or an explicit directory overrides
the bundle. `plan-format.v1.txt` ships now; M2-06 adds `organize.v1.txt` and
M3-05 `answer.v1.txt`, neither of which needs a `Package.swift` change.

---

## Testing

`Tests/FilawayCoreTests/AI*.swift` and `Organize*.swift` — 162 tests, all
offline, ~0.3 s.

* `AIProviderTests` — exact request JSON, response decoding (text, tool_use,
  refusal, max_tokens, unknown block types), the error taxonomy and retry
  behaviour against the `URLProtocol` stub with an injected clock, key
  validation.
* `AIHarnessTests` — mode selection, fixture integrity, record→replay round
  trip, the four organize scenarios, the FR-4.5 assertion over every fixture,
  the missing-fixture message.
* `AIStateTests` — secret stores, `AIStatus`/`AIHealth`, the usage ledger.
* `OrganizePlanTests` / `OrganizeValidatorTests` / `OrganizeExclusionTests` —
  codec and schema round trips, the validator matrix, property-style runs
  asserting that random unknown ids and over-deep folders never validate.

### What could not be verified without a key

1. That the API accepts the `anyOf` schema under `strict: true` (ADR-017).
2. That `thinking: {"type": "adaptive"}` + `output_config.effort` are accepted
   together on `claude-sonnet-5` for a forced tool call.
3. Real token counts, latencies and refusal categories — the committed fixtures
   are hand-authored, so their `usage` numbers are plausible, not measured.

All three resolve on M2-06's first `FILAWAY_AI_MODE=record` run.
