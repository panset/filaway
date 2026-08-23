# FilawayCore public API — storage, metadata, watching, search, apply

What M1-03/04/05/06 and M2-07/08 landed, and how the app layer is meant to drive it. Everything
here is in `FilawayCore` (Swift 6 language mode, no AppKit/SwiftUI). Requirement
IDs refer to `docs/spec/functional-spec.html`.

Three types do the work:

| Type | Kind | Owns |
|---|---|---|
| `NoteStore` | actor | The user's notes folder. Every read and write of a `.md` file. |
| `MetadataStore` | actor | The derived SQLite database in Application Support. |
| `LibraryWatcher` | actor | FSEvents + reconcile; publishes `LibraryChange`. |
| `SearchService` | actor | Keyword search over the derived database. |
| `PlanApplier` | actor | Applies an organization plan, whole or not at all. |
| `ActivityLog` | actor | The Activity history, the apply journal and the baselines. |
| `UndoService` | actor | Reverses an applied plan (FR-4.3). |

`Library` is the value that ties them together.

---

## Wiring it up

```swift
let library = Library(root: rootURL)              // rootURL from a bookmark or the picker
let store = NoteStore(library: library)
try await store.prepare()                          // creates ~/Notes and Application Support

let metadata = try MetadataStore(library: library) // opens + migrates the database
let watcher = LibraryWatcher(store: store, metadata: metadata)

// Subscribe before reconciling so nothing is missed.
let changes = await watcher.changes()
Task { for await change in changes { await apply(change) } }

try await watcher.reconcile()   // launch stat-scan (DS-4)
await watcher.start()           // live FSEvents

// …and again whenever the app becomes active:
// NSApplication.didBecomeActiveNotification -> try await watcher.reconcile()
```

Do all of this off the main actor. Every method below is `async` from the UI's
point of view.

### Paths

Above the `URL` layer, everything is a **relative path**: POSIX, `/`-separated,
NFC-normalised, no leading slash. `""` is the library root, `"Commands"` and
`"Commands/Docker"` are folders, `"Commands/curl.md"` is a note. `PathRules` has
the helpers (`title(of:)`, `folderPath(of:)`, `sanitizeTitle(_:)`,
`depth(ofFolder:)`) and the constants (`maxFolderDepth = 2`,
`untitled = "Untitled note"`).

`Library.url(for:)` and `Library.relativePath(for:)` convert both ways.

---

## `Library`

```swift
Library(root: URL, supportRoot: URL? = nil)
static func resolving(bookmark: Data, supportRoot: URL? = nil) throws -> (library: Library, isStale: Bool)
func bookmarkData() throws -> Data

var root: URL              // resolved, standardised
var key: String            // stable 16-hex digest of the root path
var supportDirectory: URL  // ~/Library/Application Support/Filaway/<key>
var databaseURL: URL       // …/filaway.sqlite
var recoveryBinURL: URL    // fallback bin for volumes with no Trash
func url(for relativePath: String) -> URL
func relativePath(for url: URL) -> String?
func prepareDirectories(fileManager:) throws
```

Persist the **bookmark**, not the path (NFR-5: the root may be an external or
synced volume, and it may be renamed). `isStale == true` means "write a fresh
`bookmarkData()` back to preferences". `supportRoot` exists so tests can redirect
Application Support; production code omits it.

---

## `NoteStore` (DS-1, DS-2)

### Model

```swift
struct NoteID: Hashable, Sendable, Codable      // UUID; also NoteID.derived(fromRelativePath:)
struct NoteSummary: Sendable, Equatable, Identifiable {
    let id: NoteID
    let relativePath, title, folderPath: String
    let tags: [String]
    let created, modified: Date     // modified == file mtime
    let size: Int
    let contentHash: String         // SHA-256 hex of the file's bytes
}
struct Note {                       // NoteSummary + body
    var summary: NoteSummary
    var body: String                // clean Markdown, front-matter stripped
    var frontMatter: FrontMatter?
    var hasByteOrderMark: Bool
    // id/title/relativePath/tags/created/modified forwarded from `summary`
}
struct Folder: Identifiable { path, name, depth, subfolders, notes }
struct LibrarySnapshot { notes, folderPaths, scannedAt; var tree: Folder }
```

Use `NoteSummary` for lists (the sidebar, Recents, search results) and `Note`
only for what is open in the editor. **The title is the filename stem** — there
is no separate title field and no H1 duplication in the body.

### Methods

```swift
func prepare() throws
func read(_ relativePath: String) throws -> Note
func summary(of relativePath: String) throws -> NoteSummary
func exists(_ relativePath: String) -> Bool
func scan(reusing: [String: NoteSummary] = [:], settleWindow: TimeInterval = 2) throws -> LibrarySnapshot

@discardableResult func save(body: String, to relativePath: String, tags: [String]? = nil) throws -> NoteSummary
@discardableResult func writeRaw(_ text: String, to relativePath: String) throws -> NoteSummary
@discardableResult func createNote(inFolder: String = "", title: String? = nil, body: String = "") throws -> Note
@discardableResult func rename(_ relativePath: String, to newTitle: String) throws -> NoteSummary
@discardableResult func move(_ relativePath: String, toFolder: String) throws -> NoteSummary
func createFolder(_ folderPath: String) throws
@discardableResult func deleteNote(_ relativePath: String) throws -> URL   // -> Trash
@discardableResult func deleteFolder(_ folderPath: String) throws -> URL   // -> Trash
func freeRelativePath(folder: String, title: String, excluding: String? = nil) throws -> String
```

Notes for the UI layer:

* **`save(body:)` is the autosave entry point** (FR-2.3). Pass the editor's
  buffer; the store re-attaches the front-matter block, stamping `id` and
  `created` on first save and preserving every key it does not understand. Writes
  are atomic (temp file on the same volume, then rename), so a `kill -9` mid-save
  leaves either the old file or the new one.
* **`rename` is the title change.** Feed it whatever the user typed; it sanitises
  (`/` and `:` become `-`, control characters go, leading dots go) and suffixes
  on collision (`Second` → `Second 2`). It returns the new summary — the relative
  path will have changed, so update whatever you were holding.
* **`move` throws `StorageError.folderTooDeep`** past two folder levels. Catch it
  and refuse the drag rather than surfacing an error sheet.
* **Delete returns a URL** — the item's new home in the Trash. Nothing is ever
  hard-deleted; on a volume without a Trash it lands in `Library.recoveryBinURL`.
* `createNote()` with no title yields `Untitled note.md`, then
  `Untitled note 2.md`, … (FR-1.1).
* Anything that is not a `.md` file is invisible to the store, and it never
  writes anything else into the user's tree.

### Front-matter (`FrontMatter`, `MarkdownDocument`)

You rarely need these directly — `NoteStore` handles the codec. They are public
because the organizer (M2) and importers will.

```swift
MarkdownDocument.parse(_ text: String) -> MarkdownDocument   // never throws
document.serialized() -> String                              // byte-for-byte round trip
document.frontMatter?.id / .created / .tags
```

Guarantees worth relying on: `parse(text).serialized() == text` for *every*
input (LF, CRLF, mixed, BOM, `...` terminator, unterminated block, no block at
all); setting a known key to the value it already holds changes nothing; unknown
keys keep their exact bytes and their position in the block.

---

## `MetadataStore` (DS-3)

```swift
init(library: Library) throws            // opens + migrates <supportDirectory>/filaway.sqlite
init(inMemoryFor library: Library) throws

func rebuild(from snapshot: LibrarySnapshot) throws
func apply(_ changes: [LibraryChange]) throws
func upsert(_ note: NoteSummary) throws
func upsert(_ notes: [NoteSummary]) throws
func remove(relativePath: String) throws
func remove(id: NoteID) throws

func allNotes() throws -> [NoteSummary]
func note(id: NoteID) throws -> NoteSummary?
func note(relativePath: String) throws -> NoteSummary?
func notes(inFolder: String) throws -> [NoteSummary]
func noteCount() throws -> Int
func folders() throws -> [FolderInfo]
func tree() throws -> Folder             // the sidebar tree, no disk access
func snapshot() throws -> LibrarySnapshot

func markOpened(id: NoteID, at: Date = Date()) throws
func recents(limit: Int = 10) throws -> [RecentNote]

func schemaVersion() throws -> Int
func meta(_ key: String) throws -> String?
func setMeta(_ key: String, _ value: String) throws
```

* **Sidebar Library tree**: `tree()`. It reads only the database, so it is cheap
  enough to call on every change; do not re-scan the disk for it.
* **Recents (FR-1.2)**: `recents(limit: 10)` returns `RecentNote` values ordered
  by `max(lastOpened, mtime)`, newest first — purely chronological, never
  reordered by the AI. Call `markOpened(id:)` when the user opens a note.
* Everything here is derived. Deleting `filaway.sqlite` costs one
  `rebuild(from: store.scan())`, which is what `Settings → Rebuild index` will
  do. Only `last_opened` has no file representation, and `rebuild` carries it
  across by note id.
* The migration registry is `DatabaseSchema.migrator`. Append migrations, never
  edit or reorder them. `v2-fts` (M1-06) is described under **Search** below
  and `v4-activity` (M2-08) under **Applying plans**; `v3-chunks` (M3-02) is
  still reserved, and will register *after* `v4-activity` — GRDB orders
  migrations by registration, not by name.

### Keeping the search index fed (M1-06)

```swift
init(library: Library, textLoader: NoteTextLoader? = nil) throws
func rebuild(from snapshot: LibrarySnapshot, indexingText: Bool = true) throws

func indexText(_ entries: [NoteText]) throws
func textIndexCount() throws -> Int
func staleTextNotes(limit: Int = 1_000) throws -> [NoteSummary]
func text(id: NoteID) throws -> NoteText?
func generation() throws -> Int
nonisolated var reader: any DatabaseReader
```

**You do not normally call any of this.** `upsert`, `apply(_:)` and `rebuild`
index as they write, reading each note's body through `textLoader` (default:
read the file, strip front matter) and skipping notes whose `contentHash` is
already indexed. Deletes cascade. So the index is correct after a reconcile, a
rename, a folder removal and a rebuild without the app doing anything.

The one decision the shell has to make is *when* the first index is built.
`rebuild(from:)` reads every note's body — about 1.2 s for 5,000 notes on a
release build. If that is in the way of the first paint, call
`rebuild(from:indexingText: false)`, show the sidebar, then drain
`staleTextNotes(limit:)` into `indexText(_:)` in the background; search returns
nothing until it has caught up, and nothing else is affected.

---

## `LibraryWatcher` (DS-4)

```swift
init(store: NoteStore, metadata: MetadataStore, latency: TimeInterval = 0.5)

func changes() -> AsyncStream<LibraryChange>       // one per subscriber
@discardableResult func start() -> Bool            // live FSEvents; false = unavailable
func stop()
var isWatching: Bool

@discardableResult func reconcile() async throws -> [LibraryChange]
@discardableResult func reconcile(paths: Set<String>) async throws -> [LibraryChange]

@discardableResult
func resolveExternalChange(noteID: NoteID, inMemoryText: String) async throws -> ConflictResolution
```

```swift
enum LibraryChange: Sendable, Equatable {
    case added(NoteSummary)
    case modified(NoteSummary)
    case removed(relativePath: String, id: NoteID?)
    case moved(from: String, to: String, note: NoteSummary)
    case conflict(noteID: NoteID, relativePath: String, externalCopyPath: String)
    case folderAdded(String)
    case folderRemoved(String)
    var relativePath: String
    var note: NoteSummary?
}
```

* **The stream carries external changes only.** The store's own writes are
  matched against its own-operation ledger, applied to the database, and left out
  of the stream — so autosaving a note does not bounce back as a `.modified` that
  would fight the editor. There is nothing for the UI to filter.
* `start()` is live FSEvents (file-level, 0.5 s, kernel-coalesced). `reconcile()`
  is the full stat-scan: call it on launch and on `didBecomeActive`. Both produce
  the same changes, so the UI needs one code path.
* `.moved` means the same note, new path — update the row you already have,
  do not remove and re-add. Moves are matched on the front-matter `id`, and on
  content hash for notes Filaway has never saved.
* Both `reconcile` overloads return the changes they emitted, if you would rather
  poll than subscribe.
* `reconcile(paths:)` touches only the rows the paths name, so the live path
  stays cheap on a large library; `reconcile()` reads the whole notes table and
  stat-scans the tree, which is why it is a launch/activation call, not a
  per-keystroke one.

### The conflict rule

The editor's buffer lives in the app layer, so the watcher cannot detect the
"external edit while dirty" case on its own. **The autosave layer calls
`resolveExternalChange(noteID:inMemoryText:)`** — on a `.modified` or `.removed`
for a note whose buffer is dirty, and defensively before a flush that follows an
external change.

```swift
let resolution = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: buffer)
if let copy = resolution.externalCopyPath {
    showBanner("An external edit was saved as \(PathRules.title(of: copy)).")
}
```

What it guarantees:

* The in-app buffer becomes the file's content — capture is sacred.
* The external bytes are preserved beside the note as
  `<Title> (external edit yyyy-MM-dd HHmm).md`, with a **fresh identity** so the
  library never holds two notes with one id.
* `.conflict` and an `.added` for the copy are emitted.
* It is safe when nothing actually diverged (`didConflict == false`, no copy
  written) and when the file was externally deleted (the buffer is simply
  written back).

---

## `SearchService` (FR-5.1, FR-5.2)

```swift
init(metadata: MetadataStore)
init(reader: any DatabaseReader)

func keyword(_ query: String, limit: Int = 25) async -> [KeywordHit]
func recent(limit: Int = 25) async -> [KeywordHit]
func invalidate()
```

```swift
struct KeywordHit: Sendable, Equatable, Identifiable {
    let id: NoteID
    let title, relativePath: String
    let modified: Date
    let snippet: String          // one line, whitespace collapsed, elided
    let matchRange: MatchRange?  // into the note *body*, or nil for a title-only hit
    let snippetRange: MatchRange? // the same match inside `snippet`
    let source: MatchSource
    let score: Double
}

struct MatchRange: Sendable, Equatable, Hashable {
    let location, length: Int    // UTF-16
    var nsRange: NSRange
    func substring(in text: String) -> String?
}

enum MatchSource { case titleExact, titlePrefix, titleWord, titleSubstring,
                        titleFuzzy, body, bodySubstring, recent
                   var isTitle: Bool }
```

```swift
let search = SearchService(metadata: metadata)

// One task per keystroke; cancel the previous one.
searchTask?.cancel()
searchTask = Task {
    let hits = await search.keyword(field.stringValue, limit: 25)
    guard !Task.isCancelled else { return }
    await MainActor.run { results = hits }
}
```

Notes for the UI layer:

* **`keyword` never throws and never crashes on user input.** `"`, `*`, `:`,
  `NOT`, an unterminated quote — none of it is FTS5 syntax to Filaway; it is all
  literal text. A cancelled search returns `[]` rather than a stale list.
* **Empty query → recents**, in the same order as the sidebar's Recents
  (`max(lastOpened, mtime)` first). That is what ⌘K should show before anything
  is typed.
* **Ranking is: title matches, then body relevance (bm25), then recency.**
  `source` says which band a hit is in, `score` is the number behind the sort.
  Do not re-sort; do feel free to group by `source.isTitle`.
* **`matchRange` is FR-5.2.** It is a UTF-16 range into `Note.body` — the same
  string the editor holds — so `textView.scrollRangeToVisible(hit.matchRange!.nsRange)`
  is the whole implementation. `nil` means the title matched and the body does
  not contain the query; open the note at the top.
* **Fuzzy is titles-only** (plan §1 amendment 6): a misremembered title within
  one or two edits still finds the note; a typo in the body finds nothing.
* Searching is cheap and off the store's actor, so it is safe to call on every
  keystroke without debouncing. Debounce anyway if you like — 40 ms is plenty.

---

## `LaunchTimer` (M1-07)

```swift
LaunchTimer.mark(.processStart)   // optional; defaults to the kernel's exec time
LaunchTimer.mark(.windowVisible)  // in `windowDidBecomeVisible`
LaunchTimer.mark(.editorReady)    // when the first note is editable
LaunchTimer.elapsed(to: .editorReady)  // TimeInterval?
LaunchTimer.report()                   // "processStart +0 ms, windowVisible +412 ms, …"
```

`XCTApplicationLaunchMetric` needs Xcode (plan §8), so this is the stand-in for
the "launch-to-editable < 2 s" budget. It prints one line per mark when
`FILAWAY_TIMING=1` and is silent otherwise. `processStart` comes from
`kinfo_proc` unless marked explicitly, so the number includes dyld and framework
load.

---

## Applying plans, Activity and Undo (M2-07, M2-08)

```swift
let activity = try ActivityLog(library: library)          // same filaway.sqlite, own connection
let applier  = PlanApplier(store: store, activity: activity, excludedFolders: excluded)
let undo     = UndoService(store: store, activity: activity)

try await applier.recoverIncompleteEvents()               // once, at launch, before reconcile()

let applied = try await applier.apply(plan, sessionText: session.rawText)
card.show(applied.summary)                                // FR-4.2

let result = try await undo.undoLatest()                  // the card's Undo button
if result.outcome == .partial { banner("Some changes needed a conflict block.") }
```

### `PlanApplier` (FR-4.2, FR-4.4, NFR-3)

```swift
protocol PlanApplying: Sendable {                         // the one apply contract (ADR-033)
    func apply(_ plan: OrganizationPlan) async throws -> AppliedPlan
}

init(store:activity:excludedFolders:clock:failureHook:)
func apply(_ plan: OrganizationPlan) async throws -> AppliedPlan
func apply(_ plan: OrganizationPlan, sessionText: String?) async throws -> AppliedPlan
@discardableResult func recoverIncompleteEvents() async throws -> [RecoveryOutcome]
```

One apply is: re-validate against a fresh `scan()`; **compare and swap** every
note in `plan.preconditions` and every `moveSegment` segment; write the journal
row with the before-images *before* the first write; execute in a fixed order
(folders -> new notes -> appends -> segment removals -> retitles -> moves ->
tags), each step atomic through `NoteStore`; write the after-images; flip the
status to `applied`.

* **A CAS miss throws `ApplyError.preconditionFailed([NoteID])` and changes
  nothing** — not one byte. That is FR-3.2's "the user kept typing": re-plan, do
  not re-try. A segment that is no longer in its source verbatim is the same
  error.
* `ApplyError.invalidPlan([PlanIssue])` means the library moved on in a way the
  validator rejects (a folder went away, a title is now taken).
* `appendToNote` appends under a `---` rule and an optional `##` heading, never
  interleaved. An empty target gets no rule.
* `moveSegment` appends to the destination *first*, then removes the segment from
  the source. A source left whitespace-only goes to the **Trash with its text
  intact** — it is never rewritten empty first, and never hard-deleted.
* `createNote` picks a free filename, so a collision suffixes rather than
  overwrites; `AppliedPlan.outcomes` carries the final path of every action.
* `tagNote` merges additively (case-insensitive, first spelling wins).

`AppliedPlan` gives the card everything it needs: `eventID`, a `summary` built
from what actually happened, per-action `outcomes` (kind, status, final path,
previous path), `createdNotes`, `createdFolders`, `trashedNotes` (with their
Trash URLs), `changedPaths`, and `removedNoteIDs` (the trashed ones, for the
baselines). `Organizer` stamps `sessionID` on it on the way past — it is the
only party that knows which session the plan came from. There is exactly one
`AppliedPlan` and one `ApplyError` in Core; M2-05's `PlanApplyError` was folded
into `ApplyError`, whose `io(String)` case carries anything that is not one of
the applier's own failures (ADR-033).

### Crash recovery

`recoverIncompleteEvents()` looks for journal rows still marked `inProgress`:

* **Rolls forward** when every note has a durable after-image *and* the file on
  disk still matches its hash — the work was done, only the status flip was
  lost. The event becomes a normal undoable entry.
* **Rolls back** otherwise: notes the event created go to the Trash, every
  before-image is written back to the path it came from, files left at
  intermediate paths are trashed, empty created folders are removed. The plan
  then counts as never applied.

Call it once at launch, before `watcher.reconcile()`. It is idempotent.

### `ActivityLog` (FR-4.3, FR-4.4)

```swift
init(library:) / init(inMemoryFor:)

func events(limit: Int = 25, before: ActivityCursor? = nil) throws -> [ActivityEvent]
func event(_ id: ActivityEventID) throws -> ActivityEvent?      // with before/after images
func images(for: ActivityEventID) throws -> [NoteImage]
func diff(for: ActivityEventID) throws -> [NoteDiff]            // per-note line diff
func sessionText(for: ActivityEventID) throws -> String?
func undoableEvents(limit: Int = 10) throws -> [ActivityEvent]
func recordDismissed(plan:summary:sessionText:at:) throws -> ActivityEventID
@discardableResult
func prune(olderThan: TimeInterval = 30 days, now: Date, keepingUndoDepth: Int = 10) throws -> ActivityPruneReport

func baseline(for: NoteID) throws -> OrganizedBaseline?         // BaselineStore
func setBaseline(_ baseline: OrganizedBaseline) throws          // BaselineStore
func setBaseline(noteID:hash:text:at:) throws
func removeBaseline(for: NoteID) throws                         // BaselineStore
```

* **`events(...)` does not load note text.** A page of images would be
  megabytes; call `event(_:)` for the row the user opened.
* Paging is newest-first through `ActivityCursor` (`timestamp` + `id`, so two
  events written in the same millisecond cannot hide each other).
* `diff(for:)` diffs the **body** — front matter is stripped, because `id:`
  churn is not a change the user made. `NoteDiff.unified` is `diff -u` text;
  `NoteDiff.created` / `.trashed` / `.wasRelocated` cover the rest.
* Retention (FR-4.4): `prune(olderThan:)` drops raw session text past 30 days,
  and images only for events Undo can no longer reach. Event rows stay forever.
* It is also the GRDB `BaselineStore` (`note_baselines`), the single baseline
  contract `Organizer` takes (ADR-033); `DatabaseBaselineStore` is the same
  thing as a value type, for wiring the organizer without handing it the log.
  The value type is `OrganizedBaseline` (note id, content hash, text, when, and
  the session that advanced it — `note_baselines` has no session column, so a
  round trip through the database drops `sessionID`).

### `UndoService` (FR-4.3)

```swift
func undoLatest() async throws -> UndoResult
func undo(_ eventID: ActivityEventID) async throws -> UndoResult
func undoableEvents(limit: Int = 10) async throws -> [ActivityEvent]
```

Per affected note: if the file still hashes to the after-image, the before-image
goes back **byte-for-byte**; if the user has edited it since, the reverse patch
is replayed onto the current text; if a hunk will not land, the user's text is
kept and the recovered text appended under `## Restored by Undo (conflict)`, and
the result is `.partial`. Creates become Trash, a trashed empty source is
written back, moves and retitles are reversed by moving the file.

Undo is **LIFO**: `UndoError.blockedByLaterEvent(id)` names the later
organization event that touched the same note — reverse that one first. Undo
events themselves never block. An undo records its own Activity event and makes
the original non-undoable (no redo in Phase 1). The other errors are
`.nothingToUndo`, `.unknownEvent`, `.notUndoable`.

---

## Errors

`StorageError` is `Equatable` and `CustomStringConvertible`: `.notFound`,
`.alreadyExists`, `.notAMarkdownFile`, `.folderTooDeep`, `.outsideLibrary`,
`.notUTF8`, `.couldNotFindFreeName`, `.couldNotTrash`. The two worth handling
specifically in the UI are `.folderTooDeep` (refuse the drop) and `.notUTF8`
(the file is not text Filaway can open).

---

## Performance

`filaway-bench scan --notes N [--bytes N] [--repeats N] [--root DIR] [--keep]`
times a cold scan and a full rebuild. Release build, M-series, 2026-08:

| Corpus | Scan | Rebuild | Total |
|---|---|---|---|
| 5,000 notes / 10 MB | 391 ms | 191 ms | **581 ms** |
| 5,000 notes / 48 MB (NFR-2) | 413 ms | 191 ms | **604 ms** |
| 20,000 notes / 41 MB | 1.62 s | 751 ms | **2.37 s** |

`ScaleTests` asserts the 5,000-note case stays under 3 s on a debug build
(currently ~1.2 s).

`filaway-bench keyword --notes N [--queries N] [--limit N] [--budget-millis N]`
builds the corpus, rebuilds the database *and its FTS indexes*, then times the
five query shapes FR-5.1 promises — a word, a prefix, two words, a misremembered
title, a substring inside a `curl` command. It **exits non-zero when p95 reaches
100 ms** (NFR-1), so it is usable as a CI gate. `filaway-bench all` runs `scan`
and `keyword` against one shared corpus.

| Corpus | Index rebuild | Database | Search p50 | p95 | max |
|---|---|---|---|---|---|
| 5,000 notes / 10 MB — release | 1.11 s | 55 MB | 9 ms | **12 ms** | 12 ms |
| 5,000 notes / 10 MB — debug | 1.7 s | 55 MB | 15 ms | **25 ms** | 27 ms |
| 20,000 notes / 41 MB — release | 5.1 s | 216 MB | 35 ms | **40 ms** | 46 ms |
| 20,000 notes / 41 MB — debug | 7.0 s | 216 MB | 46 ms | **91 ms** | 100 ms |

The database is ~5× the size of the Markdown it indexes; ADR-018 explains why
and what to do if that ever matters. `SearchScaleTests` gates 5,000 notes at
p95 < 100 ms on a **debug** build and reports the 20,000-note case against a
looser 500 ms (NFR-2's "degrade gracefully").

---

## Testing

`Tests/FilawayCoreTests` — 212 tests, ~2 s without the slow tags.

* `FrontMatterTests` — round trips (CRLF, BOM, foreign keys, missing block,
  400-case fuzz), ISO-8601 against Foundation.
* `NoteStoreTests` / `PathRulesTests` — sanitising, collisions, depth cap,
  trash-not-delete, atomic write, scan reuse.
* `MetadataStoreTests` — migration, rebuild equivalence and idempotence, Recents.
* `ReconcilerTests` — add/edit/remove/move externally, id and hash move
  detection, copies, echo suppression, targeted vs full scope, the conflict rule.
* `WatcherTests` — the live FSEvents stream (tagged `.fsevents`).
* `ChurnTests` — randomised external churn interleaved with app writes, asserting
  no loss, no duplicates, moves tracked, conflict copy only when dirty.
* `SearchTests` — ranking order, prefix, substring inside code, typo'd titles,
  unicode and emoji, hostile FTS5 syntax, empty query, and match-range accuracy
  (the returned range really does point at the matched text).
* `SearchIndexTests` — the index agrees with the folder after add, edit, move,
  rename, delete, folder removal, an in-app save, and a rebuild.
* `SearchUnitTests` / `LaunchTimerTests` — query escaping, edit distance, the
  signature prefilter (fuzzed against the real distance), snippets, UTF-16
  ranges across astral characters, launch marks.
* `ApplyTests` — the whole action matrix, `moveSegment` into an existing note,
  into a new one and leaving its source empty (-> Trash), CAS misses that
  byte-compare the entire tree, the depth and no-stray-file invariants.
* `ApplyRecoveryTests` — a crash injected between operations, before the
  after-images and before the commit: roll back, roll forward, inline rollback
  on error, idempotence (NFR-3).
* `ActivityLogTests` / `ActivityUndoTests` / `ActivityDiffTests` — paging,
  per-note diffs, 30-day retention with an injected clock, baselines, ten
  stacked undos restoring byte-identical trees, the reverse patch after a user
  edit, the conflict block, LIFO blocking.
* `ScaleTests` — 5,000 notes under 3 s (tagged `.slow`).
* `SearchScaleTests` — keyword p95 under 100 ms at 5,000 notes on a debug build;
  20,000 notes reported (tagged `.slow`).

`FILAWAY_SKIP_SLOW_TESTS=1 swift test` skips the churn, scale and FSEvents
suites. `Tools/fs_churn.sh --root ~/Notes -n 500` is the manual counterpart:
external churn against a running app, for watching the sidebar.
