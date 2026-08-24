import Foundation
import GRDB

/// A chunk as it exists in the database, with its identity.
public struct IndexedChunk: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let noteID: NoteID
    public let ordinal: Int
    public let kind: ChunkKind
    public let headingPath: [String]
    /// UTF-16 range in the note body (FR-5.2 scroll-to).
    public let range: MatchRange
    public let language: String?
    /// The text that was embedded.
    public let text: String

    public init(
        id: Int64,
        noteID: NoteID,
        ordinal: Int,
        kind: ChunkKind,
        headingPath: [String],
        range: MatchRange,
        language: String?,
        text: String
    ) {
        self.id = id
        self.noteID = noteID
        self.ordinal = ordinal
        self.kind = kind
        self.headingPath = headingPath
        self.range = range
        self.language = language
        self.text = text
    }

    public var headingBreadcrumb: String { headingPath.joined(separator: " › ") }
}

/// What the Settings pane and the status pill show while indexing (FR-5.4).
public enum IndexStatus: Sendable, Equatable {
    case idle
    /// Ordinary incremental work: `completed` of `total` notes.
    case indexing(completed: Int, total: Int)
    /// A full rebuild — a model swap, or `Settings → Rebuild index`.
    case reindexing(completed: Int, total: Int)

    public var isBusy: Bool { self != .idle }

    /// `0 ... 1`, or `nil` when nothing is running.
    public var fraction: Double? {
        switch self {
        case .idle: nil
        case let .indexing(completed, total), let .reindexing(completed, total):
            total > 0 ? min(1, Double(completed) / Double(total)) : nil
        }
    }
}

/// What one pass over the dirty queue did.
public struct IndexReport: Sendable, Equatable {
    public var notesIndexed = 0
    public var notesSkipped = 0
    public var notesPurged = 0
    public var chunksInserted = 0
    public var chunksReused = 0
    public var chunksDeleted = 0
    public var embeddingsComputed = 0

    public init() {}

    static func + (lhs: Self, rhs: Self) -> Self {
        var out = lhs
        out.notesIndexed += rhs.notesIndexed
        out.notesSkipped += rhs.notesSkipped
        out.notesPurged += rhs.notesPurged
        out.chunksInserted += rhs.chunksInserted
        out.chunksReused += rhs.chunksReused
        out.chunksDeleted += rhs.chunksDeleted
        out.embeddingsComputed += rhs.embeddingsComputed
        return out
    }
}

/// Keeps `chunks` and `embeddings` in step with the notes folder (M3-02, FR-5.4).
///
/// Work arrives from three places and lands in one debounced per-note queue:
///
/// 1. **Autosave** — the app calls ``markDirty(_:)`` after every save.
/// 2. **``LibraryWatcher``** — ``apply(_:)`` translates a change batch.
/// 3. **``rebuildAll()``** — `Settings → Rebuild index`, and the automatic
///    consequence of a model change.
///
/// Each note is processed as *read → chunk → embed → write*. Only the write is
/// a transaction, and only the changed chunks are embedded: chunks are diffed
/// by ``NoteChunk/textHash``, so inserting a paragraph at the top of a note
/// shifts every ordinal but re-embeds nothing. Embedding happens **outside**
/// the transaction, so a 5,000-note reindex never holds the database writer
/// for more than a few milliseconds at a time.
///
/// ```swift
/// let indexer = Indexer(metadata: metadata, embedder: embedder,
///                       vectorStore: vectors, isExcluded: exclusions.isExcluded(path:))
/// await indexer.start()          // debounce loop
/// await indexer.markDirty(note.id)
/// ```
public actor Indexer {
    public struct Configuration: Sendable {
        /// How long a note must be quiet before it is re-indexed. Plan §3
        /// M3-02 says 2 s, which also swallows an autosave burst.
        public var debounce: Duration
        /// How often the loop wakes when nothing is due.
        public var pollInterval: Duration
        /// Chunks handed to the embedder in one call.
        public var embedBatchSize: Int
        /// Notes read per batch during a rebuild.
        public var notesPerBatch: Int
        /// Priority the bulk work runs at (M4-07).
        ///
        /// A first-launch build is 50 s at 5,000 notes and 220 s at 20,000
        /// (`docs/verification/M3-perf.md`), and it must never compete with
        /// typing or with a ⌘K query. The debounce loop and every embedding
        /// batch run at this priority regardless of who called in, so the
        /// guarantee does not depend on each call site remembering to lower
        /// itself. `.utility` maps to `QOS_CLASS_UTILITY`, which the scheduler
        /// will preempt for anything user-initiated.
        public var workPriority: TaskPriority

        public init(
            debounce: Duration = .seconds(2),
            pollInterval: Duration = .milliseconds(250),
            embedBatchSize: Int = 32,
            notesPerBatch: Int = 64,
            workPriority: TaskPriority = .utility
        ) {
            self.debounce = debounce
            self.pollInterval = pollInterval
            self.embedBatchSize = max(1, embedBatchSize)
            self.notesPerBatch = max(1, notesPerBatch)
            self.workPriority = workPriority
        }
    }

    /// `meta` key holding the model every stored vector was produced with.
    public static let modelMetaKey = "embedding_model_id"

    private let metadata: MetadataStore
    private let embedder: any Embedder
    private let chunker: Chunker
    private let vectors: VectorStore?
    private let configuration: Configuration
    private let isExcluded: @Sendable (String) -> Bool
    private let log = Log.index

    private var deadlines: [NoteID: ContinuousClock.Instant] = [:]
    private var loop: Task<Void, Never>?
    private var currentStatus: IndexStatus = .idle
    private var observers: [UUID: AsyncStream<IndexStatus>.Continuation] = [:]

    public init(
        metadata: MetadataStore,
        embedder: any Embedder,
        chunker: Chunker = Chunker(),
        vectorStore: VectorStore? = nil,
        configuration: Configuration = .init(),
        isExcluded: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.metadata = metadata
        self.embedder = embedder
        self.chunker = chunker
        vectors = vectorStore
        self.configuration = configuration
        self.isExcluded = isExcluded
    }

    // MARK: - Status

    public var status: IndexStatus { currentStatus }

    /// How many notes are waiting (debounced or not).
    public var pendingCount: Int { deadlines.count }

    /// A stream of ``IndexStatus`` for the Settings progress row.
    public func statusStream() -> AsyncStream<IndexStatus> {
        AsyncStream { continuation in
            let token = UUID()
            continuation.yield(currentStatus)
            observers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func publish(_ status: IndexStatus) {
        guard status != currentStatus else { return }
        currentStatus = status
        for continuation in observers.values { continuation.yield(status) }
    }

    // MARK: - Queue

    /// Marks a note for re-indexing after the debounce interval.
    public func markDirty(_ id: NoteID) {
        deadlines[id] = ContinuousClock.now.advanced(by: configuration.debounce)
    }

    public func markDirty(_ ids: some Sequence<NoteID>) {
        let deadline = ContinuousClock.now.advanced(by: configuration.debounce)
        for id in ids { deadlines[id] = deadline }
    }

    /// Translates a ``LibraryWatcher`` batch into queue work.
    ///
    /// Removals are applied at once — the note row is already gone (and its
    /// chunks with it, by cascade), so all that is left is dropping the
    /// vectors from the resident matrix.
    public func apply(_ changes: [LibraryChange]) async {
        var removed: [NoteID] = []
        // Some removals cannot name the notes they took with them: a folder
        // removal deletes its notes by path inside ``MetadataStore``, and a
        // `.removed` for a file the database never knew has no id. The chunks
        // are gone either way (they cascade from `notes`); the resident matrix
        // is what needs telling, and the only honest answer is to reread it.
        var needsReload = false
        for change in changes {
            switch change {
            case let .added(note), let .modified(note), let .moved(_, _, note):
                if isExcluded(note.relativePath) {
                    removed.append(note.id)
                    deadlines[note.id] = nil
                } else {
                    markDirty(note.id)
                }
            case let .removed(_, id):
                if let id {
                    removed.append(id)
                    deadlines[id] = nil
                } else {
                    needsReload = true
                }
            case .conflict, .folderAdded:
                break
            case .folderRemoved:
                needsReload = true
            }
        }
        if !removed.isEmpty {
            await vectors?.removeNotes(removed)
        }
        if needsReload {
            do {
                try await vectors?.reloadIfLoaded()
            } catch {
                log.error("vector reload after a removal failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Consumes an entire watcher stream. Cancel the returned task to stop.
    public func observe(_ changes: AsyncStream<LibraryChange>) -> Task<Void, Never> {
        Task { [weak self] in
            for await change in changes {
                await self?.apply([change])
            }
        }
    }

    // MARK: - The loop

    /// Starts the debounce loop. Idempotent.
    public func start() {
        guard loop == nil else { return }
        loop = Task(priority: configuration.workPriority) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let slept = await self.tick()
                if !slept { return }
            }
        }
    }

    /// Stops the loop. Anything queued stays queued.
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One iteration: index whatever is due, then sleep. Returns `false` when
    /// the task was cancelled.
    private func tick() async -> Bool {
        let due = dueNotes()
        if !due.isEmpty {
            do {
                _ = try await index(notes: due, reindexing: false)
            } catch is CancellationError {
                return false
            } catch {
                log.error("index pass failed: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            try await Task.sleep(for: configuration.pollInterval)
        } catch {
            return false
        }
        return true
    }

    private func dueNotes() -> [NoteID] {
        let now = ContinuousClock.now
        let due = deadlines.filter { $0.value <= now }.map(\.key)
        for id in due { deadlines[id] = nil }
        return due.sorted { $0.uuidString < $1.uuidString }
    }

    /// Indexes everything currently queued, ignoring the debounce. Used by the
    /// app on "flush before quit" and by every test.
    @discardableResult
    public func drain() async throws -> IndexReport {
        let queued = deadlines.keys.sorted { $0.uuidString < $1.uuidString }
        deadlines.removeAll(keepingCapacity: true)
        guard !queued.isEmpty else { return IndexReport() }
        return try await index(notes: queued, reindexing: false)
    }

    // MARK: - Rebuilds

    /// The identifier every stored vector should carry.
    public nonisolated var modelID: String { embedder.identifier }

    /// Compares the active model against the one the index was built with.
    ///
    /// - Returns: `true` when they differ, in which case every vector for the
    ///   old model has been deleted and every note re-queued. The notes folder
    ///   is not re-read and nothing is re-chunked — the chunk text does not
    ///   depend on the model, only the vectors do.
    @discardableResult
    public func synchronizeModel() async throws -> Bool {
        let stored = try await metadata.meta(Self.modelMetaKey)
        guard stored != modelID else { return false }
        log.notice("""
            embedding model changed (\(stored ?? "none", privacy: .public) -> \
            \(self.modelID, privacy: .public)) — re-embedding the library
            """)
        let identifier = modelID
        try await metadata.writer.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE model_id <> ?", arguments: [identifier])
        }
        try await metadata.setMeta(Self.modelMetaKey, identifier)
        await vectors?.unload()
        markDirty(try await allNoteIDs())
        return true
    }

    /// Throws away the whole semantic index and rebuilds it.
    ///
    /// `Settings → Rebuild index` and the DoD's "rebuild completes on a 5k
    /// corpus" both land here.
    @discardableResult
    public func rebuildAll() async throws -> IndexReport {
        try await metadata.writer.write { db in
            try db.execute(sql: "DELETE FROM chunks")
        }
        try await metadata.setMeta(Self.modelMetaKey, modelID)
        await vectors?.unload()
        deadlines.removeAll(keepingCapacity: true)
        let ids = try await allNoteIDs()
        let report = try await index(notes: ids, reindexing: true)
        try await vectors?.reloadIfLoaded()
        return report
    }

    /// Indexes only the notes the database says are stale — missing chunks, a
    /// changed `content_hash`, or chunks with no vector for the active model.
    ///
    /// This is the launch path: cheap when nothing changed, and self-healing
    /// after a crash mid-index.
    @discardableResult
    public func catchUp(limit: Int = 5_000) async throws -> IndexReport {
        let ids = try await staleNoteIDs(limit: limit)
        guard !ids.isEmpty else { return IndexReport() }
        return try await index(notes: ids, reindexing: false)
    }

    /// Notes whose chunks are missing, stale, or unembedded for this model,
    /// **most recently modified first** (M4-07).
    ///
    /// Ordering is the whole point of this query on a first launch. A
    /// 20,000-note library takes about four minutes to index, and during that
    /// time semantic search only covers what is already embedded — so what is
    /// embedded first decides whether the wait is felt. People search for what
    /// they wrote last week, not for what they wrote in 2019, so `mtime DESC`
    /// puts the useful half of the library in the index within the first
    /// minute. Before this, the `UNION` returned rows in whatever order SQLite
    /// found convenient (in practice `notes.id` order, i.e. random UUIDs).
    ///
    /// `LIMIT` now applies to the ordered set rather than to the union arms,
    /// which is also what a caller passing `limit:` means.
    public func staleNoteIDs(limit: Int = 5_000) async throws -> [NoteID] {
        let identifier = modelID
        return try await metadata.reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT stale.id FROM (
                    SELECT n.id AS id FROM notes n
                    WHERE NOT EXISTS (
                        SELECT 1 FROM chunks c WHERE c.note_id = n.id AND c.source_hash = n.content_hash
                    )
                    UNION
                    SELECT DISTINCT c.note_id AS id FROM chunks c
                    WHERE NOT EXISTS (
                        SELECT 1 FROM embeddings e WHERE e.chunk_id = c.id AND e.model_id = ?
                    )
                ) stale
                JOIN notes n ON n.id = stale.id
                ORDER BY n.mtime DESC
                LIMIT ?
                """, arguments: [identifier, limit])
                .compactMap(NoteID.init)
        }
    }

    private func allNoteIDs() async throws -> [NoteID] {
        try await metadata.reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notes ORDER BY mtime DESC")
                .compactMap(NoteID.init)
        }
    }

    // MARK: - Indexing

    /// Indexes one note immediately, bypassing the queue. Returns `nil` when
    /// the note is unknown, excluded, or has no indexed text yet.
    @discardableResult
    public func index(noteID: NoteID) async throws -> IndexReport {
        deadlines[noteID] = nil
        return try await index(notes: [noteID], reindexing: false)
    }

    private func index(notes ids: [NoteID], reindexing: Bool) async throws -> IndexReport {
        guard !ids.isEmpty else { return IndexReport() }
        var report = IndexReport()
        let total = ids.count
        var completed = 0
        publish(reindexing ? .reindexing(completed: 0, total: total) : .indexing(completed: 0, total: total))
        defer { publish(.idle) }

        var offset = 0
        while offset < ids.count {
            try Task.checkCancellation()
            let batch = Array(ids[offset ..< min(offset + configuration.notesPerBatch, ids.count)])
            for source in try await sources(for: batch) {
                try Task.checkCancellation()
                report = report + (try await index(source))
                completed += 1
                publish(reindexing
                    ? .reindexing(completed: completed, total: total)
                    : .indexing(completed: completed, total: total))
                // M4-07: hand the actor back between notes. A 20,000-note
                // build owns this actor for close to four minutes, and every
                // `markDirty` an autosave sends — and every `status` the
                // progress row reads — would otherwise queue behind the whole
                // pass. One suspension per note costs microseconds and keeps
                // the mailbox draining while the build runs.
                await Task.yield()
            }
            // Notes the batch query did not return (deleted between queue and
            // read) still count as done.
            completed = min(total, max(completed, offset + batch.count))
            offset += batch.count
        }
        log.info("""
            indexed \(report.notesIndexed, privacy: .public) notes: \
            +\(report.chunksInserted, privacy: .public) chunks, \
            \(report.chunksReused, privacy: .public) reused, \
            -\(report.chunksDeleted, privacy: .public) removed, \
            \(report.embeddingsComputed, privacy: .public) embeddings
            """)
        return report
    }

    /// A note's identity and body, as one read.
    private struct Source: Sendable {
        let id: NoteID
        let relativePath: String
        let title: String
        let contentHash: String
        let body: String?
    }

    private func sources(for ids: [NoteID]) async throws -> [Source] {
        let strings = ids.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: strings.count).joined(separator: ", ")
        let rows: [Source] = try await metadata.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.id AS id, n.relpath AS relpath, n.title AS title,
                       n.content_hash AS content_hash, t.body AS body
                FROM notes n
                LEFT JOIN note_text t ON t.note_id = n.id
                WHERE n.id IN (\(placeholders))
                """, arguments: StatementArguments(strings))
                .compactMap { row in
                    guard let id = NoteID(row["id"] as String) else { return nil }
                    return Source(
                        id: id,
                        relativePath: row["relpath"],
                        title: row["title"],
                        contentHash: row["content_hash"],
                        body: row["body"]
                    )
                }
        }
        return rows
    }

    private func index(_ source: Source) async throws -> IndexReport {
        var report = IndexReport()

        // FR-4.5's excluded folders are also excluded from the *index*: nothing
        // in them is ever embedded, so nothing in them can be retrieved into a
        // prompt later.
        if isExcluded(source.relativePath) {
            let deleted = try await purge(noteID: source.id)
            report.notesPurged += 1
            report.chunksDeleted += deleted
            return report
        }

        guard let body = source.body ?? readBodyFromDisk(source) else {
            // The note has no indexed text yet (`rebuild(indexingText: false)`
            // is still catching up). Leave whatever is there and try again.
            report.notesSkipped += 1
            return report
        }

        let fresh = chunker.chunk(body, title: source.title)
        let existing = try await existingChunks(noteID: source.id)

        // Reuse by text hash, not by ordinal: inserting a paragraph at the top
        // renumbers every chunk but changes none of them.
        var spare: [String: [ExistingChunk]] = [:]
        for chunk in existing where chunk.hasVector {
            spare[chunk.textHash, default: []].append(chunk)
        }
        var reused: [(id: Int64, chunk: NoteChunk)] = []
        var novel: [NoteChunk] = []
        for chunk in fresh {
            if var candidates = spare[chunk.textHash], let match = candidates.popLast() {
                spare[chunk.textHash] = candidates
                reused.append((match.id, chunk))
            } else {
                novel.append(chunk)
            }
        }
        let keptIDs = Set(reused.map(\.id))
        let obsolete = existing.map(\.id).filter { !keptIDs.contains($0) }

        // Embedding is the slow part and must not hold the writer.
        var embeddings: [[Float]] = []
        if !novel.isEmpty {
            embeddings = try await embed(novel.map(\.text))
            guard embeddings.count == novel.count else {
                throw EmbedderError.emptyResult
            }
            report.embeddingsComputed += embeddings.count
        }

        let identifier = modelID
        let dimension = embedder.dimension
        let noteID = source.id.uuidString
        let sourceHash = source.contentHash
        // Immutable copies for the write closure: Swift 6 will not let a
        // concurrently-executing body capture a `var`.
        let reusedRows = reused
        let novelRows = novel
        let blobs = embeddings.map(HalfVector.encode)

        let inserted: [(Int64, NoteChunk)] = try await metadata.writer.write { db in
            // Every chunk of this note in one transaction (plan §3 M3-02).
            // Ordinals are unique per note, so the survivors are parked in the
            // negative range first and cannot collide with the new numbering.
            try db.execute(sql: "UPDATE chunks SET ordinal = -1 - ordinal WHERE note_id = ?", arguments: [noteID])
            for id in obsolete {
                try db.execute(sql: "DELETE FROM chunks WHERE id = ?", arguments: [id])
            }
            for (id, chunk) in reusedRows {
                try db.execute(sql: """
                    UPDATE chunks SET ordinal = ?, kind = ?, heading_path = ?, language = ?,
                                      range_start = ?, range_length = ?, source_hash = ?
                    WHERE id = ?
                    """, arguments: [
                        chunk.ordinal, chunk.kind.rawValue,
                        ChunkRow.encode(headingPath: chunk.headingPath), chunk.language,
                        chunk.range.location, chunk.range.length, sourceHash, id,
                    ])
            }
            var written: [(Int64, NoteChunk)] = []
            for (offset, chunk) in novelRows.enumerated() {
                try db.execute(sql: """
                    INSERT INTO chunks(note_id, ordinal, kind, heading_path, language,
                                       range_start, range_length, text_hash, source_hash, text)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        noteID, chunk.ordinal, chunk.kind.rawValue,
                        ChunkRow.encode(headingPath: chunk.headingPath), chunk.language,
                        chunk.range.location, chunk.range.length, chunk.textHash, sourceHash, chunk.text,
                    ])
                let id = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO embeddings(chunk_id, model_id, dim, vector) VALUES(?, ?, ?, ?)
                    ON CONFLICT(chunk_id, model_id) DO UPDATE SET dim = excluded.dim, vector = excluded.vector
                    """, arguments: [id, identifier, dimension, blobs[offset]])
                written.append((id, chunk))
            }
            return written
        }

        report.notesIndexed += 1
        report.chunksInserted += inserted.count
        report.chunksReused += reused.count
        report.chunksDeleted += obsolete.count

        if let vectors {
            await vectors.apply(
                upserts: inserted.enumerated().map { offset, entry in
                    VectorStore.Upsert(chunkID: entry.0, noteID: source.id, vector: embeddings[offset])
                },
                deletedChunkIDs: obsolete
            )
        }
        return report
    }

    private func embed(_ texts: [String]) async throws -> [[Float]] {
        guard texts.count > configuration.embedBatchSize else {
            return try await embedBatch(texts)
        }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        var offset = 0
        while offset < texts.count {
            try Task.checkCancellation()
            let slice = Array(texts[offset ..< min(offset + configuration.embedBatchSize, texts.count)])
            out.append(contentsOf: try await embedBatch(slice))
            offset += slice.count
        }
        return out
    }

    /// One embedder call, forced down to ``Configuration/workPriority``.
    ///
    /// Actor methods run at the *caller's* priority, so an indexer kicked off
    /// from a main-actor `Task` would embed at `.userInitiated` and fight the
    /// keystroke path for the Neural Engine. Detaching pins the QoS to the
    /// configuration instead of to whoever happened to call in, and it cannot
    /// deadlock because the closure touches only the (`Sendable`) embedder,
    /// never this actor.
    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        let embedder = self.embedder
        return try await Task.detached(priority: configuration.workPriority) {
            try await embedder.embed(texts)
        }.value
    }

    /// Last-resort body read, for a note the text index has not caught up with.
    private func readBodyFromDisk(_ source: Source) -> String? {
        let url = metadata.library.url(for: source.relativePath)
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return MarkdownDocument.parse(text).body
    }

    private struct ExistingChunk: Sendable {
        let id: Int64
        let textHash: String
        let hasVector: Bool
    }

    private func existingChunks(noteID: NoteID) async throws -> [ExistingChunk] {
        let identifier = modelID
        let id = noteID.uuidString
        return try await metadata.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id AS id, c.text_hash AS text_hash,
                       EXISTS(SELECT 1 FROM embeddings e WHERE e.chunk_id = c.id AND e.model_id = ?) AS has_vector
                FROM chunks c WHERE c.note_id = ? ORDER BY c.ordinal
                """, arguments: [identifier, id])
                .map { ExistingChunk(id: $0["id"], textHash: $0["text_hash"], hasVector: $0["has_vector"]) }
        }
    }

    /// Removes every chunk of a note (an exclusion, or an explicit purge).
    @discardableResult
    public func purge(noteID: NoteID) async throws -> Int {
        let id = noteID.uuidString
        let deleted = try await metadata.writer.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks WHERE note_id = ?", arguments: [id]) ?? 0
            try db.execute(sql: "DELETE FROM chunks WHERE note_id = ?", arguments: [id])
            return count
        }
        await vectors?.removeNotes([noteID])
        return deleted
    }

    // MARK: - Counts (bench and Settings)

    public func chunkCount() async throws -> Int {
        try await metadata.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
        }
    }

    public func embeddingCount() async throws -> Int {
        let identifier = modelID
        return try await metadata.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings WHERE model_id = ?", arguments: [identifier]) ?? 0
        }
    }
}

// MARK: - Row mapping

/// Reading and writing `chunks` rows. Shared by ``Indexer`` (which writes them)
/// and ``HybridSearch`` (which hydrates search results from them).
enum ChunkRow {
    /// Heading components are joined with U+001F INFORMATION SEPARATOR ONE — a
    /// control character no Markdown heading can contain, so the round trip is
    /// lossless without a JSON encode per chunk.
    static let separator = "\u{001F}"

    static func encode(headingPath: [String]) -> String {
        headingPath.joined(separator: separator)
    }

    static func decode(headingPath raw: String) -> [String] {
        raw.isEmpty ? [] : raw.components(separatedBy: separator)
    }

    static let columns = """
        c.id AS id, c.note_id AS note_id, c.ordinal AS ordinal, c.kind AS kind,
        c.heading_path AS heading_path, c.language AS language,
        c.range_start AS range_start, c.range_length AS range_length, c.text AS text
        """

    static func chunk(from row: Row) -> IndexedChunk? {
        guard let noteID = NoteID(row["note_id"] as String) else { return nil }
        return IndexedChunk(
            id: row["id"],
            noteID: noteID,
            ordinal: row["ordinal"],
            kind: ChunkKind(rawValue: row["kind"]) ?? .prose,
            headingPath: decode(headingPath: row["heading_path"] ?? ""),
            range: MatchRange(location: row["range_start"], length: row["range_length"]),
            language: row["language"],
            text: row["text"]
        )
    }

    static func fetch(_ db: Database, ids: [Int64]) throws -> [Int64: IndexedChunk] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        var out: [Int64: IndexedChunk] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT \(columns) FROM chunks c WHERE c.id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        ) {
            if let chunk = chunk(from: row) { out[chunk.id] = chunk }
        }
        return out
    }

    static func fetch(_ db: Database, noteIDs: [NoteID]) throws -> [NoteID: [IndexedChunk]] {
        guard !noteIDs.isEmpty else { return [:] }
        let strings = noteIDs.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: strings.count).joined(separator: ", ")
        var out: [NoteID: [IndexedChunk]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT \(columns) FROM chunks c WHERE c.note_id IN (\(placeholders)) ORDER BY c.ordinal",
            arguments: StatementArguments(strings)
        ) {
            if let chunk = chunk(from: row) { out[chunk.noteID, default: []].append(chunk) }
        }
        return out
    }
}

extension VectorStore {
    /// Rereads only if something already loaded the matrix — a rebuild should
    /// not force a lazy store into memory.
    func reloadIfLoaded() throws {
        guard loaded else { return }
        try reload()
    }
}
