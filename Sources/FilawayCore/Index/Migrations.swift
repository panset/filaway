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
/// | `v2-fts` | M1-06 | `notes_fts` (trigram + unicode61) and its sync triggers |
/// | `v3-chunks` | M3-02 | `chunks`, `embeddings` (vector BLOBs) |
/// | `v4-activity` | M2-08 | `activity_events`, `undo_events`, `note_baselines` |
public enum DatabaseSchema {
    /// Bumped whenever the *last* migration changes; mirrored into `meta`.
    public static let version = 1

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

        return migrator
    }
}
