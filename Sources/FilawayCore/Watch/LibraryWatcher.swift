import Foundation
import OSLog

/// Keeps the metadata database and the UI in step with the notes folder (DS-4).
///
/// Two complementary mechanisms, exactly as plan §1 specifies:
///
/// * **Live FSEvents** — file-level, 0.5 s latency, coalesced by the kernel.
///   Each batch triggers a *targeted* reconcile of the paths it named.
/// * **Full stat-scan** — ``reconcile()``, called on launch and whenever the app
///   is activated. Catches everything the stream could miss (app not running,
///   dropped events, an unmounted volume).
///
/// Both funnel into the same diff, so their results are identical. Changes the
/// app made itself are matched against ``NoteStore``'s own-operation ledger and
/// never reach the stream.
///
/// ```swift
/// let watcher = LibraryWatcher(store: store, metadata: metadata)
/// Task { for await change in await watcher.changes() { apply(change) } }
/// try await watcher.reconcile()   // launch scan
/// await watcher.start()           // live events
/// ```
public actor LibraryWatcher {
    private let store: NoteStore
    private let metadata: MetadataStore
    private let library: Library
    private let latency: TimeInterval
    private let log = Log.make("watcher")

    private var monitor: FSEventsMonitor?
    private var continuations: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

    private var isReconciling = false
    private var pendingPaths: Set<String> = []
    private var pendingFullScan = false

    /// - Parameter latency: FSEvents coalescing window. 0.5 s is the plan's
    ///   number: long enough that an editor's write-truncate-write cycle is one
    ///   event, short enough to feel live.
    public init(store: NoteStore, metadata: MetadataStore, latency: TimeInterval = 0.5) {
        self.store = store
        self.metadata = metadata
        library = store.library
        self.latency = latency
    }

    deinit { monitor?.stop() }

    // MARK: - Change stream

    /// A new subscription to the change stream. Several consumers may subscribe;
    /// each gets every subsequent change. Cancelling the iterating task
    /// unsubscribes.
    public func changes() -> AsyncStream<LibraryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream(bufferingPolicy: .unbounded)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ changes: [LibraryChange]) {
        guard !changes.isEmpty else { return }
        for continuation in continuations.values {
            for change in changes { continuation.yield(change) }
        }
    }

    // MARK: - Live events

    /// Starts the FSEvents stream. Idempotent.
    ///
    /// - Returns: `false` if the stream could not be created (the app should
    ///   then fall back to periodic ``reconcile()`` calls).
    @discardableResult
    public func start() -> Bool {
        guard monitor == nil else { return true }
        let created = FSEventsMonitor(root: library.root, latency: latency) { [weak self] paths, needsFullScan in
            guard let self else { return }
            Task { await self.enqueue(paths: paths, needsFullScan: needsFullScan) }
        }
        guard created.start() else { return false }
        monitor = created
        return true
    }

    /// Stops the FSEvents stream and finishes every subscription.
    public func stop() {
        monitor?.stop()
        monitor = nil
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    /// `true` while the FSEvents stream is running.
    public var isWatching: Bool { monitor?.isRunning ?? false }

    private func enqueue(paths: [String], needsFullScan: Bool) async {
        if needsFullScan { pendingFullScan = true }
        for path in paths {
            guard let relative = library.relativePath(for: URL(fileURLWithPath: path)), !relative.isEmpty else { continue }
            if PathRules.isNotePath(relative) {
                pendingPaths.insert(relative)
            } else {
                // A directory event: cheapest correct answer is a full scan.
                pendingFullScan = true
            }
        }
        await drain()
    }

    private func drain() async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        while pendingFullScan || !pendingPaths.isEmpty {
            let full = pendingFullScan
            let paths = pendingPaths
            pendingFullScan = false
            pendingPaths.removeAll()
            do {
                _ = try await performReconcile(scope: full ? nil : paths)
            } catch {
                log.error("reconcile failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Reconcile

    /// Full stat-scan of the library, diffed against the database.
    ///
    /// Call on launch and on app activation. Returns the changes that were
    /// *emitted* — the app's own writes are applied to the database but left out
    /// of the result, because the caller already knows about them.
    @discardableResult
    public func reconcile() async throws -> [LibraryChange] {
        try await performReconcile(scope: nil)
    }

    /// Reconcile restricted to a set of relative paths. Used by the FSEvents
    /// path; exposed for tests and for callers that know exactly what changed.
    @discardableResult
    public func reconcile(paths: Set<String>) async throws -> [LibraryChange] {
        try await performReconcile(scope: Set(paths.map(PathRules.normalize)))
    }

    private func performReconcile(scope: Set<String>?) async throws -> [LibraryChange] {
        let known = try await metadata.snapshot()
        let knownByPath = known.notesByPath
        var knownByID: [NoteID: NoteSummary] = [:]
        for note in known.notes { knownByID[note.id] = note }

        var diskByPath: [String: NoteSummary] = [:]
        var candidates: Set<String>
        var folderChanges: [LibraryChange] = []

        if let scope {
            candidates = scope.filter { PathRules.isNotePath($0) }
            for path in candidates {
                guard await store.exists(path) else { continue }
                if let summary = try? await store.summary(of: path) { diskByPath[path] = summary }
            }
            for path in candidates where diskByPath[path] != nil {
                let folder = PathRules.folderPath(of: path)
                if !folder.isEmpty, !known.folderPaths.contains(folder) {
                    folderChanges.append(.folderAdded(folder))
                }
            }
        } else {
            let snapshot = try await store.scan(reusing: knownByPath)
            diskByPath = snapshot.notesByPath
            candidates = Set(diskByPath.keys).union(knownByPath.keys)
            let diskFolders = Set(MetadataStore.impliedFolders(snapshot))
            let knownFolders = Set(known.folderPaths)
            folderChanges += diskFolders.subtracting(knownFolders).sorted().map { .folderAdded($0) }
            folderChanges += knownFolders.subtracting(diskFolders).sorted().map { .folderRemoved($0) }
        }

        var changes = folderChanges
        var additions: [NoteSummary] = []
        var removals: [String: NoteSummary] = [:]

        for path in candidates.sorted() {
            switch (diskByPath[path], knownByPath[path]) {
            case let (.some(disk), .none):
                additions.append(disk)
            case let (.none, .some(row)):
                removals[path] = row
            case let (.some(disk), .some(row)):
                guard disk.contentHash != row.contentHash else { continue }
                changes.append(.modified(Self.reconciled(disk: disk, database: row)))
            case (.none, .none):
                continue
            }
        }

        // Move detection: front-matter `id` first (DS-2 makes it survive a
        // rename or a drag in Finder), content hash as the fallback for notes
        // Filaway has never saved and which therefore carry no id.
        var leftoverAdditions: [NoteSummary] = []
        for addition in additions {
            let path = addition.relativePath
            if !addition.id.isDerived(fromRelativePath: path), let previous = knownByID[addition.id] {
                var stillThere = false
                if removals[previous.relativePath] == nil {
                    stillThere = await store.exists(previous.relativePath)
                }
                if !stillThere {
                    removals[previous.relativePath] = nil
                    knownByID[addition.id] = nil
                    changes.append(.moved(from: previous.relativePath, to: path, note: addition))
                    continue
                }
                // The old path is still on disk: this is a copy, not a move.
                // Give it a fresh identity so the two files never collide.
                leftoverAdditions.append(Self.reidentified(addition, as: NoteID()))
                continue
            }
            if let match = removals.first(where: { $0.value.contentHash == addition.contentHash }) {
                removals[match.key] = nil
                let carried = Self.reidentified(addition, as: match.value.id)
                changes.append(.moved(from: match.key, to: path, note: carried))
                continue
            }
            leftoverAdditions.append(addition)
        }

        changes += leftoverAdditions.map { .added($0) }
        changes += removals.values
            .sorted { $0.relativePath < $1.relativePath }
            .map { .removed(relativePath: $0.relativePath, id: $0.id) }

        guard !changes.isEmpty else { return [] }
        try await metadata.apply(changes)

        var emitted: [LibraryChange] = []
        for change in changes where await !isEcho(change) { emitted.append(change) }
        emit(emitted)
        return emitted
    }

    /// `true` when the change is the echo of one of Filaway's own writes.
    private func isEcho(_ change: LibraryChange) async -> Bool {
        switch change {
        case let .added(note), let .modified(note):
            return await store.consumeOwnOperation(relativePath: note.relativePath, contentHash: note.contentHash)
        case let .removed(path, _):
            return await store.consumeOwnOperation(relativePath: path, contentHash: nil)
        case let .moved(from, to, note):
            let destination = await store.consumeOwnOperation(relativePath: to, contentHash: note.contentHash)
            let source = await store.consumeOwnOperation(relativePath: from, contentHash: nil)
            return destination || source
        case .folderAdded, .folderRemoved, .conflict:
            return false
        }
    }

    /// A file with no front-matter `id` keeps whatever identity the database
    /// already holds for its path; a file that *does* carry an id wins.
    static func reconciled(disk: NoteSummary, database: NoteSummary) -> NoteSummary {
        guard disk.id.isDerived(fromRelativePath: disk.relativePath) else { return disk }
        return reidentified(disk, as: database.id)
    }

    static func reidentified(_ note: NoteSummary, as id: NoteID) -> NoteSummary {
        NoteSummary(
            id: id,
            relativePath: note.relativePath,
            title: note.title,
            folderPath: note.folderPath,
            tags: note.tags,
            created: note.created,
            modified: note.modified,
            size: note.size,
            contentHash: note.contentHash
        )
    }

    // MARK: - External-edit conflict rule (DS-4)

    /// Resolves an external change to a note the editor has unsaved edits for.
    ///
    /// The in-app buffer always wins as the file's content — "capture is
    /// sacred" — and the external bytes are never dropped: they are preserved
    /// next to the note as `<Title> (external edit yyyy-MM-dd HHmm).md` with a
    /// fresh identity, and a ``LibraryChange/conflict(noteID:relativePath:externalCopyPath:)``
    /// is emitted so the UI can show its banner.
    ///
    /// The buffer lives in the UI layer, so autosave calls this rather than the
    /// watcher guessing. Safe to call when nothing actually diverged: it then
    /// writes nothing extra and reports ``ConflictResolution/didConflict`` false.
    ///
    /// - Parameters:
    ///   - noteID: identity of the note being edited.
    ///   - inMemoryText: the editor's buffer — clean Markdown body, no front-matter.
    @discardableResult
    public func resolveExternalChange(noteID: NoteID, inMemoryText: String) async throws -> ConflictResolution {
        guard let row = try await metadata.note(id: noteID) else {
            throw StorageError.notFound(noteID.uuidString)
        }
        let path = row.relativePath
        let external = try? await store.read(path)

        // Externally deleted while dirty: just put the buffer back.
        guard let external else {
            let saved = try await store.save(body: inMemoryText, to: path)
            try await metadata.apply([.added(saved)])
            emit([.added(saved)])
            return ConflictResolution(note: saved, externalCopyPath: nil)
        }

        guard external.body != inMemoryText else {
            try await metadata.apply([.modified(external.summary)])
            return ConflictResolution(note: external.summary, externalCopyPath: nil)
        }

        let stamp = ISO8601.conflictStamp(from: external.modified)
        let copyPath = try await store.freeRelativePath(
            folder: row.folderPath,
            title: "\(row.title) (external edit \(stamp))"
        )
        // The copy must not inherit the note's identity, or the library would
        // hold two notes with the same id.
        var copyDocument = MarkdownDocument.parse(
            (external.frontMatter.map { $0.serialized() } ?? "") + external.body
        )
        if copyDocument.frontMatter != nil {
            copyDocument.frontMatter?.id = NoteID()
        }
        copyDocument.hasByteOrderMark = external.hasByteOrderMark
        let copy = try await store.writeRaw(copyDocument.serialized(), to: copyPath)
        let saved = try await store.save(body: inMemoryText, to: path)

        let conflict = LibraryChange.conflict(noteID: noteID, relativePath: path, externalCopyPath: copyPath)
        let changes: [LibraryChange] = [.modified(saved), .added(copy), conflict]
        try await metadata.apply(changes)
        emit(changes)
        log.notice("external edit preserved as a conflict copy")
        return ConflictResolution(note: saved, externalCopyPath: copyPath)
    }
}
