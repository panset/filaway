import Foundation
import GRDB

/// The durable offline queue (FR-6.4, M2-09).
///
/// ``InMemoryPendingSessionStore`` is correct but forgetful: quit the app while
/// the network is down and the session that was waiting for it is gone, along
/// with the filing pass it stood for. This is the same contract over
/// `pending_sessions` in `filaway.sqlite` (migration `v5-pending-sessions`), so
/// a queued session survives a relaunch and is retried when health comes back.
///
/// It follows ``ActivityLog``'s pattern exactly (ADR-027): its own
/// `DatabaseQueue` on the shared file, WAL, and a busy timeout, because three
/// connections now share `filaway.sqlite` and none of them may take GRDB's
/// default "fail immediately if busy" stance.
///
/// Losing the queue costs a filing pass, never a keystroke — so every failure
/// here is survivable, and the organizer already treats the store as
/// best-effort (`try?` at every call site).
public actor PendingSessionStoreGRDB: PendingSessionStore {
    public let library: Library
    private let dbQueue: DatabaseQueue

    public init(library: Library) throws {
        self.library = library
        try FileManager.default.createDirectory(at: library.supportDirectory, withIntermediateDirectories: true)
        let opened = try DatabaseFile.open(at: library.databaseURL, configuration: Self.configuration()) { queue in
            try DatabaseSchema.migrator.migrate(queue)
        }
        dbQueue = opened.queue
    }

    /// In-memory database, for tests and previews.
    public init(inMemoryFor library: Library) throws {
        self.library = library
        dbQueue = try DatabaseQueue(configuration: Self.configuration())
        try DatabaseSchema.migrator.migrate(dbQueue)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try? db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return configuration
    }

    // MARK: - PendingSessionStore

    public func enqueue(_ session: PendingSession) throws {
        let noteIDs = String(decoding: try JSONEncoder().encode(session.noteIDs.map(\.uuidString)), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_sessions
                        (id, note_ids, started_at, ended_at, reason, attempts, last_error, next_attempt_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        note_ids = excluded.note_ids,
                        started_at = excluded.started_at,
                        ended_at = excluded.ended_at,
                        reason = excluded.reason,
                        attempts = excluded.attempts,
                        last_error = excluded.last_error,
                        next_attempt_at = excluded.next_attempt_at
                    """,
                arguments: [
                    session.id.uuidString, noteIDs,
                    session.startedAt.timeIntervalSince1970, session.endedAt.timeIntervalSince1970,
                    session.reason.rawValue, session.attempts, session.lastError,
                    session.nextAttemptAt?.timeIntervalSince1970,
                ]
            )
        }
    }

    public func remove(_ id: SessionID) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_sessions WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Everything queued, oldest first.
    public func all() throws -> [PendingSession] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, note_ids, started_at, ended_at, reason, attempts, last_error, next_attempt_at
                FROM pending_sessions ORDER BY ended_at ASC, id ASC
                """)
                .compactMap(Self.pending(from:))
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_sessions") ?? 0 }
    }

    /// Drops everything. Settings → "Forget queued sessions", and tests.
    public func removeAll() throws {
        _ = try dbQueue.write { db in try db.execute(sql: "DELETE FROM pending_sessions") }
    }

    private static func pending(from row: Row) -> PendingSession? {
        guard let idString: String = row["id"], let id = SessionID(idString),
              let reasonRaw: String = row["reason"], let reason = SessionEndReason(rawValue: reasonRaw)
        else { return nil }
        let noteIDs: [NoteID] = {
            guard let json: String = row["note_ids"],
                  let raw = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
            else { return [] }
            return raw.compactMap(NoteID.init)
        }()
        let nextAttempt: Double? = row["next_attempt_at"]
        return PendingSession(
            id: id,
            noteIDs: noteIDs,
            startedAt: Date(timeIntervalSince1970: row["started_at"] ?? 0),
            endedAt: Date(timeIntervalSince1970: row["ended_at"] ?? 0),
            reason: reason,
            attempts: row["attempts"] ?? 0,
            lastError: row["last_error"],
            nextAttemptAt: nextAttempt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
