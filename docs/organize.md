# Sessions and the organize pipeline

What M2-03, M2-05 and M2-06 landed: the writing-session model, the concurrency
core that turns a finished session into a plan, and the prompt and context
builder that make the request. All in `FilawayCore` (Swift 6, no AppKit), all
testable with `swift test` and no API key.

Requirement IDs refer to `docs/spec/functional-spec.html`; amendments refer to
`docs/plan.md` §1.

---

## The shape of it

| Type | Kind | Owns |
|---|---|---|
| `SessionMachine` | struct | FR-3.1's rules, as a pure state machine |
| `SessionTracker` | actor | the timer, the autosave flush hook, publication |
| `Organizer` | actor | FR-3.2 — baselines, in-flight, pending, dirty, the queue |
| `OrganizeContextBuilder` | struct | the user half of the prompt, inside a token budget |
| `OrganizeRequestBuilder` | enum | the `AIRequest` (model, tool, effort, timeout) |
| `TitleOverlapCandidateFinder` | struct | M2 merge-target ranking, from titles and folders alone |
| `HybridCandidateFinder` | struct | M3-08 — the same ranking through the semantic index |
| `BaselineStore`, `PendingSessionStore`, `PlanApplying`, `OrganizeLibrarySource`, `CandidateFinder` | protocols | everything the pipeline needs from other milestones |

---

## Sessions (M2-03, FR-3.1)

A session **starts on the first edit**. Scrolling and selecting sustain a
session but never start one — a session with nothing typed in it has no content
to organize.

```swift
let tracker = SessionTracker(configuration: SessionConfiguration(idleInterval: 180))
await tracker.setFlushHook { await autosave.flushNow() }
await tracker.noteEdited(noteID)                        // from onTextChange
await tracker.editorActivity(noteID, kind: .scroll)     // from onEditorActivity
await tracker.appDidResignActive()
for await event in tracker.events { … }
```

| Input | idle | active | grace (end pending) |
|---|---|---|---|
| `noteEdited` | starts a session, touches the note | touches the note, resets the idle timer | **cancels the grace**, session resumes |
| `editorActivity` (scroll/selection) | ignored | resets the idle timer | cancels the grace |
| `noteSwitched` | ignored | resets the idle timer | cancels the grace |
| `appDidResignActive` / `windowClosed` | ignored | ends the session, pipeline scheduled at `now + 30 s` | keeps the *earlier* deadline |
| `appDidBecomeActive` | ignored | ignored | **ignored** |
| `appWillTerminate` | ignored | ends now, no grace | fires the pending session now |
| idle timer | — | ends with `.idle`, `endedAt` = the deadline | — |

Two decisions worth knowing:

* **Coming back to the app does not cancel the grace.** Only touching the editor
  does. Otherwise a ⌘-Tab round trip — the exact loop amendment 2 exists for —
  would postpone filing indefinitely for a user who returns to read.
* **A second ⌘-Tab does not extend the grace.** The countdown starts once.

`idleInterval` is clamped to FR-3.1's 1–15 minutes (default 3). `gracePeriod`
defaults to 30 s and is not user-visible (amendment 2, `[ASSUMPTION]`).

### The ordering contract the app must honour

```text
idle timer fires / ⌘-Tab grace expires
       ↓
flushHook()                    autosave writes the buffer to disk
       ↓
SessionEvent.ended(Session)    published on the stream and to the observer
       ↓
Organizer.sessionEnded(_:)     reads each touched note's *current* text and its
                               organized baseline, then builds the prompt
```

The snapshot must be taken **after** the flush (or the delta misses the last
keystrokes) and **before** any apply (or a compare-and-swap precondition would be
recorded against text the plan itself rewrote). The tracker guarantees the first
half by awaiting `flushHook` before it publishes; the app must not reorder the
second.

The app also calls `Organizer.noteEdited(_:)` on every edit — the same signal
the tracker gets. It is cheap when nothing is in flight and decisive when
something is.

---

## The organizer (M2-05, FR-3.2 — risk #2)

### Per-note state

| | meaning | cleared by |
|---|---|---|
| **baseline** | text the AI has already had a chance to file (hash + text) | a completed pipeline |
| **in flight** | a request that includes this note is running | the reply, or the user typing |
| **pending** | a plan is on screen awaiting Accept / Edit / Dismiss | the user, or the user typing |
| **dirty** | a cancelled request left new material unfiled | the next session, which folds it in |

A note that has never been organized has **no** baseline, which is modelled as
empty text: the first session sends the whole note. That is right for a note
created during that session, and merely wasteful (never wrong) for one that
predates the database.

### Session end

1. Read the current text of every touched note plus any dirty notes.
2. Compute `baseline → current` per note (`TextDelta`, line-level).
   **No effective delta anywhere → skip.** Deleting text, reflowing whitespace
   or reverting an edit costs no request, and the baselines advance so the same
   non-change is not reconsidered.
3. Build the context and the request (below).
4. Decode, validate, repair.
5. `ask` → hold as `pending`, publish `.proposed`. `auto` → apply, publish
   `.applied`.

### The race matrix

| Event | Effect | Baseline |
|---|---|---|
| typing in a note with a request in flight | the request is cancelled (`Task.cancel`), every note in it is marked dirty, `.cancelled` | **unchanged** |
| typing in a note with a pending plan (session note *or* plan target) | `.withdrawn(supersededByEdit)` | unchanged |
| a newer session covering those notes | `.withdrawn(supersededBySession)` | unchanged |
| Accept | apply with CAS | advances to the **post-apply** text |
| Accept after the note changed | `.stale`, nothing written | unchanged |
| Edit → Accept | re-validated against a *fresh* snapshot, original preconditions kept | as Accept |
| Dismiss | `.withdrawn(dismissed)` | advances to the **plan-time** text |
| auto-apply succeeds | `.applied` | advances to the post-apply text |
| "nothing to do" | `.skipped(nothingToDo)` | advances to the request-time text |
| provider unreachable | `.queued`, retried on backoff | unchanged |
| a 400 / bad model / refusal | `.failed` | unchanged |

Dismiss advancing the baseline is deliberate: the user has seen this content and
said no. Not advancing would re-propose it after every future keystroke, which is
the nagging FR-6.4 forbids.

### Serialization

Requests touching the same note never overlap; a session waits for any in-flight
session it shares a note with. Disjoint sessions run concurrently, capped at
`maxConcurrentRequests` (2).

### Degradation (FR-6.4, M2-09's core)

`AIError` splits into "come back later" and "this will never work":

| Queued and retried | Reported and dropped |
|---|---|
| `rateLimited`, `serverOverloaded`, `network`, `timedOut`, `notConfigured`, `invalidKey` | `badRequest`, `modelNotFound`, `malformedResponse`, refusals, validation failures |

Queued sessions live behind `PendingSessionStore` with exponential backoff, and
`Organizer.aiStatusChanged(.connected)` drains the queue. Nothing in this path
blocks capture, browsing or keyword search — the organizer never touches the
editor.

### Plan repair (risk #6)

The validator's objections are handled per action:

1. An action the validator rejected is **dropped** — one hallucinated target must
   not cost the user the four good actions.
2. The reduced plan is re-validated. Still invalid → discard.
3. **The summary is checked against what is left.** If it names a note title or
   folder that only the dropped actions touched, the summary is now a lie about
   the plan, and the whole plan is discarded rather than shown with a wrong
   description (FR-4.2: the card "always states exactly what happened/will
   happen").
4. Plan-level errors with no action index (too many actions, an unresolvable
   contradiction) always discard: there is no action to remove that fixes them.

Actions the *decoder* could not read at all (an invented `deleteNote`) are
warnings, not errors: they never entered the plan, so nothing is lost.

### Events

```swift
enum OrganizerEvent {
    case proposed(ProposedPlan)                 // ask mode — the card
    case applied(AppliedPlan)                   // auto mode, or Accept
    case withdrawn(ProposalID, reason:)         // take the card down
    case stale(ProposalID, noteIDs:)            // CAS miss
    case cancelled(SessionID, noteID:)          // typing killed a request
    case skipped(SessionID, reason:)            // nothing to file
    case failed(SessionID, failure:)            // content-free
    case queued(SessionID, attempt:, retryAt:)  // FR-6.4
    case retrying(SessionID, attempt:)
}
```

`ProposedPlan` carries the plan, its validation (warnings are worth showing), the
actions that were dropped, and the plan-time text of every session note.

### The apply seam (M2-05 ↔ M2-07)

M2-05 and M2-07 were written in parallel and each defined the contract between
them. There is now exactly one of each (ADR-033), and it lives with the applier:

| Type | Where | Note |
|---|---|---|
| `PlanApplying` | `Organize/ApplyModel.swift` | `apply(_:) async throws -> AppliedPlan` |
| `AppliedPlan` | `Organize/ApplyModel.swift` | the applier's rich result: `eventID`, per-action `outcomes`, `createdNotes`, `createdFolders`, `trashedNotes`, `changedPaths`, plus the `sessionID` the organizer stamps |
| `ApplyError` | `Organize/ApplyModel.swift` | `preconditionFailed` / `invalidPlan` / `noteMissing` / `io` (+ the two test-hook cases) |
| `BaselineStore`, `OrganizedBaseline` | `Session/BaselineStore.swift` | `ActivityLog` and `DatabaseBaselineStore` are the durable implementations |
| `PendingSessionStore`, `PendingSession` | `Organize/OrganizerTypes.swift` | in-memory only, until M2-09 |

`ApplyError.preconditionFailed(_:)` is what the organizer turns into
`.stale(_:noteIDs:)`: the CAS semantics are M2-05's, the enum is M2-07's.
The real `PlanApplier` checks every hash in `plan.preconditions` — plus every
`moveSegment` segment, verbatim — before it touches a file, which is exactly what
the organizer's race matrix assumes.

`AppliedPlan.removedNoteIDs` (the trashed notes) is what makes a baseline
disappear rather than advance; `createdNotes` is what gives a brand-new note one.

---

## The prompt and the context (M2-06)

### `organize.v1`

`Sources/FilawayCore/AI/Prompts/organize.v1.txt` is the whole system prompt. It
splices in `plan-format.v1` at `{{include:plan-format.v1}}`, so the two
versioned prompts are rendered as one string and either one moving moves the
fixture key. It covers: the role, the closed action set with when to use each,
FR-4.6's convergence rule, depth ≤ 2, "never delete — merge is `moveSegment`
with the segment copied byte-for-byte", untitled notes get retitled, ≤ 5
lowercase tags, output only through the tool, and the Figure 2a summary style
with worked examples of what not to write.

### The user message

```text
# Session
Prompt: organize.v1
Ended: 2026-08-24T01:50:00Z (idle)
Mode: ask
Notes written in this session: 1

## Session note: Scratch
id: … / path: … / status: new — never filed
New in this session:
<<< … the delta, verbatim … >>>
Whole note as it stands now:            (omitted when it equals the delta)
<<< … >>>

# Library
Folders: …                              (depth ≤ 2, excluded folders absent)
Notes: - path (id=…) tags=…

# Candidate notes for merging
## Candidate: Commands/curl.md
id: …
First 20 lines: <<< … >>>

# Your task
File the new material from this session. Call `organization_plan` once. …
```

`Prompt: organize.v1` in the body is what makes a recorded request self-
describing, and the golden tests assert on it.

### FR-4.5 is structural

`OrganizeContext(snapshot:excludedFolders:bodies:)` runs `ExclusionFilter`
first, so an excluded note is absent from the tree, the candidates and the body
map — and its folder name is never rendered either, because naming a folder tells
the provider it exists. The organizer drops excluded notes from the session's own
delta list too, for the case where the user moved a note into an excluded folder
mid-session.

The proof is in the fixtures: the `excluded-folder` scenario, whose session
touched an excluded note, hashes to the **same request** as the scenario without
it. A test asserts that equality.

### The token budget

Target: 6 000 estimated input tokens, at a crude and deliberately pessimistic
four bytes per token. Over budget, the render is rebuilt with less, in this
order:

1. candidate previews: 20 lines → 10 → 5
2. candidates dropped from the lowest-ranked up, to a floor of one, then none
3. the library note list collapses to folders plus a count
4. session note bodies truncated *around the delta*

Candidates go first because they are the most speculative part of the prompt:
losing one costs a possible merge, while losing session text costs the plan.
**The delta itself is never truncated** — it is the thing being filed, and
`moveSegment` needs a byte-exact copy of it.

Every reduction is recorded in `OrganizeRequestContext.truncations`, so a prompt
that is quietly running hot is visible in a test rather than in a bill.

### Finding candidates (M3-08)

`CandidateFinder` is the seam. Two implementations ship:

```swift
Organizer(…, candidateFinder: TitleOverlapCandidateFinder())          // M2 default
Organizer(…, candidateFinder: HybridCandidateFinder(hybrid: hybrid))  // M3-08
```

`TitleOverlapCandidateFinder` scores word overlap between the session text and
each note's title, folder and tags. It needs no index, so it works on first
launch and before M3 exists — but a scratch note full of `kubectl` will never
find `Commands/Kubernetes` unless the word is in the title.

`HybridCandidateFinder` asks the same `HybridSearch` actor ⌘K uses: the session
text (titles first, capped at `queryCharacterLimit`, since the embedder runs at
a fixed 256-token sequence) goes in, ranked notes come back. The recency prior
is switched off — "two days ago" written *inside* someone's notes is not a
filter — and the context's own `ExclusionFilter` is applied on top of the fact
that excluded folders are never indexed (FR-4.5, twice over). Only notes present
in the `OrganizeContext` are returned, so a stale index row can never become an
`.unknownNote` in a plan.

**An empty or unavailable index falls through to `fallback`** (the title finder
by default) rather than to an empty list. Returning nothing would leave the
model with no merge targets at all and start it creating near-duplicates — the
exact sprawl FR-4.6 exists to prevent.

**How the app wires it (M3-08, done).** `OrganizeCoordinator.start` takes an
optional `CandidateFinder`, and `AppModel` passes one from the retrieval stack:

```swift
await organize.start(
    searchService: searchService,
    autosave: autosave,
    candidateFinder: semanticSearch.candidateFinder(
        fallback: KeywordCandidateFinder(search: searchService)
    )
)
```

`SemanticSearchCoordinator.candidateFinder(fallback:)` returns a **stable**
object rather than a `HybridCandidateFinder` directly, because the organizer is
built on the first paint and the embedder is still compiling then. It forwards
to the fallback until `HybridSearch` exists and to `HybridCandidateFinder` from
that moment on, so nothing has to wait and nothing has to be rebuilt.

### The request

| Field | Value | Why |
|---|---|---|
| `model` | Settings, default `claude-sonnet-5` | plan §1 "Default models" |
| `system` | `organize.v1` + `plan-format.v1` | §9 prompt versioning |
| `tools` | `OrganizationPlan.tool`, `strict: true` | FR-4.1's closed set |
| `toolChoice` | forced | no prose answers |
| `maxTokens` | 4 096 | a truncated plan is unusable |
| `thinking` | adaptive | the filing decision is the hard part |
| `effort` | `low` | plans are short; the user pays (FR-6.2) |
| `timeout` | 60 s | `AIPurpose.organize` |

---

## Golden scenarios

`Tests/FilawayCoreTests/OrganizeGoldenTests.swift` runs the **whole** pipeline —
builder → prompt → provider → decoder → validator → organizer — against
committed fixtures:

| Scenario | What it pins |
|---|---|
| `new-note` | a new subject → `createNote` in the best *existing* folder |
| `merge-code-block` | merge = `moveSegment`, segment verbatim (amendment 1) |
| `retitle-untitled` | untitled + content → `retitleNote` + ≤ 5 lowercase tags |
| `new-folder` | nothing fits → `createFolder` at depth 1, filled in the same plan |
| `nothing-to-do` | FR-4.6 — an empty plan, and the baseline still advances |
| `convergence` | FR-4.6 — an existing note beats a plausible new folder |
| `excluded-folder` | FR-4.5 — identical request with the excluded note removed |
| `invalid-action-dropped` | risk #6 — the good action survives |
| `summary-no-longer-matches` | risk #6 — the whole plan goes instead |

`Tests/FilawayCoreTests/OrganizeIntegrationTests.swift` is the other end of the
same rope: the `Organizer`, the **real** `PlanApplier`, the `ActivityLog` as the
`BaselineStore` and `UndoService`, over a temp library on disk with a
`MockProvider` for the model — auto mode end to end, and ask mode all the way
through propose → accept → applied → undo, asserting the tree comes back
byte-identical.

The **responses** are hand-authored (no key on this machine); the **requests**
are captured from the real builder:

```bash
FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "OrganizeGoldenTests/regenerate"
FILAWAY_AI_MODE=record       swift test --filter "Organize goldens"   # when a key exists
```

---

## The app wiring (M2-09, M2-10, M2-12) — done

`Sources/FilawayApp/Features/Organize/OrganizeCoordinator.swift` is the whole
seam. `AppModel` owns the storage stack and builds one of these after the first
paint; nothing in it is on the path to an editable note (NFR-1).

```text
editor keystroke ─┬─▶ SessionTracker.noteEdited      starts/sustains the session
                  └─▶ Organizer.noteEdited           FR-3.2's supersede rules
scroll / selection ─▶ SessionTracker.editorActivity
note switch ────────▶ SessionTracker.noteSwitched
⌘-Tab / close / quit ▶ appDidResignActive / windowClosed / appWillTerminate

tracker.events ─▶ flushHook (autosave) ─▶ .ended ─▶ Organizer.sessionEnded
organizer.events ─▶ @MainActor cards, status pill, banners
after apply/undo ─▶ LibraryWatcher.reconcile(paths:) ─▶ sidebar, index, editor
```

| Need | What it is now | Who swaps it |
|---|---|---|
| library snapshot + bodies | `OrganizeLibrarySourceLive` (**disk**, not the database) | — |
| merge candidates | `KeywordCandidateFinder` over `SearchService.keyword` + title overlap | M3-08 → hybrid |
| baselines | `ActivityLog` (`note_baselines`) | — |
| apply | `PlanApplier` | — |
| offline queue | `PendingSessionStoreGRDB` (`pending_sessions`, `v5-pending-sessions`) | — |
| settings | `OrganizeSettingsSource`, UserDefaults-backed | M2-11 → `AppSettings` |
| provider | `AIProviderFactory`, `FILAWAY_AI_MODE` defaulting to **`live`** (ADR-041) | — |

Three things are worth knowing because they are easy to get wrong:

* **The snapshot comes from `NoteStore.scan`, not `MetadataStore`.** Preconditions
  are a compare-and-swap against the bytes the applier is about to check, and the
  database is updated asynchronously after every save. A snapshot one autosave
  behind turns a good plan into a spurious `.stale`.
* **`recoverIncompleteEvents()` runs before the launch `reconcile()`.** A
  rolled-back apply moves files; the stat-scan has to see the tree afterwards.
* **The applier's writes never reach the watcher's stream** — they are the
  store's own operations, which is exactly why autosave does not bounce back as
  a `.modified`. So the coordinator explicitly calls `reconcile(paths:)` and
  tells `AppModel` to reload the open note (unless its buffer is dirty, in which
  case capture wins).

### The card, the sheets and the window (M2-10)

* `OrganizationCardView` / `OrganizationCardStack` — Figure 2a, bottom-trailing,
  queued, never first responder. Ask: **Accept** (⏎) / **Edit** / **Dismiss**
  (⎋), waits indefinitely. Auto: **Undo** / **View changes**, fades after 20 s.
  ADR-042 has the placement rationale.
* `EditPlanSheet` — include/exclude each action, re-target a folder or a note,
  fix a proposed title. It can only produce actions the model could have
  produced. **Apply** goes through `Organizer.accept(_:plan:)`, which
  re-validates against a fresh snapshot and keeps the original preconditions.
* `ViewChangesSheet` + `NoteDiffView` — the real unified diff from
  `ActivityLog.diff(for:)` for an applied event; for a *proposal* there are no
  images yet (nothing touched the disk), so it shows the plan's actions as a
  structured preview and says the diff arrives after Accept. Simulating the
  applier to fake one would be a second implementation of apply.
* `ActivityWindowView` (Window ▸ Activity, ⌥⌘A) — events newest first with
  model and prompt version, a diff pane, Undo with the LIFO blocked reason
  spelled out (`ActivityLog.laterEvent(touching:after:)`), and the raw session
  text behind a disclosure (FR-4.4). Edit ▸ **Undo Last Organization** is ⌥⌘Z;
  ⇧⌘Z stays the editor's Redo.

### Degradation (M2-09)

`AIStatusIndicator` in the toolbar: `AI ready` · `AI queued · N` · `AI offline`
· `Key invalid` · `AI paused` · `AI off`. Clicking it calls
`onOpenAISettings`, which posts `.filawayOpenAISettings` for M2-11's Settings
scene. Queued sessions live in `pending_sessions` and are retried on a 60 s
loop, on `aiStatusChanged(.connected)`, and once at launch. No modal alert
anywhere, and nothing on this path can block a keystroke.

### Raw session text (FR-4.4) — closed in M4-08

The organizer used to call `PlanApplying.apply(_:)`, which had no room for the
session's raw text, so FR-4.4's "the original raw session text remains
recoverable" had nothing to recover on the automatic path. Closed by the second
of the two options this note listed:

* `PlanApplying` gained `apply(_:sessionText:)`, with a **default implementation
  that drops the text and calls `apply(_:)`** — an in-memory double in a
  race-matrix test has nowhere to put it, and the organizer must not have to
  know which kind of applier it holds.
* `ProposedPlan.sessionText` carries it from the request context to the apply,
  so the ask path and the auto path file the same string.
* The string is `SessionDelta.rawSessionText(of:)`: the session's **added**
  material only, never the note it was typed into and never the baseline. One
  note gives its `addedText` unadorned; several get a `## <title>` heading each,
  so the Activity window's disclosure says which note a paragraph came from.
* `ActivityLog.prune(olderThan:)` keeps it for 30 days, and
  `MaintenanceScheduler` in `OrganizeCoordinator.start()` is what makes the
  prune actually run — once a day, off a durable stamp.

Asserted end to end in `ReliabilityRetentionTests`, both modes.

## What the app layer has to wire

1. `SessionTracker` ← editor: `onTextChange` → `noteEdited`, `onEditorActivity`
   → `editorActivity`, plus `noteSwitched`, `appDidResignActive`,
   `appDidBecomeActive`, `windowClosed`, `appWillTerminate`.

   `FilawayApp` has its own AppKit-side `EditorActivity` enum; map it to
   `FilawayCore.EditorActivityKind` — `.typing → .keystroke`,
   `.selection → .selection`, `.scroll → .scroll`. (A `.keystroke` and a
   `noteEdited` are the same thing to the tracker; only the edit path marks the
   note as touched.)
2. `tracker.setFlushHook { await autosave.flushNow() }` — before anything
   else. `AutosaveController.flushNow()` (trigger `.manual`) exists for exactly
   this.
3. `for await case .ended(let session) in tracker.events { await organizer.sessionEnded(session) }`.
4. `organizer.noteEdited(noteID)` on every edit, for the supersede rules.
5. An `OrganizeLibrarySource` over `MetadataStore` (snapshot) and `NoteStore`
   (bodies).
6. The `PlanApplier` actor as the `PlanApplying`, and the `ActivityLog` (or the
   `DatabaseBaselineStore` façade over it) as the `BaselineStore` — both real
   since M2-07/M2-08, over `note_baselines` in `filaway.sqlite`. The
   `PendingSessionStore` is `PendingSessionStoreGRDB` since M2-09.
7. `organizer.aiStatusChanged(_:)` whenever the status pill changes, and
   `setSettings` whenever Settings does.
8. The card (M2-10) from `.proposed` / `.applied`, taken down on `.withdrawn`
   and `.stale`.
