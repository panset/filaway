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
public enum DatabaseSchema {
    /// Bumped whenever the *last* migration changes; mirrored into `meta`.
    public static let version = 2

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
