import Foundation
import GRDB

/// The Activity log and the apply journal — one table, two jobs (FR-4.3,
/// FR-4.4, NFR-3).
///
/// Every organization event is a row in `activity_events` written **before**
/// ``PlanApplier`` touches a file and completed once the after-images are
/// durable. That is what makes the log a journal: a row still marked
/// ``ActivityEventStatus/inProgress`` at launch means a crash mid-apply, and
/// ``PlanApplier/recoverIncompleteEvents()`` has everything it needs to put the
/// files back.
///
/// ```swift
/// let activity = try ActivityLog(library: library)
/// let page = try await activity.events(limit: 25)             // newest first
/// let diffs = try await activity.diff(for: page[0].id)        // per-note diffs
/// try await activity.prune(olderThan: 30 * 86_400)            // FR-4.4 retention
/// ```
///
/// It lives in the same `filaway.sqlite` as ``MetadataStore`` (migration
/// `v4-activity`) but holds its own connection, configured with a busy timeout
/// and WAL so the two never fight over the file.
public actor ActivityLog {
    public let library: Library
    private let dbQueue: DatabaseQueue

    /// FR-4.4: raw session text is recoverable for at least 30 days.
    public static let sessionTextRetention: TimeInterval = 30 * 24 * 60 * 60
    /// FR-4.3: Undo reaches at least the last 10 organization events.
    public static let undoDepth = 10

    public init(library: Library) throws {
        self.library = library
        try FileManager.default.createDirectory(at: library.supportDirectory, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: library.databaseURL.path, configuration: Self.configuration())
        try DatabaseSchema.migrator.migrate(dbQueue)
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
        // Two connections share `filaway.sqlite` (this one and MetadataStore's),
        // so neither may take the default "fail immediately if busy" stance.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            // WAL is a file-level setting: switching it on here lets
            // MetadataStore's readers run while the log writes.
            try? db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        return configuration
    }

    // MARK: - Writing

    /// Opens an event. For an apply this is the journal record: written before
    /// the first file operation, with the before-images already in it.
    @discardableResult
    public func begin(
        id: ActivityEventID = ActivityEventID(),
        kind: ActivityEventKind,
        status: ActivityEventStatus,
        summary: String,
        plan: OrganizationPlan? = nil,
        sessionText: String? = nil,
        images: [NoteImage] = [],
        isUndoable: Bool = false,
        at timestamp: Date = Date()
    ) throws -> ActivityEventID {
        let planJSON = try plan.map { try Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO activity_events
                        (id, created_at, kind, status, summary, prompt_version, model,
                         plan_json, session_text, progress_json, undoable, undone_by, detail)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, '')
                    """,
                arguments: [
                    id.uuidString, timestamp.timeIntervalSince1970, kind.rawValue, status.rawValue,
                    summary, plan?.promptVersion.description, plan?.model,
                    planJSON, sessionText, isUndoable ? 1 : 0,
                ]
            )
            try Self.writeImages(db, eventID: id, images: images)
        }
        return id
    }

    /// Records a plan the user dismissed (ask mode). Nothing touched the disk,
    /// but FR-4.3 asks the log to list *all* AI actions.
    @discardableResult
    public func recordDismissed(
        plan: OrganizationPlan,
        summary: String? = nil,
        sessionText: String? = nil,
        at timestamp: Date = Date()
    ) throws -> ActivityEventID {
        try begin(
            kind: .proposedDismissed,
            status: .none,
            summary: summary ?? plan.summary,
            plan: plan,
            sessionText: sessionText,
            images: [],
            isUndoable: false,
            at: timestamp
        )
    }

    /// Replaces an event's images — the applier calls this with the after-images
    /// once every file operation has landed, *before* the status flips to
    /// ``ActivityEventStatus/applied``. The order matters: an event whose images
    /// are all complete can be rolled *forward* by recovery.
    public func setImages(_ images: [NoteImage], for id: ActivityEventID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM activity_note_images WHERE event_id = ?", arguments: [id.uuidString])
            try Self.writeImages(db, eventID: id, images: images)
        }
    }

    /// Journal progress: what the applier has actually done so far, as JSON.
    public func setProgress(_ json: String?, for id: ActivityEventID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE activity_events SET progress_json = ? WHERE id = ?",
                arguments: [json, id.uuidString]
            )
        }
    }

    public func progressJSON(for id: ActivityEventID) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT progress_json FROM activity_events WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Marks how an event ended.
    public func setStatus(
        _ status: ActivityEventStatus,
        for id: ActivityEventID,
        isUndoable: Bool? = nil,
        summary: String? = nil,
        detail: String? = nil
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE activity_events
                       SET status = ?,
                           undoable = COALESCE(?, undoable),
                           summary = COALESCE(?, summary),
                           detail = COALESCE(?, detail)
                     WHERE id = ?
                    """,
                arguments: [status.rawValue, isUndoable.map { $0 ? 1 : 0 }, summary, detail, id.uuidString]
            )
        }
    }

    /// Records an undo: its own event row, the `undo_events` link, and the
    /// original event marked reversed and no longer undoable (redo is out of
    /// scope for Phase 1).
    @discardableResult
    public func recordUndo(
        of eventID: ActivityEventID,
        undoEventID: ActivityEventID = ActivityEventID(),
        summary: String,
        images: [NoteImage],
        outcome: String,
        detail: String = "",
        at timestamp: Date = Date()
    ) throws -> ActivityEventID {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO activity_events
                        (id, created_at, kind, status, summary, prompt_version, model,
                         plan_json, session_text, progress_json, undoable, undone_by, detail)
                    VALUES (?, ?, 'undone', 'applied', ?, NULL, NULL, NULL, NULL, NULL, 0, NULL, ?)
                    """,
                arguments: [undoEventID.uuidString, timestamp.timeIntervalSince1970, summary, detail]
            )
            try Self.writeImages(db, eventID: undoEventID, images: images)
            try db.execute(
                sql: "INSERT INTO undo_events (id, event_id, created_at, outcome, detail) VALUES (?, ?, ?, ?, ?)",
                arguments: [undoEventID.uuidString, eventID.uuidString, timestamp.timeIntervalSince1970, outcome, detail]
            )
            try db.execute(
                sql: "UPDATE activity_events SET status = 'undone', undoable = 0, undone_by = ? WHERE id = ?",
                arguments: [undoEventID.uuidString, eventID.uuidString]
            )
        }
        return undoEventID
    }

    // MARK: - Reading

    /// One page of the Activity list, newest first.
    ///
    /// Images are **not** loaded — a page of note text would be megabytes. Use
    /// ``event(_:)`` or ``images(for:)`` for the row the user opened.
    public func events(limit: Int = 25, before cursor: ActivityCursor? = nil) throws -> [ActivityEvent] {
        try dbQueue.read { db in
            let rows: [Row]
            if let cursor {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM activity_events
                         WHERE created_at < ? OR (created_at = ? AND id < ?)
                         ORDER BY created_at DESC, id DESC LIMIT ?
                        """,
                    arguments: [
                        cursor.timestamp.timeIntervalSince1970, cursor.timestamp.timeIntervalSince1970,
                        cursor.id.uuidString, limit,
                    ]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM activity_events ORDER BY created_at DESC, id DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            return try rows.map { try Self.event(from: $0, db: db, includingImages: false) }
        }
    }

    /// One event with its before/after images.
    public func event(_ id: ActivityEventID) throws -> ActivityEvent? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM activity_events WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            return try Self.event(from: row, db: db, includingImages: true)
        }
    }

    public func images(for id: ActivityEventID) throws -> [NoteImage] {
        try dbQueue.read { db in try Self.images(db, eventID: id) }
    }

    /// The raw session text, while retention keeps it (FR-4.4).
    public func sessionText(for id: ActivityEventID) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT session_text FROM activity_events WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func eventCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity_events") ?? 0 }
    }

    /// Journal rows left mid-flight by a crash, oldest first — the order
    /// recovery must repair them in.
    public func incompleteEvents() throws -> [ActivityEvent] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM activity_events WHERE status = ? ORDER BY created_at ASC, id ASC",
                arguments: [ActivityEventStatus.inProgress.rawValue]
            )
            return try rows.map { try Self.event(from: $0, db: db, includingImages: true) }
        }
    }

    /// Applied events Undo can still reach, newest first (FR-4.3: ≥10).
    public func undoableEvents(limit: Int = ActivityLog.undoDepth) throws -> [ActivityEvent] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM activity_events
                     WHERE kind = 'applied' AND status = 'applied' AND undoable = 1
                     ORDER BY created_at DESC, id DESC LIMIT ?
                    """,
                arguments: [limit]
            )
            return try rows.map { try Self.event(from: $0, db: db, includingImages: false) }
        }
    }

    /// The first *organization* event after `event` that touched any of the same
    /// notes — Undo's LIFO guard. Undo events themselves never block, or a
    /// ten-deep unwind would stop after the first step.
    public func laterEvent(touching noteIDs: Set<NoteID>, after event: ActivityEvent) throws -> ActivityEvent? {
        guard !noteIDs.isEmpty else { return nil }
        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: noteIDs.count).joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [
                event.timestamp.timeIntervalSince1970,
                event.timestamp.timeIntervalSince1970,
                event.id.uuidString,
            ]
            arguments.append(contentsOf: noteIDs.map(\.uuidString))
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT e.* FROM activity_events e
                      JOIN activity_note_images i ON i.event_id = e.id
                     WHERE e.kind = 'applied' AND e.status = 'applied' AND e.undone_by IS NULL
                       AND (e.created_at > ? OR (e.created_at = ? AND e.id > ?))
                       AND i.note_id IN (\(placeholders))
                     ORDER BY e.created_at ASC, e.id ASC LIMIT 1
                    """,
                arguments: StatementArguments(arguments)
            ) else { return nil }
            return try Self.event(from: row, db: db, includingImages: false)
        }
    }

    /// Per-note diffs for the Activity window (FR-4.3).
    ///
    /// The diff is over the note's *body* — front matter is stripped, because
    /// `id:` and `created:` appearing as a change would be noise the user did
    /// not make.
    public func diff(for id: ActivityEventID) throws -> [NoteDiff] {
        try images(for: id).map { image in
            let before = image.before.map { MarkdownDocument.parse($0.text).body } ?? ""
            let after = image.after.map { MarkdownDocument.parse($0.text).body } ?? ""
            return NoteDiff(
                noteID: image.noteID,
                title: image.title,
                beforePath: image.before?.relativePath,
                afterPath: image.after?.relativePath,
                diff: TextDiff.between(before, after),
                created: image.created,
                trashed: image.wasTrashed
            )
        }
    }

    // MARK: - Retention (FR-4.4)

    /// Drops what retention no longer requires.
    ///
    /// * Raw session text goes once it is older than `interval` — FR-4.4's
    ///   "recoverable for at least 30 days", and no longer.
    /// * Before/after images go only when the event is *also* past Undo's
    ///   reach: not undoable, not in the newest `keepingUndoDepth` applied
    ///   events, and not a journal row awaiting recovery. "Kept as long as the
    ///   event is undoable" is the rule.
    ///
    /// Event rows themselves are never deleted: the Activity log is a history.
    @discardableResult
    public func prune(
        olderThan interval: TimeInterval = ActivityLog.sessionTextRetention,
        now: Date = Date(),
        keepingUndoDepth: Int = ActivityLog.undoDepth
    ) throws -> ActivityPruneReport {
        let cutoff = now.addingTimeInterval(-interval).timeIntervalSince1970
        return try dbQueue.write { db in
            var report = ActivityPruneReport()
            try db.execute(
                sql: "UPDATE activity_events SET session_text = NULL WHERE session_text IS NOT NULL AND created_at < ?",
                arguments: [cutoff]
            )
            report.sessionTextsPruned = db.changesCount

            let keep = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM activity_events
                     WHERE kind = 'applied' AND status = 'applied' AND undoable = 1
                     ORDER BY created_at DESC, id DESC LIMIT ?
                    """,
                arguments: [keepingUndoDepth]
            )
            let placeholders = keep.isEmpty ? "''" : Array(repeating: "?", count: keep.count).joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [cutoff]
            arguments.append(contentsOf: keep)
            let stale = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT event_id FROM activity_note_images
                     WHERE event_id IN (
                         SELECT id FROM activity_events
                          WHERE created_at < ? AND status <> 'inProgress' AND undoable = 0
                     )
                     AND event_id NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            for eventID in stale {
                try db.execute(sql: "DELETE FROM activity_note_images WHERE event_id = ?", arguments: [eventID])
            }
            report.eventsStrippedOfImages = stale.count
            return report
        }
    }

    // MARK: - Baselines (FR-3.2)

    /// The stored baseline, or `nil` when the AI has never seen this note.
    ///
    /// `note_baselines` has no session column, so the round trip drops
    /// ``OrganizedBaseline/sessionID`` — which is a label on the last advance,
    /// not something the delta is computed from.
    public func baseline(for noteID: NoteID) throws -> OrganizedBaseline? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM note_baselines WHERE note_id = ?",
                arguments: [noteID.uuidString]
            ) else { return nil }
            return OrganizedBaseline(
                noteID: noteID,
                contentHash: row["content_hash"],
                text: row["text"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    public func setBaseline(noteID: NoteID, hash: String, text: String, at timestamp: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_baselines (note_id, content_hash, text, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(note_id) DO UPDATE SET
                        content_hash = excluded.content_hash,
                        text = excluded.text,
                        updated_at = excluded.updated_at
                    """,
                arguments: [noteID.uuidString, hash, text, timestamp.timeIntervalSince1970]
            )
        }
    }

    public func removeBaseline(for noteID: NoteID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM note_baselines WHERE note_id = ?", arguments: [noteID.uuidString])
        }
    }

    public func baselineCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_baselines") ?? 0 }
    }

    // MARK: - Row plumbing

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func writeImages(_ db: Database, eventID: ActivityEventID, images: [NoteImage]) throws {
        for (ordinal, image) in images.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO activity_note_images
                        (event_id, note_id, ordinal, title, created,
                         before_path, before_text, before_hash,
                         after_path, after_text, after_hash, trashed_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(event_id, note_id) DO UPDATE SET
                        ordinal = excluded.ordinal, title = excluded.title, created = excluded.created,
                        before_path = excluded.before_path, before_text = excluded.before_text,
                        before_hash = excluded.before_hash, after_path = excluded.after_path,
                        after_text = excluded.after_text, after_hash = excluded.after_hash,
                        trashed_url = excluded.trashed_url
                    """,
                arguments: [
                    eventID.uuidString, image.noteID.uuidString, ordinal, image.title, image.created ? 1 : 0,
                    image.before?.relativePath, image.before?.text, image.before?.contentHash,
                    image.after?.relativePath, image.after?.text, image.after?.contentHash,
                    image.trashedURL,
                ]
            )
        }
    }

    private static func images(_ db: Database, eventID: ActivityEventID) throws -> [NoteImage] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM activity_note_images WHERE event_id = ? ORDER BY ordinal",
            arguments: [eventID.uuidString]
        ).compactMap { row in
            guard let noteID = NoteID(row["note_id"] as String) else { return nil }
            return NoteImage(
                noteID: noteID,
                title: row["title"],
                before: side(row, "before"),
                after: side(row, "after"),
                trashedURL: row["trashed_url"],
                created: (row["created"] as Int) != 0
            )
        }
    }

    private static func side(_ row: Row, _ prefix: String) -> NoteImageSide? {
        guard let path = row["\(prefix)_path"] as String?, let text = row["\(prefix)_text"] as String? else { return nil }
        return NoteImageSide(relativePath: path, text: text, contentHash: row["\(prefix)_hash"] as String?)
    }

    private static func event(from row: Row, db: Database, includingImages: Bool) throws -> ActivityEvent {
        let id = ActivityEventID(row["id"] as String) ?? ActivityEventID()
        var plan: OrganizationPlan?
        if let json = row["plan_json"] as String? {
            plan = try? JSONDecoder().decode(OrganizationPlan.self, from: Data(json.utf8))
        }
        let images = includingImages ? try images(db, eventID: id) : []
        let count = includingImages
            ? images.count
            : (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM activity_note_images WHERE event_id = ?",
                arguments: [id.uuidString]
            ) ?? 0)
        return ActivityEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: row["created_at"]),
            kind: ActivityEventKind(rawValue: row["kind"]) ?? .external,
            status: ActivityEventStatus(rawValue: row["status"]) ?? .none,
            summary: row["summary"],
            promptVersion: (row["prompt_version"] as String?).flatMap { PromptVersion($0) },
            model: row["model"],
            plan: plan,
            isUndoable: (row["undoable"] as Int) != 0,
            undoneBy: (row["undone_by"] as String?).flatMap { ActivityEventID($0) },
            detail: row["detail"],
            images: images,
            affectedNoteCount: count,
            hasSessionText: (row["session_text"] as String?) != nil
        )
    }
}

// MARK: - BaselineStore

extension ActivityLog: BaselineStore {
    public func setBaseline(_ baseline: OrganizedBaseline) throws {
        try setBaseline(
            noteID: baseline.noteID,
            hash: baseline.contentHash,
            text: baseline.text,
            at: baseline.updatedAt
        )
    }
}

/// The GRDB ``BaselineStore``: `note_baselines` in `filaway.sqlite`, reached
/// through the ``ActivityLog``'s connection so the two never contend.
public struct DatabaseBaselineStore: BaselineStore {
    public let log: ActivityLog

    public init(log: ActivityLog) {
        self.log = log
    }

    public func baseline(for noteID: NoteID) async throws -> OrganizedBaseline? {
        try await log.baseline(for: noteID)
    }

    public func setBaseline(_ baseline: OrganizedBaseline) async throws {
        try await log.setBaseline(baseline)
    }

    public func removeBaseline(for noteID: NoteID) async throws {
        try await log.removeBaseline(for: noteID)
    }
}
