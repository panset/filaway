# Spec §8 — the success-criteria dry run

**Task:** plan §3 M4-11. **Date:** 2026-08-23.

Spec §8 makes four promises. Three of them are about a person with a stopwatch
and a week of real notes, which is why they are the *last* thing Phase 1 does
and the only thing in this repository no test can settle.

| # | Criterion | How it is settled | Status |
|---|---|---|---|
| 1 | Install → typing in **under 3 minutes** | §1, stopwatch, once, on a clean user account | **not run** — needs a notarized DMG (M4-05, blocked on enrolment) |
| 2 | Find a stored command by natural language in **under 10 s, ≥ 90%** of the time | §2, a week of `Help → Log Retrieval Outcome…` | **not run** — the instrument is in, the week is not |
| 3 | **Zero AI content loss** | §3, mostly already automated | **automated; one gap** |
| 4 | Notes readable in **any text editor** | §4, one command | **PASS** |

Criterion 2 has a laboratory answer already — the M3-07 benchmark says 95% of
queries put the right note first in 14 ms over a 302-note corpus
(`docs/verification/M4-perf.md`). That is a gate, not a population estimate:
one corpus, one voice, and queries written by the person who wrote the notes.
The week is what turns it into a number about *this user's* library.

---

## 1. Criterion 1 — install to typing, under 3 minutes

**Run once, on a macOS account that has never seen Filaway.** Not a fresh
Terminal — a fresh *user*: `System Settings → Users & Groups → Add User`, then
log in as them. The point is that nothing is cached, no Keychain item exists, no
`~/Notes` exists, and `~/Library/Application Support/Filaway` is absent.

**Start the stopwatch when the DMG has finished downloading**, not when it has
finished copying: the download is the network's fault, everything after it is
ours.

1. Open the DMG, drag Filaway to Applications, eject.
2. Launch. Approve Gatekeeper if it asks.
3. Onboarding step 1 — accept the default `~/Notes`, or pick a folder.
4. Onboarding step 2 — paste an API key, or **Skip for now**. Run it *both*
   ways, on two accounts: skipping is the path most people take on day one, and
   FR-6.5 says the app has to be fully usable after it.
5. Onboarding step 3 — orientation, Finish.
6. **Stop the stopwatch at the first character appearing in the editor.**

Record, in `docs/verification/success-criteria.md` under §5:

* wall-clock seconds, both with and without a key;
* how long the key validation itself took (it is a live `GET /v1/models`);
* anything that made you stop and read.

**What the instrument already says.** The app's own launch marks
(`FILAWAY_TIMING=1`, `filaway-bench launch`) put cold launch to an editable
window at **242 ms** on an empty library and **374 ms** on 20,000 notes
(`docs/verification/M4-perf.md`). So of the 180-second budget, Filaway's own
code accounts for under half a second. Everything else is Gatekeeper, the drag
to Applications, and reading three onboarding screens. If this criterion fails
it will be because onboarding asks too much, not because the app is slow —
which is worth knowing before the run, so the stopwatch is on the *right*
thing.

**Blocked on:** a notarized DMG. `Tools/notarize.sh` exits with `BLOCKED:` until
the Developer Program enrolment lands (`docs/release.md`). An ad-hoc-signed
`build/Filaway.app` will do for a rehearsal, but the real number has to include
Gatekeeper's first-launch check, which only a notarized build produces.

---

## 2. Criterion 2 — the retrieval week

> *"find a specific stored command via natural language in under 10 seconds,
> at least 90% of the time."*

### 2.1 The instrument

**Help → "Log Retrieval Outcome…"** (⌃⌥⌘L). A three-field prompt — the query,
whether you found it, how many seconds — appending one JSON object per line to:

```
~/Library/Application Support/Filaway/retrieval-log.jsonl
```

```json
{"at":"2026-08-23T20:23:46Z","found":true,"query":"the curl for staging docs","seconds":6.5}
```

Deliberately **outside** the per-library folder, so pointing the app at a
different notes folder mid-week does not split the sample in two. It is local
only: nothing uploads it, and `Help → Export diagnostics` must not include it
(NFR-4; M4-08 owns that exclusion). Note *content* never enters it — an outcome
is a query, a yes/no and a stopwatch reading.

Reading it back:

```
filaway-bench retrieval-log summarize
filaway-bench retrieval-log summarize --all              # every entry, not just failures
filaway-bench retrieval-log summarize --budget-seconds 5 # a harder bar
filaway-bench retrieval-log add "the jq one-liner" --seconds 8   # scripted, no GUI
```

```
hit rate:      67% (2/3 found)
under 10 s:    33% — found *and* inside the budget (spec §8 bar: 90%)
median:        14.0 s over every search
median (hits): 6.5 s
p90 / max:     22.0 s / 22.0 s

not found (1):
  2026-08-23T20:23:46Z  14.0 s    “the ffmpeg flags”
found but over 10 s (1):
  2026-08-23T20:23:46Z  22.0 s    “that awk thing” — had to rephrase twice
```

Two rates, and the difference between them matters. **Hit rate** is "did you
find it at all". **`under 10 s`** is the spec §8 criterion — found *and* inside
the budget — and it is the one the PASS line reports. A search that succeeds on
the fourth rephrasing is not a success.

### 2.2 The protocol

**Seven consecutive days of ordinary use.** Not a test session: the value of
this week is that the queries are ones you actually needed answered, on notes
you actually wrote.

**Log every natural-language retrieval, including the ones that go well.**
This is the discipline the whole thing rests on, and the failure mode is
obvious: it is much more tempting to log a frustrating search than a smooth
one, and a log of nothing but frustrations reports a 20% hit rate on an app
that works. If you notice you have only logged misses for a day, note that in
§5 and treat the day as unusable rather than pretending.

**Time from the first keystroke in ⌘K to having the answer** — the command in
front of you, ready to copy. Not to the results appearing. If you gave up, log
`found: false` with the seconds you spent before giving up.

**What counts as a retrieval:** you wanted a specific thing you had written
before and went to ⌘K to get it. What does not: browsing the sidebar, opening
the note you were just editing, or searching for a note you knew the title of
(that is FR-1.3's keyword path and it is not what §8 is about — though if you
*typed* a title because you did not trust Ask to find it, that is itself worth
a note).

**Aim for 30+ entries.** Fewer than about 20 and one bad day moves the
percentage by more than the thing being measured. `summarize` prints how many
of the seven days have entries, and says so when the sample is not the week.

**On the last day**, run `summarize` and paste the output into §5 below,
together with:

* how many notes were in the library and roughly how old the oldest was;
* whether AI was connected (an unconnected app answers from the local
  heuristic, which M3-07 measured as a *high* floor — 90% answer accuracy on
  the dev corpus — so a skipped-key week is a legitimate and interesting run,
  just a different one);
* every miss, with what you would have needed the app to understand.

### 2.3 Reading the result

* **≥ 90% under 10 s** — criterion met. Record it and stop.
* **80–90%** — read the misses before touching anything. M3-07's ablations
  (`docs/verification/M3-retrieval.md` §3) show every constant in the ranker was
  wrong when set from first principles and right when set from a corpus; the
  same will be true here. The levers, in the order they paid off last time:
  the prompt-chunk count, `rrfK`, `RecencyPrior.maxBoost`.
* **Misses that are all typos** — already fixed; M4-07's typo repair took that
  category from 57% to 100% (`docs/verification/M4-perf.md`). If it recurs,
  the repair's one-edit budget is the first thing to look at.
* **Misses where the right note ranked 2nd or 3rd** — retrieval is fine and the
  *answer step* is choosing badly. That is a prompt question, and it means
  re-running §4 of `docs/prompts.md` with a key.
* **Misses where the note was not in the top ten at all** — retrieval. Add the
  query and the expected note to `Tests/Fixtures/queries/dev.json`, so the next
  benchmark run can see it. **A miss that does not become a fixture will
  happen again.**

---

## 3. Criterion 3 — zero AI content loss

Mostly settled without a human, and the automated part is in
`docs/verification/M2.md`:

* **No action in the closed set can delete user text** —
  `OrganizePlanTests`: *"no action in the closed set can delete user text
  (FR-4.4)"*. A merge is a segment *move*, carried byte-for-byte.
* **An emptied source goes to the Trash, never `unlink`** — `ApplyTests`,
  `ActivityUndoTests`: *"undo of a created note moves it to the Trash, never
  deletes it"*.
* **Undo ten deep restores a byte-identical tree at every step** —
  `ActivityUndoTests`: *"ten stacked events unwind to a byte-identical tree at
  every step"*.
* **An edit the reverse patch cannot unpick becomes a marked conflict block,
  never a loss** — same suite.
* **A crash mid-apply rolls back or forward, never halfway** —
  `ApplyRecoveryTests`, six tests.

**The one gap, and it belongs in this document rather than only in M2's:**
FR-4.4 also promises the session's *raw text* is retrievable for 30 days, and
on the automatic path it is never recorded at all (`docs/organize.md` § "Known
gap", `docs/verification/M2.md` §3.4). Storage, pruning and the 29/31-day test
all exist; the applier contract has no parameter to carry the text. **Close this
before the dogfood week**, because a week of auto-mode filing is exactly when
someone will want to see what they wrote before the AI moved it.

**The human half:** during the week, whenever a card says it moved something,
check the source note. `Activity` (⌥⌘A) shows the diff and `Undo Last
Organization` (⌥⌘Z) puts it back. Log any instance where text you wrote is not
somewhere you can find it — that is a Phase 1 blocker, not a polish item.

---

## 4. Criterion 4 — the notes are just Markdown — **PASS**

```
find ~/Notes -name '*.md' | head -20 | xargs -n1 cat | less
ls ~/Notes                      # folders and .md files, nothing else
```

Nothing but `.md` files and folders, at most two folder levels
(`PathRules.maxFolderDepth`), the filename stem is the title, and front matter
is three optional keys (`id`, `created`, `tags`) written only when the app
saves. Asserted by `ApplyTests` (*"nothing but .md files ever lands in the
user's tree"*), `FrontMatterTests` and `NoteStoreTests`. `_assets/` is reserved
for future attachments and skipped by the scanner (ADR-040), and is the only
non-note thing the tree will ever contain.

Everything derived — the database, the vectors, the activity log, the usage
ledger, this retrieval log — lives in `~/Library/Application Support/Filaway/`
and can be deleted at any time.

---

## 5. Results

*Fill in during the run. Leave the table empty rather than optimistic.*

### 5.1 Install → typing

| Account | With a key | Skipped the key | Notes |
|---|--:|--:|---|
| | | | |

### 5.2 The retrieval week

```
paste the output of `filaway-bench retrieval-log summarize` here
```

| | |
|---|---|
| Library size | |
| AI connected | |
| Days logged | |
| Hit rate | |
| Under 10 s (spec §8) | |
| Median seconds (hits) | |

**Misses, and what each would have needed:**

### 5.3 Content loss

Any instance of text written and not findable afterwards. *Expected: none.*
