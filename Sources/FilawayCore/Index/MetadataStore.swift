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

    /// Opens (creating if needed) the database for a library and migrates it.
    public init(library: Library) throws {
        self.library = library
        try FileManager.default.createDirectory(at: library.supportDirectory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: library.databaseURL.path, configuration: configuration)
        try Self.prepare(dbQueue, library: library)
    }

    /// In-memory database, for tests and for `filaway-bench`.
    public init(inMemoryFor library: Library) throws {
        self.library = library
        dbQueue = try DatabaseQueue()
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

    private static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }

    // MARK: - Rebuild

    /// Replaces the whole `notes`/`folders` content with a scan result.
    ///
    /// Idempotent: rebuilding twice from the same snapshot yields the same rows,
    /// which is what the "rebuild equivalence" test asserts.
    public func rebuild(from snapshot: LibrarySnapshot) throws {
        try dbQueue.write { db in
            var lastOpened: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, last_opened FROM notes WHERE last_opened IS NOT NULL") {
                lastOpened[row["id"]] = row["last_opened"]
            }
            try db.execute(sql: "DELETE FROM notes")
            try db.execute(sql: "DELETE FROM folders")
            for path in Self.impliedFolders(snapshot) {
                try Self.insertFolder(db, path: path)
            }
            for note in snapshot.notes {
                try Self.upsert(db, note, lastOpened: lastOpened[note.id.uuidString])
            }
            try Self.setMeta(db, "last_scan", ISO8601.string(from: snapshot.scannedAt))
        }
    }

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
        try dbQueue.write { db in try Self.upsert(db, note, lastOpened: nil) }
    }

    /// Inserts or updates several notes in one transaction.
    public func upsert(_ notes: [NoteSummary]) throws {
        try dbQueue.write { db in
            for note in notes { try Self.upsert(db, note, lastOpened: nil) }
        }
    }

    /// Removes a note row by relative path.
    public func remove(relativePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE relpath = ?", arguments: [PathRules.normalize(relativePath)])
        }
    }

    /// Removes a note row by identity.
    public func remove(id: NoteID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
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
    public func apply(_ changes: [LibraryChange]) throws {
        try dbQueue.write { db in
            for change in changes {
                switch change {
                case let .added(note), let .modified(note):
                    try Self.upsert(db, note, lastOpened: nil)
                case let .moved(from, _, note):
                    try db.execute(sql: "DELETE FROM notes WHERE relpath = ?", arguments: [from])
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
