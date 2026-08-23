# FilawayCore public API — storage, metadata, watching, search

What M1-03/04/05/06 landed, and how the app layer is meant to drive it. Everything
here is in `FilawayCore` (Swift 6 language mode, no AppKit/SwiftUI). Requirement
IDs refer to `docs/spec/functional-spec.html`.

Three types do the work:

| Type | Kind | Owns |
|---|---|---|
| `NoteStore` | actor | The user's notes folder. Every read and write of a `.md` file. |
| `MetadataStore` | actor | The derived SQLite database in Application Support. |
| `LibraryWatcher` | actor | FSEvents + reconcile; publishes `LibraryChange`. |
| `SearchService` | actor | Keyword search over the derived database. |

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
  edit or reorder them; `v3-chunks` (M3-02) and `v4-activity` (M2-08) are
  reserved. `v2-fts` (M1-06) is described under **Search** below.

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

The database is ~5× the size of the Markdown it indexes; ADR-012 explains why
and what to do if that ever matters. `SearchScaleTests` gates 5,000 notes at
p95 < 100 ms on a **debug** build and reports the 20,000-note case against a
looser 500 ms (NFR-2's "degrade gracefully").

---

## Testing

`Tests/FilawayCoreTests` — 151 tests, ~1.8 s without the slow tags.

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
* `ScaleTests` — 5,000 notes under 3 s (tagged `.slow`).
* `SearchScaleTests` — keyword p95 under 100 ms at 5,000 notes on a debug build;
  20,000 notes reported (tagged `.slow`).

`FILAWAY_SKIP_SLOW_TESTS=1 swift test` skips the churn, scale and FSEvents
suites. `Tools/fs_churn.sh --root ~/Notes -n 500` is the manual counterpart:
external churn against a running app, for watching the sidebar.
