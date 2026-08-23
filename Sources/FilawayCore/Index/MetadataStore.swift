import Foundation
import GRDB

/// A note as the sidebar's **Recents** section needs it (FR-1.2).
public struct RecentNote: Sendable, Equatable, Identifiable {
    public var id: NoteID { note.id }
    public let note: NoteSummary
    public let lastOpened: Date?
    /// `max(lastOpened, mtime)` — plan §1 amendment 7.
    public var sortDate: Date { max(lastOpened ?? .distantPast, note.modified) }

    public init(note: NoteSummary, lastOpened: Date?) {
        self.note = note
        self.lastOpened = lastOpened
    }
}

/// One row of the `folders` table.
public struct FolderInfo: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let parentPath: String?
    public let depth: Int

    public init(path: String, name: String, parentPath: String?, depth: Int) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.depth = depth
    }
}

/// The derived metadata database (DS-3).
///
/// Lives at `~/Library/Application Support/Filaway/<libraryKey>/filaway.sqlite`
/// and holds nothing the notes folder does not already imply — deleting it
/// costs a rebuild, not data. `last_opened` is the one exception: it is a UI
/// convenience with no file representation, so ``rebuild(from:)`` carries it
/// across by note `id`.
///
/// ```swift
/// let metadata = try MetadataStore(library: library)
/// try await metadata.rebuild(from: store.scan())
/// let recents = try await metadata.recents(limit: 10)
/// ```
public actor MetadataStore {
    public let library: Library
    private let dbQueue: DatabaseQueue
    private let textLoader: NoteTextLoader

    /// A read handle onto the same database, usable off this actor.
    ///
    /// ``SearchService`` holds it so a keystroke's query never has to queue
    /// behind the writer's actor mailbox (M1-06). GRDB still serialises the two
    /// on one connection, so search reads are deliberately kept to a few
    /// milliseconds; the upgrade path, if that ever bites, is WAL + a
    /// `DatabasePool`.
    public nonisolated var reader: any DatabaseReader { dbQueue }

    /// A write handle onto the same database, for subsystems that own their own
    /// tables and their own transaction shapes.
    ///
    /// ``Indexer`` (M3-02) writes `chunks`/`embeddings` through this: it must
    /// batch, cancel and back off on its own schedule, and routing that through
    /// this actor's mailbox would put a 5,000-note reindex in front of every
    /// autosave. GRDB still serialises the two on one connection, so the rule
    /// for anyone using this is the same as for ``reader``: keep each
    /// transaction short.
    public nonisolated var writer: any DatabaseWriter { dbQueue }

    /// Opens (creating if needed) the database for a library and migrates it.
    ///
    /// - Parameter textLoader: how the store fetches a note's body when it needs
    ///   to (re)index it for search. Defaults to reading the file and stripping
    ///   front matter; pass ``NoteTextLoader/none`` to keep the text index out
    ///   of the write path entirely.
    public init(library: Library, textLoader: NoteTextLoader? = nil) throws {
        self.library = library
        self.textLoader = textLoader ?? .reading(from: library)
        try FileManager.default.createDirectory(at: library.supportDirectory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // Three connections share `filaway.sqlite` (this one, ``ActivityLog``'s
        // and ``PendingSessionStoreGRDB``'s). GRDB's default busy mode is
        // `.immediateError`, which would surface normal contention as an error
        // — ADR-027 noted this as the one-line change the integration pass owes.
        configuration.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: library.databaseURL.path, configuration: configuration)
        try Self.prepare(dbQueue, library: library)
    }

    /// In-memory database, for tests and for `filaway-bench`.
    public init(inMemoryFor library: Library, textLoader: NoteTextLoader? = nil) throws {
        self.library = library
        self.textLoader = textLoader ?? .reading(from: library)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // Three connections share `filaway.sqlite` (this one, ``ActivityLog``'s
        // and ``PendingSessionStoreGRDB``'s). GRDB's default busy mode is
        // `.immediateError`, which would surface normal contention as an error
        // — ADR-027 noted this as the one-line change the integration pass owes.
        configuration.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(configuration: configuration)
        try Self.prepare(dbQueue, library: library)
    }

    private static func prepare(_ queue: DatabaseQueue, library: Library) throws {
        try DatabaseSchema.migrator.migrate(queue)
        try queue.write { db in
            try setMeta(db, "schema_version", String(DatabaseSchema.version))
            try setMeta(db, "library_key", library.key)
            try setMeta(db, "library_root", library.root.path)
        }
    }

    // MARK: - Meta

    /// Schema version recorded in `meta`; `0` when never written.
    public func schemaVersion() throws -> Int {
        try dbQueue.read { db in
            Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'") ?? "0") ?? 0
        }
    }

    /// Reads an arbitrary `meta` value.
    public func meta(_ key: String) throws -> String? {
        try dbQueue.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    /// Writes an arbitrary `meta` value.
    public func setMeta(_ key: String, _ value: String) throws {
        try dbQueue.write { db in try Self.setMeta(db, key, value) }
    }

    /// Bumps the counter that tells readers the `notes` table changed.
    ///
    /// A rename or a move changes neither the row count nor any mtime, so a
    /// digest of the table cannot see it — but ``SearchService``'s title cache
    /// has to. Every write path through this store bumps this instead.
    private static func bumpGeneration(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO meta(key, value) VALUES('notes_generation', '1')
            ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
            """)
    }

    /// Increments on every change to `notes`; readers cache against it.
    public func generation() throws -> Int {
        try dbQueue.read { db in
            Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'notes_generation'") ?? "0") ?? 0
        }
    }

    private static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }

    // MARK: - Rebuild

    /// Replaces the whole `notes`/`folders` content with a scan result.
    ///
    /// Idempotent: rebuilding twice from the same snapshot yields the same rows,
    /// which is what the "rebuild equivalence" test asserts.
    ///
    /// - Parameter indexingText: also rebuild the search index (M1-06), which
    ///   means reading every note's body off disk. `false` leaves the index
    ///   empty and defers the work to ``indexText(_:)`` /
    ///   ``staleTextNotes(limit:)`` — use it when the caller wants the sidebar
    ///   on screen before search is ready.
    public func rebuild(from snapshot: LibrarySnapshot, indexingText: Bool = true) throws {
        try dbQueue.write { db in
            var lastOpened: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, last_opened FROM notes WHERE last_opened IS NOT NULL") {
                lastOpened[row["id"]] = row["last_opened"]
            }
            // Bulk load: the triggers would fire once per row, where FTS5's own
            // 'rebuild' does the whole index in a single pass.
            try Self.dropFTSTriggers(db)
            try db.execute(sql: "DELETE FROM note_text")
            try Self.clearFTS(db)
            try db.execute(sql: "DELETE FROM notes")
            try db.execute(sql: "DELETE FROM folders")
            for path in Self.impliedFolders(snapshot) {
                try Self.insertFolder(db, path: path)
            }
            for note in snapshot.notes {
                try Self.upsert(db, note, lastOpened: lastOpened[note.id.uuidString])
            }
            try Self.setMeta(db, "last_scan", ISO8601.string(from: snapshot.scannedAt))
            try Self.bumpGeneration(db)
        }

        // Bodies are read off-transaction, in batches, so neither the write lock
        // nor memory is held for the whole library.
        var indexingError: Error?
        if indexingText {
            do {
                var index = 0
                while index < snapshot.notes.count {
                    let batch = Array(snapshot.notes[index ..< min(index + Self.indexBatchSize, snapshot.notes.count)])
                    let texts = batch.compactMap(loadText(for:))
                    try dbQueue.write { db in
                        for text in texts { try Self.insertText(db, text) }
                    }
                    index += batch.count
                }
            } catch {
                indexingError = error
            }
        }

        try dbQueue.write { db in
            try Self.rebuildFTS(db)
            try Self.createFTSTriggers(db)
        }
        if let indexingError { throw indexingError }
    }

    /// How many notes' bodies are held in memory at once while indexing.
    private static let indexBatchSize = 512

    /// All folder paths implied by a snapshot, including ancestors of notes.
    static func impliedFolders(_ snapshot: LibrarySnapshot) -> [String] {
        var paths = Set(snapshot.folderPaths.map(PathRules.normalize))
        for note in snapshot.notes where !note.folderPath.isEmpty {
            var current = note.folderPath
            while !current.isEmpty {
                paths.insert(current)
                current = PathRules.parent(of: current) ?? ""
            }
        }
        paths.remove("")
        return paths.sorted()
    }

    // MARK: - Notes

    /// Inserts or updates one note, keyed by ``NoteID``.
    public func upsert(_ note: NoteSummary) throws {
        try upsert([note])
    }

    /// Inserts or updates several notes in one transaction, refreshing their
    /// search index entries.
    public func upsert(_ notes: [NoteSummary]) throws {
        let texts = loadTexts(for: notes)
        try dbQueue.write { db in
            for note in notes { try Self.upsert(db, note, lastOpened: nil) }
            for text in texts { try Self.insertText(db, text) }
            try Self.bumpGeneration(db)
        }
    }

    /// Removes a note row by relative path.
    public func remove(relativePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE relpath = ?", arguments: [PathRules.normalize(relativePath)])
            try Self.bumpGeneration(db)
        }
    }

    /// Removes a note row by identity.
    public func remove(id: NoteID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
            try Self.bumpGeneration(db)
        }
    }

    /// Every note, ordered by relative path.
    public func allNotes() throws -> [NoteSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY relpath").map(Self.summary(from:))
        }
    }

    public func note(id: NoteID) throws -> NoteSummary? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE id = ?", arguments: [id.uuidString]).map(Self.summary(from:))
        }
    }

    public func note(relativePath: String) throws -> NoteSummary? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE relpath = ?", arguments: [PathRules.normalize(relativePath)])
                .map(Self.summary(from:))
        }
    }

    /// Rows for a set of relative paths — the targeted-reconcile lookup, so a
    /// live FSEvents batch does not read the whole table.
    public func notes(relativePaths: Set<String>) throws -> [NoteSummary] {
        guard !relativePaths.isEmpty else { return [] }
        let paths = relativePaths.map(PathRules.normalize)
        let placeholders = databaseQuestionMarks(paths.count)
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM notes WHERE relpath IN (\(placeholders))",
                arguments: StatementArguments(paths)
            ).map(Self.summary(from:))
        }
    }

    /// `true` when the `folders` table already knows this path.
    public func folderExists(_ path: String) throws -> Bool {
        let folder = PathRules.normalize(path)
        guard !folder.isEmpty else { return true }
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM folders WHERE path = ?", arguments: [folder]) != nil
        }
    }

    private func databaseQuestionMarks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Notes in one folder, ordered by title.
    public func notes(inFolder folderPath: String) throws -> [NoteSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes WHERE folder_path = ? ORDER BY title",
                             arguments: [PathRules.normalize(folderPath)]).map(Self.summary(from:))
        }
    }

    public func noteCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0 }
    }

    /// Semantic chunks currently stored, for the whole library or for the notes
    /// under one folder (M4-02).
    ///
    /// The observable half of FR-4.5: excluding a folder has to *remove* what
    /// was already indexed, and "the chunks are gone" is the only statement of
    /// that a test can make without reading the model's mind.
    public func chunkCount(inFolder folderPath: String? = nil) throws -> Int {
        try dbQueue.read { db in
            guard let folderPath else {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            }
            let normalized = PathRules.normalize(folderPath)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chunks c JOIN notes n ON n.id = c.note_id
                WHERE n.folder_path = ? OR n.folder_path LIKE ?
                """, arguments: [normalized, normalized + "/%"]) ?? 0
        }
    }

    // MARK: - Recents (FR-1.2)

    /// Records that the user opened a note. Feeds the Recents ordering.
    public func markOpened(id: NoteID, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE notes SET last_opened = ? WHERE id = ?",
                           arguments: [date.timeIntervalSince1970, id.uuidString])
        }
    }

    /// Recents: newest first by `max(lastOpened, mtime)`, capped (FR-1.2 says
    /// "~10"). Purely chronological — never reordered by the AI.
    public func recents(limit: Int = 10) throws -> [RecentNote] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM notes
                ORDER BY MAX(COALESCE(last_opened, 0), mtime) DESC, relpath ASC
                LIMIT ?
                """,
                arguments: [limit]
            ).map { row in
                RecentNote(
                    note: Self.summary(from: row),
                    lastOpened: (row["last_opened"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    // MARK: - Folders

    /// Adds a folder row (and its ancestors) if missing.
    public func addFolder(_ path: String) throws {
        try dbQueue.write { db in
            var chain: [String] = []
            var current = PathRules.normalize(path)
            while !current.isEmpty {
                chain.append(current)
                current = PathRules.parent(of: current) ?? ""
            }
            for folder in chain.reversed() { try Self.insertFolder(db, path: folder) }
        }
    }

    /// Removes a folder row and everything beneath it, notes included.
    public func removeFolder(_ path: String) throws {
        let folder = PathRules.normalize(path)
        guard !folder.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM folders WHERE path = ? OR path LIKE ?", arguments: [folder, folder + "/%"])
            try db.execute(sql: "DELETE FROM notes WHERE folder_path = ? OR folder_path LIKE ?",
                           arguments: [folder, folder + "/%"])
            try Self.bumpGeneration(db)
        }
    }

    public func folders() throws -> [FolderInfo] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY path").map { row in
                FolderInfo(path: row["path"], name: row["name"], parentPath: row["parent_path"], depth: row["depth"])
            }
        }
    }

    /// The Library tree, rebuilt from the database alone (no disk access).
    public func tree() throws -> Folder {
        Folder.tree(notes: try allNotes(), folderPaths: try folders().map(\.path))
    }

    /// Everything the database knows, in ``LibrarySnapshot`` shape — used by the
    /// reconciler to diff disk against the last known state.
    public func snapshot() throws -> LibrarySnapshot {
        LibrarySnapshot(
            notes: try allNotes(),
            folderPaths: try folders().map(\.path),
            scannedAt: (try meta("last_scan")).flatMap(ISO8601.date(from:)) ?? .distantPast
        )
    }

    // MARK: - Applying reconciler output

    /// Applies a batch of ``LibraryChange`` values in one transaction.
    ///
    /// The search index follows: added/modified/moved notes are re-read and
    /// re-indexed, and removals unindex themselves through `note_text`'s
    /// cascading foreign key.
    public func apply(_ changes: [LibraryChange]) throws {
        var touched: [NoteSummary] = []
        // A move keeps the note's bytes, so its content hash is unchanged and
        // the "already indexed" check would skip it — but its row is about to
        // be deleted and reinserted at the new path, and its title may have
        // changed with the filename. Moves are therefore always reloaded.
        var moved: Set<String> = []
        for change in changes {
            switch change {
            case let .added(note), let .modified(note):
                touched.append(note)
            case let .moved(_, _, note):
                touched.append(note)
                moved.insert(note.id.uuidString)
            case .removed, .conflict, .folderAdded, .folderRemoved:
                break
            }
        }
        let texts = loadTexts(for: touched, reloading: moved)
        try dbQueue.write { db in
            for change in changes {
                switch change {
                case let .added(note), let .modified(note):
                    try Self.upsert(db, note, lastOpened: nil)
                case let .moved(from, _, note):
                    // Guarded by id: the row at the old path *is* this note, and
                    // deleting it would cascade its indexed text away.
                    try db.execute(sql: "DELETE FROM notes WHERE relpath = ? AND id <> ?",
                                   arguments: [from, note.id.uuidString])
                    try Self.upsert(db, note, lastOpened: nil)
                case let .removed(relativePath, _):
                    try db.execute(sql: "DELETE FROM notes WHERE relpath = ?", arguments: [relativePath])
                case let .folderAdded(path):
                    try Self.insertFolder(db, path: path)
                case let .folderRemoved(path):
                    try db.execute(sql: "DELETE FROM folders WHERE path = ? OR path LIKE ?", arguments: [path, path + "/%"])
                    try db.execute(sql: "DELETE FROM notes WHERE folder_path = ? OR folder_path LIKE ?",
                                   arguments: [path, path + "/%"])
                case .conflict:
                    break  // the copy itself arrives as a separate `.added`
                }
            }
            for text in texts { try Self.insertText(db, text) }
            try Self.bumpGeneration(db)
        }
    }

    // MARK: - Search text index (M1-06, FR-5.1)

    /// Inserts or refreshes the searchable text of the given notes.
    ///
    /// Only needed by callers that construct bodies themselves (an importer, or
    /// a background catch-up after `rebuild(from:indexingText: false)`); the
    /// ordinary write paths index automatically.
    public func indexText(_ entries: [NoteText]) throws {
        guard !entries.isEmpty else { return }
        try dbQueue.write { db in
            for entry in entries { try Self.insertText(db, entry) }
        }
    }

    /// How many notes currently have searchable text.
    public func textIndexCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_text") ?? 0 }
    }

    /// Notes whose text is missing from the index or was indexed from different
    /// bytes — the work list for a background catch-up.
    public func staleTextNotes(limit: Int = 1_000) throws -> [NoteSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT notes.* FROM notes
                LEFT JOIN note_text ON note_text.note_id = notes.id
                WHERE note_text.note_id IS NULL OR note_text.content_hash <> notes.content_hash
                ORDER BY notes.mtime DESC
                LIMIT ?
                """, arguments: [limit]).map(Self.summary(from:))
        }
    }

    /// The indexed text of one note, front matter stripped.
    public func text(id: NoteID) throws -> NoteText? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM note_text WHERE note_id = ?", arguments: [id.uuidString])
                .map(Self.noteText(from:))
        }
    }

    /// Reads the bodies of notes whose indexed hash no longer matches.
    ///
    /// - Parameter reloading: note ids to re-read even when the hash matches.
    private func loadTexts(for notes: [NoteSummary], reloading: Set<String> = []) -> [NoteText] {
        guard !notes.isEmpty else { return [] }
        let known: [String: String]
        do {
            let ids = notes.map(\.id.uuidString)
            let placeholders = databaseQuestionMarks(ids.count)
            known = try dbQueue.read { db in
                var map: [String: String] = [:]
                for row in try Row.fetchAll(
                    db,
                    sql: "SELECT note_id, content_hash FROM note_text WHERE note_id IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                ) {
                    map[row["note_id"]] = row["content_hash"]
                }
                return map
            }
        } catch {
            known = [:]
        }
        return notes.compactMap { note in
            let id = note.id.uuidString
            guard reloading.contains(id) || known[id] != note.contentHash else { return nil }
            return loadText(for: note)
        }
    }

    private func loadText(for note: NoteSummary) -> NoteText? {
        guard let body = textLoader.load(note) else { return nil }
        return NoteText(
            id: note.id,
            relativePath: note.relativePath,
            title: note.title,
            body: body,
            contentHash: note.contentHash
        )
    }

    private static func insertText(_ db: Database, _ text: NoteText) throws {
        try db.execute(
            sql: """
            INSERT INTO note_text(note_id, relpath, title, body, content_hash) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(note_id) DO UPDATE SET
                relpath = excluded.relpath,
                title = excluded.title,
                body = excluded.body,
                content_hash = excluded.content_hash
            """,
            arguments: [text.id.uuidString, text.relativePath, text.title, text.body, text.contentHash]
        )
    }

    private static func noteText(from row: Row) -> NoteText {
        NoteText(
            id: NoteID(row["note_id"] as String) ?? NoteID(),
            relativePath: row["relpath"],
            title: row["title"],
            body: row["body"],
            contentHash: row["content_hash"]
        )
    }

    private static func dropFTSTriggers(_ db: Database) throws {
        for name in DatabaseSchema.ftsTriggerNames {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)")
        }
    }

    private static func createFTSTriggers(_ db: Database) throws {
        try dropFTSTriggers(db)
        for sql in DatabaseSchema.ftsTriggerStatements { try db.execute(sql: sql) }
    }

    private static func clearFTS(_ db: Database) throws {
        for table in DatabaseSchema.ftsTables {
            try db.execute(sql: "INSERT INTO \(table)(\(table)) VALUES('delete-all')")
        }
    }

    private static func rebuildFTS(_ db: Database) throws {
        for table in DatabaseSchema.ftsTables {
            try db.execute(sql: "INSERT INTO \(table)(\(table)) VALUES('rebuild')")
        }
    }

    // MARK: - Row mapping

    private static func upsert(_ db: Database, _ note: NoteSummary, lastOpened: Double?) throws {
        // A note that moved keeps its id, so clear any stale row at the new path.
        try db.execute(sql: "DELETE FROM notes WHERE relpath = ? AND id <> ?",
                       arguments: [note.relativePath, note.id.uuidString])
        try db.execute(
            sql: """
            INSERT INTO notes(id, relpath, folder_path, title, content_hash, mtime, size, created, last_opened, tags)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                relpath = excluded.relpath,
                folder_path = excluded.folder_path,
                title = excluded.title,
                content_hash = excluded.content_hash,
                mtime = excluded.mtime,
                size = excluded.size,
                created = excluded.created,
                tags = excluded.tags
            """,
            arguments: [
                note.id.uuidString,
                note.relativePath,
                note.folderPath,
                note.title,
                note.contentHash,
                note.modified.timeIntervalSince1970,
                note.size,
                note.created.timeIntervalSince1970,
                lastOpened,
                encodeTags(note.tags),
            ]
        )
        if !note.folderPath.isEmpty {
            var current = note.folderPath
            var chain: [String] = []
            while !current.isEmpty {
                chain.append(current)
                current = PathRules.parent(of: current) ?? ""
            }
            for folder in chain.reversed() { try insertFolder(db, path: folder) }
        }
    }

    private static func insertFolder(_ db: Database, path: String) throws {
        let normalized = PathRules.normalize(path)
        guard !normalized.isEmpty else { return }
        try db.execute(
            sql: """
            INSERT INTO folders(path, name, parent_path, depth) VALUES(?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET name = excluded.name, parent_path = excluded.parent_path, depth = excluded.depth
            """,
            arguments: [
                normalized,
                PathRules.name(of: normalized),
                PathRules.parent(of: normalized),
                PathRules.depth(ofFolder: normalized),
            ]
        )
    }

    private static func summary(from row: Row) -> NoteSummary {
        NoteSummary(
            id: NoteID(row["id"] as String) ?? NoteID(),
            relativePath: row["relpath"],
            title: row["title"],
            folderPath: row["folder_path"],
            tags: decodeTags(row["tags"]),
            created: Date(timeIntervalSince1970: row["created"]),
            modified: Date(timeIntervalSince1970: row["mtime"]),
            size: row["size"],
            contentHash: row["content_hash"]
        )
    }

    static func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeTags(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
