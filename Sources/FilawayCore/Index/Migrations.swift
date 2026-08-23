import Foundation
import GRDB

/// The migration registry for the derived database (DS-3).
///
/// Everything here is *derived*: the file can be deleted at any time and
/// rebuilt from the notes folder (`Settings → Rebuild index`). That is what
/// lets later milestones bolt on FTS5, embeddings, activity and undo without
/// touching the user's Markdown.
///
/// ## Adding a migration
///
/// Append a `registerMigration` call — never edit an existing one, and never
/// reorder. GRDB records applied identifiers in `grdb_migrations`, so a
/// half-upgraded database converges on the next launch. The reserved
/// identifiers below are the ones the plan already schedules:
///
/// | Identifier | Milestone | Adds |
/// |---|---|---|
/// | `v1-notes` | M1-04 | `meta`, `folders`, `notes` |
/// | `v2-fts` | M1-06 | `note_text` + `notes_fts` (unicode61) + `notes_trigram` and their sync triggers |
/// | `v3-chunks` | M3-02 | `chunks`, `embeddings` (vector BLOBs) |
/// | `v4-activity` | M2-08 | `activity_events`, `undo_events`, `note_baselines` |
/// | `v5-pending-sessions` | M2-09 | `pending_sessions` (the FR-6.4 offline queue) |
public enum DatabaseSchema {
    /// Bumped whenever the *last* migration changes; mirrored into `meta`.
    public static let version = 4

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-notes") { db in
            try db.create(table: "meta") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }

            try db.create(table: "folders") { table in
                table.column("path", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("parent_path", .text)
                table.column("depth", .integer).notNull()
            }
            try db.create(index: "folders_on_parent", on: "folders", columns: ["parent_path"])

            try db.create(table: "notes") { table in
                table.column("id", .text).primaryKey()
                table.column("relpath", .text).notNull()
                table.column("folder_path", .text).notNull().defaults(to: "")
                table.column("title", .text).notNull()
                table.column("content_hash", .text).notNull()
                table.column("mtime", .double).notNull()
                table.column("size", .integer).notNull()
                table.column("created", .double).notNull()
                table.column("last_opened", .double)
                table.column("tags", .text).notNull().defaults(to: "[]")
            }
            try db.create(index: "notes_on_relpath", on: "notes", columns: ["relpath"], unique: true)
            try db.create(index: "notes_on_folder", on: "notes", columns: ["folder_path"])
            // Recents (FR-1.2) sort by max(last_opened, mtime).
            try db.execute(sql: "CREATE INDEX notes_on_mtime ON notes(mtime DESC)")
        }

        // M1-06 (FR-5.1). Full text lives in `note_text`, one row per note, and
        // two FTS5 indexes sit on top of it as *external content* tables so the
        // body text is stored once:
        //
        // * `notes_fts` — `unicode61`: words, prefixes (`dock*`), phrases, and
        //   the bm25 ranking signal. Small index, no substring matching.
        // * `notes_trigram` — `trigram`: arbitrary substrings, which is what
        //   "find `-sSL` inside a curl command" needs. Costs roughly the size of
        //   the text again; only queries of three characters or more can use it.
        //
        // `note_text.note_id` cascades from `notes`, so every existing delete
        // path (reconcile, folder removal, rebuild) unindexes for free, and the
        // triggers below keep both FTS tables in step with `note_text`.
        migrator.registerMigration("v2-fts") { db in
            try db.execute(sql: """
                CREATE TABLE note_text (
                    rowid INTEGER PRIMARY KEY,
                    note_id TEXT NOT NULL UNIQUE REFERENCES notes(id) ON DELETE CASCADE,
                    relpath TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    content_hash TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX note_text_on_relpath ON note_text(relpath)")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    title, body,
                    content='note_text', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                )
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_trigram USING fts5(
                    title, body,
                    content='note_text', content_rowid='rowid',
                    tokenize='trigram'
                )
                """)
            // Persisted ranking weights: a hit in the title counts ten times a
            // hit in the body, so `ORDER BY rank` is already the order the UI
            // wants and SQLite never has to sort twice.
            for table in ftsTables {
                try db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES('rank', 'bm25(10.0, 1.0)')")
            }
            for sql in ftsTriggerStatements { try db.execute(sql: sql) }
        }

        // M3-02 (FR-5.4). The semantic index: `chunks` holds the units the
        // chunker produced, `embeddings` holds one vector per (chunk, model).
        //
        // * `source_hash` is the note's `content_hash` at the time it was
        //   chunked, so "is this note up to date?" is one indexed query and no
        //   third table is needed.
        // * `text_hash` is the diff key: editing one paragraph re-embeds one
        //   chunk, not the note (M3-02's incremental test).
        // * `embeddings.model_id` is `Embedder.identifier`. Swapping models
        //   costs a re-embed but never a re-read of the notes folder: the
        //   chunk text is unchanged, and the old model's vectors are deleted
        //   in the same pass.
        // * `vector` is a Float16 BLOB — half the memory of Float32 at no
        //   measurable ranking cost (ADR-023), stored as raw IEEE 754 binary16
        //   so it is architecture-independent.
        // Both tables cascade from `notes`, so every existing delete path
        // (reconcile, folder removal, rebuild) unindexes for free.
        migrator.registerMigration("v3-chunks") { db in
            try db.execute(sql: """
                CREATE TABLE chunks (
                    id INTEGER PRIMARY KEY,
                    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    heading_path TEXT NOT NULL DEFAULT '',
                    language TEXT,
                    range_start INTEGER NOT NULL,
                    range_length INTEGER NOT NULL,
                    text_hash TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    text TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX chunks_on_note_ordinal ON chunks(note_id, ordinal)")
            try db.execute(sql: "CREATE INDEX chunks_on_note_hash ON chunks(note_id, text_hash)")

            try db.execute(sql: """
                CREATE TABLE embeddings (
                    chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                    model_id TEXT NOT NULL,
                    dim INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    PRIMARY KEY (chunk_id, model_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX embeddings_on_model ON embeddings(model_id)")
        }

        // M2-07 / M2-08 (FR-4.3, FR-4.4, NFR-3). One table does double duty:
        // `activity_events` is both the user-visible Activity log *and* the
        // apply journal. A row is written with `status = 'inProgress'` before
        // ``PlanApplier`` touches a single file, and only flips to `'applied'`
        // once every after-image is durable — so a crash mid-apply leaves a row
        // that ``PlanApplier/recoverIncompleteEvents()`` can roll back (or
        // forward) on the next launch.
        //
        // `activity_note_images` holds the before/after *raw file text* of every
        // note an event touched: the material for the diff view (FR-4.3), for
        // Undo (byte-identical restore or a reverse patch), and for journal
        // recovery. It is its own table rather than a JSON blob because Undo's
        // LIFO rule asks "did a later event touch this note?", which wants an
        // index.
        migrator.registerMigration("v4-activity") { db in
            try db.execute(sql: """
                CREATE TABLE activity_events (
                    id TEXT PRIMARY KEY,
                    created_at DOUBLE NOT NULL,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    prompt_version TEXT,
                    model TEXT,
                    plan_json TEXT,
                    session_text TEXT,
                    progress_json TEXT,
                    undoable INTEGER NOT NULL DEFAULT 1,
                    undone_by TEXT,
                    detail TEXT NOT NULL DEFAULT ''
                )
                """)
            try db.execute(sql: "CREATE INDEX activity_events_on_created ON activity_events(created_at DESC, id DESC)")
            try db.execute(sql: "CREATE INDEX activity_events_on_status ON activity_events(status)")

            try db.execute(sql: """
                CREATE TABLE activity_note_images (
                    event_id TEXT NOT NULL REFERENCES activity_events(id) ON DELETE CASCADE,
                    note_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    created INTEGER NOT NULL DEFAULT 0,
                    before_path TEXT,
                    before_text TEXT,
                    before_hash TEXT,
                    after_path TEXT,
                    after_text TEXT,
                    after_hash TEXT,
                    trashed_url TEXT,
                    PRIMARY KEY (event_id, note_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX activity_note_images_on_note ON activity_note_images(note_id)")

            try db.execute(sql: """
                CREATE TABLE undo_events (
                    id TEXT PRIMARY KEY,
                    event_id TEXT NOT NULL REFERENCES activity_events(id) ON DELETE CASCADE,
                    created_at DOUBLE NOT NULL,
                    outcome TEXT NOT NULL,
                    detail TEXT NOT NULL DEFAULT ''
                )
                """)
            try db.execute(sql: "CREATE INDEX undo_events_on_event ON undo_events(event_id)")

            // The organized baseline of FR-3.2: the content the last plan was
            // computed against, so `SessionTracker` can tell "the user typed
            // since" from "nothing changed".
            try db.execute(sql: """
                CREATE TABLE note_baselines (
                    note_id TEXT PRIMARY KEY,
                    content_hash TEXT NOT NULL,
                    text TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL
                )
                """)
        }

        // M2-09 (FR-6.4). The offline queue: sessions that could not reach the
        // provider, so a relaunch still files them. ``PendingSessionStoreGRDB``
        // owns this table and opens its own connection, like ``ActivityLog``
        // (ADR-027). `note_ids` is a JSON array rather than a join table
        // because nothing ever queries the queue *by note* — it is drained
        // whole, oldest first.
        migrator.registerMigration("v5-pending-sessions") { db in
            try db.execute(sql: """
                CREATE TABLE pending_sessions (
                    id TEXT PRIMARY KEY,
                    note_ids TEXT NOT NULL,
                    started_at DOUBLE NOT NULL,
                    ended_at DOUBLE NOT NULL,
                    reason TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    next_attempt_at DOUBLE
                )
                """)
            try db.execute(sql: "CREATE INDEX pending_sessions_on_ended ON pending_sessions(ended_at ASC)")
        }

        return migrator
    }

    /// The FTS tables kept in sync with `note_text`.
    static let ftsTables = ["notes_fts", "notes_trigram"]

    /// Triggers mirroring `note_text` into both FTS indexes.
    ///
    /// Dropped and recreated around a bulk rebuild (see
    /// ``MetadataStore/rebuild(from:indexingText:)``): row-at-a-time trigger
    /// firing costs far more than FTS5's own `'rebuild'` command, and the
    /// statements live here so the two paths can never drift.
    static var ftsTriggerStatements: [String] {
        var statements: [String] = []
        for table in ftsTables {
            statements.append("""
                CREATE TRIGGER note_text_ai_\(table) AFTER INSERT ON note_text BEGIN
                    INSERT INTO \(table)(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END
                """)
            statements.append("""
                CREATE TRIGGER note_text_ad_\(table) AFTER DELETE ON note_text BEGIN
                    INSERT INTO \(table)(\(table), rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                END
                """)
            statements.append("""
                CREATE TRIGGER note_text_au_\(table) AFTER UPDATE ON note_text BEGIN
                    INSERT INTO \(table)(\(table), rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                    INSERT INTO \(table)(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END
                """)
        }
        return statements
    }

    static var ftsTriggerNames: [String] {
        ftsTables.flatMap { ["note_text_ai_\($0)", "note_text_ad_\($0)", "note_text_au_\($0)"] }
    }
}
