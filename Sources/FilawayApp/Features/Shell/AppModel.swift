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

    // MARK: - Storage stack

    private(set) var library: Library
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

    init(
        root: URL = AppSettings.notesRoot,
        supportRoot: URL? = AppSettings.supportRoot,
        debounce: TimeInterval = AutosaveScheduler.defaultDebounce
    ) {
        self.library = Library(root: root, supportRoot: supportRoot)
        self.debounce = debounce
        self.expandedFolders = AppSettings.expandedFolders(libraryKey: library.key)
        search.onOpen = { [weak self] hit in self?.openSearchHit(hit) }
        search.onReturnFocusToEditor = { [weak self] in self?.focusEditor() }
    }

    // MARK: - Launch

    /// Opens the library. Safe to call twice; the second call is a no-op.
    func bootstrap() async {
        guard store == nil else { return }
        let library = self.library
        do {
            let store = NoteStore(library: library)
            try await store.prepare()
            // GRDB opens and migrates synchronously; keep it off the main thread
            // so the first frame is never blocked (NFR-1).
            let metadata = try await Task.detached(priority: .userInitiated) {
                try MetadataStore(library: library)
            }.value
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
            // started, so AppKit never sees a reentrant table edit.
            await Task.yield()
            await refreshSidebarNow()
            isLoaded = true
            LaunchClock.mark("libraryOpen")
            await restoreLastNote()

            Task { [weak self] in
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

    /// Every keystroke in the body (FR-2.3).
    func editorTextChanged(_ text: String) {
        guard let open = openNote, let autosave else { return }
        autosave.textChanged(noteID: open.id, relativePath: open.relativePath, text: text)
        dirtyNoteIDs = autosave.dirtyNoteIDs
    }

    private func noteSaved(_ summary: NoteSummary) {
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
