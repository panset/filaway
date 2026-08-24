import AppKit
import FilawayCore
import SwiftUI

/// The shell's single source of truth (M1-09, M1-11, M1-13).
///
/// Owns the storage stack — `Library`, `NoteStore`, `MetadataStore`,
/// `LibraryWatcher` — plus the open note, the sidebar's projection of the
/// library, and the autosave pipeline. Views read published state and call
/// intents; nothing else touches Core.
///
/// **Launch (NFR-1).** `init` does no I/O: the window paints an empty shell
/// immediately. ``bootstrap()`` then opens the database off the main thread,
/// paints the sidebar and restores the last note from the database alone, and
/// only afterwards runs the launch reconcile and starts FSEvents. See ADR-023.
@MainActor
final class AppModel: ObservableObject {

    /// The note the editor is showing.
    struct OpenNote: Equatable {
        var id: NoteID
        var relativePath: String
        var title: String
        var created: Date
    }

    /// A transient, non-blocking message (conflict copies, delete confirmations).
    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var symbol: String = "info.circle"
        var isError: Bool = false
    }

    // MARK: - Published state

    /// The Markdown body of the open note; bound straight into the editor.
    @Published var editorText: String = ""
    /// The open note's title; committing it renames the file (DS-1).
    @Published var editorTitle: String = ""
    @Published var openNote: OpenNote?

    @Published var selection: SidebarItem?
    @Published private(set) var recents: [RecentNote] = []
    @Published private(set) var tree: Folder?
    @Published private(set) var noteCount: Int = 0
    @Published var expandedFolders: Set<String> = []

    /// `true` once the database is open and the sidebar reflects it.
    @Published private(set) var isLoaded = false
    /// Notes with unwritten edits — drives "Now · editing" in Recents.
    @Published private(set) var dirtyNoteIDs: Set<NoteID> = []
    @Published var banner: Banner?

    /// Bumped to move first responder. Views observe and act.
    @Published private(set) var focusEditorRequest = 0
    @Published private(set) var focusSearchRequest = 0
    @Published private(set) var focusSidebarRequest = 0

    /// "Open the note scrolled to the relevant section" (FR-5.2). Set after the
    /// note is loaded; ``ShellView`` performs the scroll on the live text view.
    struct Reveal: Equatable {
        /// Makes two reveals of the same range distinct, so `onChange` fires.
        var token: Int
        var noteID: NoteID
        var range: NSRange
        /// `false` for a title-only hit: open at the top, select nothing.
        var selects: Bool
    }

    @Published private(set) var reveal: Reveal?
    private var revealToken = 0

    let search = SearchCoordinator()
    /// The semantic stack (M3-06): embedder, index, vectors, hybrid ranker and
    /// the answer extractor. Built behind the first frame; ⌘K is keyword-only
    /// until it is up (FR-5.5).
    let semanticSearch = SemanticSearchCoordinator()

    /// The organize pipeline (M2-12). `nil` until ``bootstrap()`` has opened the
    /// library — the shell paints, and capture works, without it.
    @Published private(set) var organize: OrganizeCoordinator?

    // MARK: - Storage stack

    /// The library, resolved on **first use** rather than in `init`.
    ///
    /// On a first launch the notes root is not knowable until the FR-7.1 gate
    /// has been answered, and `AppModel.shared` is built long before that —
    /// forced from inside SwiftUI's `StateObject` update, which is an
    /// AttributeGraph pass. Binding a `Library` there meant binding it to
    /// `~/Notes`, and (while reading the root still ran the gate) spinning that
    /// gate's modal run loop inside the graph, which left the `WindowGroup`
    /// half-installed: no window, no `ShellView.task`, no `bootstrap()`.
    ///
    /// ``bootstrap()`` waits for the gate and then reads this, which is the one
    /// place the root is resolved. **Nothing on the first-paint path may touch
    /// it** — see ``resolvedLibraryRoot`` for the display-only accessor.
    /// ADR-049, ADR-061.
    private(set) var library: Library {
        get {
            if let storedLibrary { return storedLibrary }
            let library = Library(root: rootOverride ?? AppSettings.notesRoot,
                                  supportRoot: supportRootOverride)
            storedLibrary = library
            return library
        }
        set { storedLibrary = newValue }
    }

    /// The library root **without** resolving it: `nil` until the gate has been
    /// answered and ``bootstrap()`` has opened the library. Views on the first
    /// paint use this; everything else uses ``library``.
    var resolvedLibraryRoot: URL? { storedLibrary?.root }

    private var storedLibrary: Library?
    private let rootOverride: URL?
    private let supportRootOverride: URL?
    private(set) var store: NoteStore?
    private(set) var metadata: MetadataStore?
    private(set) var watcher: LibraryWatcher?
    private(set) var autosave: AutosaveController?
    private(set) var searchService: SearchService?

    private var changeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private let debounce: TimeInterval

    var libraryKey: String { library.key }

    // MARK: - Init

    /// The app is single-window and single-library; the delegate and the scene
    /// need the same instance, and `@NSApplicationDelegateAdaptor` runs before
    /// the scene exists.
    static let shared = AppModel()

    /// `root` and `supportRoot` are **not** resolved here: see ``library``.
    init(
        root: URL? = nil,
        supportRoot: URL? = nil,
        debounce: TimeInterval = AutosaveScheduler.defaultDebounce
    ) {
        self.rootOverride = root
        self.supportRootOverride = supportRoot ?? AppSettings.supportRoot
        self.debounce = debounce
        search.onOpen = { [weak self] hit in self?.openSearchHit(hit) }
        search.onReturnFocusToEditor = { [weak self] in self?.focusEditor() }
        // M3-06: a semantic result opens the note scrolled to its chunk, in the
        // same coordinates a keyword hit uses (FR-5.2).
        search.onOpenChunk = { [weak self] noteID, range in
            self?.openSearchChunk(noteID: noteID, range: range)
        }
        search.onOpenAISettings = { SettingsWindow.open() }
        search.semantic = semanticSearch
        // FR-8.1 (M4-02): Settings turned semantic search off while the panel
        // was open — Ask goes away at once rather than at the next ⌘K.
        semanticSearch.onEnabledChanged = { [weak self] _ in
            self?.search.semanticAvailabilityChanged()
        }
    }

    // MARK: - Launch

    /// Opens the library. Safe to call twice; the second call is a no-op.
    func bootstrap() async {
        guard store == nil else { return }
        // FR-7.1: on a first launch the folder the flow chooses is the one this
        // launch opens, so nothing may resolve the notes root until the gate
        // has been answered (ADR-049, ADR-061).
        await OnboardingPresenter.waitUntilAnswered()
        let library = self.library
        // Per-library window state, which could not be read before the root was
        // known (FR-1.5).
        expandedFolders = AppSettings.expandedFolders(libraryKey: library.key)
        // Build the preference model *here*, where the root is finally known and
        // the cost is part of launch. It used to be forced from the App body,
        // which is too early (ADR-061); left to whoever asks first it is a
        // `Library`, an `AIConnectionManager` and a usage ledger opening on the
        // main actor at some arbitrary later moment — measurable as a ~130 ms
        // stall in the middle of an as-you-type keystroke.
        _ = SettingsModel.shared
        do {
            let store = NoteStore(library: library)
            try await store.prepare()
            // GRDB opens and migrates synchronously; keep it off the main thread
            // so the first frame is never blocked (NFR-1).
            let metadata = try await Task.detached(priority: .userInitiated) {
                try MetadataStore(library: library)
            }.value
            LaunchClock.mark("dbOpen")  // M4-07: GRDB open + migrations are done.
            let watcher = LibraryWatcher(store: store, metadata: metadata)

            self.store = store
            self.metadata = metadata
            self.watcher = watcher

            // Keyword search (M1-06/M1-12). It reads through
            // `MetadataStore.reader`, off the store's actor, so a keystroke
            // never queues behind an autosave — and it is entirely offline
            // (FR-5.5).
            let searchService = SearchService(metadata: metadata)
            self.searchService = searchService
            search.backend = { query, limit in
                await searchService.keyword(query, limit: limit)
            }

            // Semantic search (M3-05/M3-06). Returns immediately; the embedder,
            // the catch-up and the vector load all happen off the main actor.
            semanticSearch.start(metadata: metadata, library: library)

            let autosave = AutosaveController(store: store, watcher: watcher, debounce: debounce)
            autosave.onSaved = { [weak self] summary, _ in self?.noteSaved(summary) }
            autosave.onConflictCopy = { [weak self] copy in
                self?.show(Banner(
                    text: "An external edit was preserved as ‘\(PathRules.title(of: copy))’.",
                    symbol: "arrow.triangle.branch"
                ))
            }
            autosave.onFailure = { [weak self] _, error in
                self?.show(Banner(text: "Could not save: \(error)", symbol: "exclamationmark.triangle", isError: true))
            }
            autosave.onDirtyChanged = { [weak self] ids in self?.dirtyNoteIDs = ids }
            self.autosave = autosave

            // Subscribe before reconciling so no change is missed (core-api.md).
            let changes = await watcher.changes()
            changeTask = Task { [weak self] in
                for await change in changes {
                    await self?.handle(change)
                }
            }

            // Paint from the database alone — no disk scan — so the sidebar and
            // the last note are up before the launch reconcile runs. The yield
            // keeps the first paint out of the SwiftUI update that `.task`
            // started.
            //
            // It does **not** silence AppKit's "reentrant operation in its
            // NSTableView delegate" warning, and neither does a full run-loop
            // turn here, before `restoreLastNote()`, or inside
            // `refreshSidebarNow()` — all three were measured (M4-06). See
            // `docs/a11y-checklist.md` § 5 for what the warning is actually
            // tied to and everything that has been ruled out.
            await Task.yield()
            await refreshSidebarNow()
            isLoaded = true
            LaunchClock.mark("libraryOpen")
            await restoreLastNote()

            // M2 (FR-3.1, FR-4.x): sessions, plans, Activity, Undo, the offline
            // queue. Built after the first paint, because nothing in it is on
            // the path to an editable note (NFR-1).
            let organize = OrganizeCoordinator(
                library: library, store: store, metadata: metadata, watcher: watcher
            )
            organize.onBanner = { [weak self] text, symbol in
                self?.show(Banner(text: text, symbol: symbol))
            }
            organize.onLibraryChanged = { [weak self] noteIDs in
                Task { [weak self] in await self?.organizerChanged(noteIDs) }
            }
            organize.onOpenAISettings = {
                NotificationCenter.default.post(name: .filawayOpenAISettings, object: nil)
            }
            self.organize = organize

            Task { [weak self] in
                // `recoverIncompleteEvents()` runs inside `start()`, and it must
                // run *before* the reconcile: a rolled-back apply moves files
                // and the stat-scan has to see the tree afterwards.
                // M3-08: merge targets come from the hybrid ranker once the
                // index is up, and from FTS until then.
                await organize.start(
                    searchService: searchService,
                    autosave: autosave,
                    candidateFinder: self?.semanticSearch.candidateFinder(
                        fallback: KeywordCandidateFinder(search: searchService)
                    )
                )
                await self?.reconcile()
                _ = await watcher.start()
            }
        } catch {
            Log.app.error("library open failed: \(String(describing: error), privacy: .public)")
            show(Banner(text: "Could not open \(library.root.path): \(error)",
                        symbol: "exclamationmark.triangle", isError: true))
            isLoaded = true
        }
    }

    /// Launch and `didBecomeActive` stat-scan (DS-4).
    func reconcile() async {
        guard let watcher else { return }
        do {
            let changes = try await watcher.reconcile()
            if !changes.isEmpty { await refreshSidebarNow() }
        } catch {
            Log.app.error("reconcile failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Changing the notes folder (FR-8.1, M4-02)

    /// Points Filaway at a different notes folder, live.
    ///
    /// **Nothing is moved or copied.** The library at `url` is *opened*; the
    /// previous one is left exactly as it is, with its own database, its own
    /// exclusions and its own restored state — pointing back at it later brings
    /// all of that back. Settings says so before it calls this, because "change
    /// folder" is otherwise the most plausible-sounding way to lose a library.
    ///
    /// The order is the reverse of ``bootstrap()``: flush what is unwritten,
    /// stop everything that watches or indexes, drop the stack, re-key the
    /// per-library preferences, then bootstrap again. `bootstrap()` guards on
    /// `store == nil`, which is exactly what this leaves behind.
    func reopenLibrary(at url: URL) async {
        // FR-2.3: nothing typed may be lost, including by a settings change.
        await flushNow(trigger: .manual)

        changeTask?.cancel()
        changeTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        organize?.stop()
        await watcher?.stop()
        semanticSearch.resetForLibraryChange()

        // **Close the note while `library` is still the old one.** FR-1.5's
        // last-open note is stored per `Library.key`, and `closeOpenNote()`
        // clears that key's entry — do this after the swap and it erases what
        // the *new* library remembered, one instruction before `bootstrap()`
        // goes looking for it.
        closeOpenNote()

        AppSettings.setNotesRoot(url)
        let library = Library(root: url, supportRoot: AppSettings.supportRoot)
        self.library = library
        // Excluded folders are relative paths inside *one* library (FR-4.5), so
        // the preference store has to be re-keyed before anything reads them.
        SettingsModel.shared.settings.libraryKey = library.key

        store = nil
        metadata = nil
        watcher = nil
        autosave = nil
        searchService = nil
        organize = nil
        search.backend = nil
        recents = []
        tree = nil
        noteCount = 0
        dirtyNoteIDs = []
        // FR-1.5's window/sidebar state is per library too: the frame and the
        // sidebar width are global, the expansion set and the last-open note
        // are not.
        expandedFolders = AppSettings.expandedFolders(libraryKey: library.key)
        isLoaded = false

        await bootstrap()
        await reconcile()
        SettingsModel.shared.reloadFolders()
        show(Banner(text: "Filaway is now reading \(url.path). Nothing was moved.", symbol: "folder"))
    }

    private func restoreLastNote() async {
        guard let id = AppSettings.lastOpenNoteID(libraryKey: library.key) else { return }
        guard let metadata, let row = try? await metadata.note(id: id) else { return }
        guard let store, await store.exists(row.relativePath) else { return }
        // Reopening on launch *is* opening it — Recents leads with the note
        // the user is looking at (FR-1.2).
        await open(noteID: id)
    }

    // MARK: - Sidebar projection

    /// Coalesced refresh — a reconcile can emit dozens of changes at once.
    func scheduleSidebarRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.refreshTask = nil
            await self?.refreshSidebarNow()
        }
    }

    func refreshSidebarNow() async {
        guard let metadata else { return }
        do {
            let recents = try await metadata.recents(limit: 10)
            let tree = try await metadata.tree()
            let count = try await metadata.noteCount()
            self.recents = recents
            self.tree = tree
            self.noteCount = count
        } catch {
            Log.app.error("sidebar refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Selection

    /// Selects a note from anywhere (search results, new note, restore).
    func select(noteID: NoteID) {
        selection = .recent(noteID)
        Task { await open(noteID: noteID) }
    }

    /// Reacts to the sidebar's `List` selection.
    func selectionChanged(to item: SidebarItem?) {
        guard let noteID = item?.noteID else { return }
        Task { await open(noteID: noteID) }
    }

    /// Loads a note into the editor. Flushes the outgoing buffer first
    /// (FR-2.3 flush point).
    func open(noteID: NoteID, markOpened: Bool = true) async {
        guard openNote?.id != noteID else { return }
        guard let metadata, let store else { return }

        if let current = openNote?.id, let autosave {
            await autosave.flush(noteID: current, trigger: .noteSwitch)
        }

        guard let row = try? await metadata.note(id: noteID) else { return }
        do {
            let note = try await store.read(row.relativePath)
            openNote = OpenNote(
                id: note.id, relativePath: note.relativePath,
                title: note.title, created: note.created
            )
            editorText = note.body
            editorTitle = note.title
            if selection?.noteID != noteID { selection = .recent(noteID) }
            AppSettings.setLastOpenNoteID(noteID, libraryKey: library.key)
            if markOpened {
                try? await metadata.markOpened(id: noteID)
                await refreshSidebarNow()
            }
            organize?.noteSwitched(to: noteID)
            focusEditor()
        } catch {
            show(Banner(text: "Could not open ‘\(row.title)’: \(error)",
                        symbol: "exclamationmark.triangle", isError: true))
        }
    }

    func closeOpenNote() {
        openNote = nil
        editorText = ""
        editorTitle = ""
        selection = nil
        AppSettings.setLastOpenNoteID(nil, libraryKey: library.key)
    }

    // MARK: - Search (FR-5.2)

    /// A click, or ⏎, on a keyword hit.
    func openSearchHit(_ hit: KeywordHit) {
        Task { await openSearchHitAsync(hit) }
    }

    /// Selects the note in the sidebar, loads it, then asks the editor to scroll
    /// to the hit's `matchRange` and select it — "clicking any result opens the
    /// note scrolled to the relevant section" (FR-5.2).
    ///
    /// Works when the hit *is* the open note: `open(noteID:)` returns early in
    /// that case, and the reveal is published either way.
    @discardableResult
    func openSearchHitAsync(_ hit: KeywordHit) async -> Bool {
        guard metadata != nil else { return false }
        selection = .recent(hit.id)
        await open(noteID: hit.id)
        guard openNote?.id == hit.id else { return false }
        revealToken += 1
        reveal = Reveal(
            token: revealToken,
            noteID: hit.id,
            // A title-only hit has no body range: open at the top (ADR-019).
            range: hit.matchRange?.nsRange ?? NSRange(location: 0, length: 0),
            selects: hit.matchRange != nil
        )
        return true
    }

    /// A click, or ⏎, on a semantic result or the answer card (M3-06, FR-5.2).
    func openSearchChunk(noteID: NoteID, range: MatchRange) {
        Task { await openSearchChunkAsync(noteID: noteID, range: range) }
    }

    @discardableResult
    func openSearchChunkAsync(noteID: NoteID, range: MatchRange) async -> Bool {
        guard metadata != nil else { return false }
        selection = .recent(noteID)
        await open(noteID: noteID)
        guard openNote?.id == noteID else { return false }
        revealToken += 1
        reveal = Reveal(token: revealToken, noteID: noteID, range: range.nsRange, selects: true)
        return true
    }

    // MARK: - Focus

    func focusEditor() { focusEditorRequest += 1 }

    /// ⌘K from anywhere. Presenting the panel here rather than waiting for the
    /// field's focus callback keeps the shortcut deterministic — and testable
    /// from the headless smoke driver, which has no first responder to move.
    func focusSearch() {
        focusSearchRequest += 1
        search.activate()
    }

    func focusSidebar() { focusSidebarRequest += 1 }

    // MARK: - Banner

    func show(_ banner: Banner) {
        self.banner = banner
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.banner?.id == banner.id { self?.banner = nil }
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    // MARK: - Editor callbacks

    /// Every keystroke in the body (FR-2.3, FR-3.1).
    func editorTextChanged(_ text: String) {
        guard let open = openNote, let autosave else { return }
        autosave.textChanged(noteID: open.id, relativePath: open.relativePath, text: text)
        dirtyNoteIDs = autosave.dirtyNoteIDs
        // Starts or sustains the writing session, and supersedes anything the
        // organizer has in flight or on screen for this note (FR-3.2).
        organize?.noteEdited(open.id)
    }

    /// Scrolling and selecting sustain a session but never start one (FR-3.1).
    func editorActivityHappened(_ activity: EditorActivity) {
        guard let open = openNote else { return }
        organize?.editorActivity(open.id, kind: activity)
    }

    /// An apply or an undo rewrote notes through `NoteStore`, whose own writes
    /// are kept out of the watcher's stream — so the shell has to be told.
    private func organizerChanged(_ noteIDs: Set<NoteID>) async {
        await refreshSidebarNow()
        guard let open = openNote, noteIDs.contains(open.id), let store, let metadata else { return }
        // A dirty buffer wins: capture is sacred, and the CAS means the plan was
        // computed against text the user has since replaced anyway.
        guard !dirtyNoteIDs.contains(open.id) else { return }
        let row = (try? await metadata.note(id: open.id)) ?? nil
        let path = row?.relativePath ?? open.relativePath
        guard let note = try? await store.read(path) else {
            // The plan trashed the note it was merged out of (plan §1
            // amendment 1) — its text is safe in the destination and in the
            // Trash, but there is nothing left to show here.
            closeOpenNote()
            return
        }
        editorText = note.body
        editorTitle = note.title
        openNote?.title = note.title
        openNote?.relativePath = note.relativePath
        autosave?.noteRelocated(noteID: note.id, to: note.relativePath)
    }

    private func noteSaved(_ summary: NoteSummary) {
        // FR-5.4: the semantic index follows every autosave, debounced inside
        // the indexer.
        semanticSearch.noteSaved(summary.id)
        Task { [weak self] in
            guard let self, let metadata = self.metadata else { return }
            try? await metadata.apply([.modified(summary)])
            if self.openNote?.id == summary.id, self.openNote?.relativePath != summary.relativePath {
                self.openNote?.relativePath = summary.relativePath
            }
            await self.refreshSidebarNow()
        }
    }

    // MARK: - Flush points (FR-2.3)

    func flushNow(trigger: AutosaveTrigger = .manual) async {
        await autosave?.flushNow(trigger: trigger)
        AppSettings.flush()
    }

    /// The quit path (FR-2.3). Returns a task that finishes entirely off the
    /// main actor, so `applicationShouldTerminate` can block on it.
    func terminateFlushTask() -> Task<Int, Never>? {
        AppSettings.flush()
        return autosave?.terminateFlush()
    }

    // MARK: - Watcher stream (DS-4)

    private func handle(_ change: LibraryChange) async {
        semanticSearch.libraryChanged(change)
        switch change {
        case let .modified(summary) where summary.id == openNote?.id:
            await reconcileOpenNote(with: summary)
        case let .removed(path, id) where id == openNote?.id || path == openNote?.relativePath:
            await handleOpenNoteRemoved()
        case let .moved(_, to, summary) where summary.id == openNote?.id:
            // Renamed or moved from outside: keep the selection on this note.
            openNote?.relativePath = to
            openNote?.title = summary.title
            editorTitle = summary.title
            autosave?.noteRelocated(noteID: summary.id, to: to)
        case let .conflict(_, _, copy):
            show(Banner(
                text: "An external edit was preserved as ‘\(PathRules.title(of: copy))’.",
                symbol: "arrow.triangle.branch"
            ))
        default:
            break
        }
        scheduleSidebarRefresh()
    }

    /// An external write landed on the open note.
    private func reconcileOpenNote(with summary: NoteSummary) async {
        guard let autosave, let store else { return }
        // Dirty → the conflict rule runs and the buffer wins (ADR-010).
        if await autosave.externalChangeSeen(noteID: summary.id) { return }
        // Clean → adopt the file. `setMarkdown` clamps the existing selection,
        // so the caret survives.
        if let note = try? await store.read(summary.relativePath) {
            editorText = note.body
            editorTitle = note.title
            openNote?.title = note.title
            openNote?.relativePath = note.relativePath
        }
    }

    private func handleOpenNoteRemoved() async {
        guard let open = openNote, let autosave else { return }
        // Deleted while dirty: `resolveExternalChange` writes the buffer back.
        if await autosave.externalChangeSeen(noteID: open.id) { return }
        closeOpenNote()
    }
}
