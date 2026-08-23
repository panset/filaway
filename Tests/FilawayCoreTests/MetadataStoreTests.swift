import Foundation
import Testing

@testable import FilawayCore

@Suite("Metadata database (DS-3)")
struct MetadataStoreTests {
    @Test("Opening a library creates a migrated database in Application Support")
    func migration() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        #expect(try await metadata.schemaVersion() == DatabaseSchema.version)
        #expect(try await metadata.meta("library_key") == temp.library.key)
        #expect(try await metadata.meta("library_root") == temp.root.path)
        #expect(FileManager.default.fileExists(atPath: temp.library.databaseURL.path))
        // DS-3: derived data never lands in the user's notes folder.
        #expect(temp.strayEntries().isEmpty)
        #expect(temp.library.databaseURL.path.hasPrefix(temp.supportRoot.path))
    }

    @Test("Re-opening an existing database migrates idempotently")
    func reopen() async throws {
        let temp = try TempLibrary()
        let first = try temp.metadataStore()
        _ = try await first.rebuild(from: try await temp.store.scan())
        let second = try temp.metadataStore()
        #expect(try await second.schemaVersion() == DatabaseSchema.version)
    }

    @Test("Rebuild-from-folder reproduces the scan exactly, and is idempotent")
    func rebuildEquivalence() async throws {
        let temp = try TempLibrary()
        _ = try await temp.store.createNote(title: "Root")
        _ = try await temp.store.createNote(inFolder: "Commands", title: "curl")
        _ = try await temp.store.createNote(inFolder: "Commands/Docker", title: "run")
        try await temp.store.createFolder("Empty")
        try temp.writeExternal("---\ntags: [x, y]\n---\nbody\n", to: "Commands/foreign.md")

        let metadata = try temp.metadataStore()
        let snapshot = try await temp.store.scan()
        try await metadata.rebuild(from: snapshot)

        func compare(_ rows: [NoteSummary]) {
            #expect(rows.count == snapshot.notes.count)
            for (row, note) in zip(rows, snapshot.notes) {
                #expect(row.id == note.id)
                #expect(row.relativePath == note.relativePath)
                #expect(row.title == note.title)
                #expect(row.folderPath == note.folderPath)
                #expect(row.tags == note.tags)
                #expect(row.contentHash == note.contentHash)
                #expect(row.size == note.size)
                #expect(abs(row.modified.timeIntervalSince(note.modified)) < 0.001)
                #expect(abs(row.created.timeIntervalSince(note.created)) < 0.001)
            }
        }
        compare(try await metadata.allNotes())

        // A second rebuild from the same snapshot changes nothing.
        try await metadata.rebuild(from: snapshot)
        compare(try await metadata.allNotes())

        #expect(try await metadata.folders().map(\.path) == ["Commands", "Commands/Docker", "Empty"])
        // Same shape from the database alone, without touching the disk.
        func shape(_ folder: Folder) -> String {
            let children = folder.subfolders.map(shape).joined(separator: ",")
            return "\(folder.path)[\(folder.notes.map(\.title).joined(separator: " "))]{\(children)}"
        }
        #expect(shape(try await metadata.tree()) == shape(snapshot.tree))
    }

    @Test("A deleted database rebuilds to the same state (DS-3 'fully rebuildable')")
    func rebuildAfterDeletion() async throws {
        let temp = try TempLibrary()
        for index in 0 ..< 20 {
            _ = try await temp.store.createNote(inFolder: index % 2 == 0 ? "A" : "B", title: "note \(index)")
        }
        let first = try temp.metadataStore()
        try await first.rebuild(from: try await temp.store.scan())
        let before = try await first.allNotes()

        try FileManager.default.removeItem(at: temp.library.databaseURL)
        let second = try temp.metadataStore()
        try await second.rebuild(from: try await temp.store.scan())
        #expect(try await second.allNotes().map(\.id) == before.map(\.id))
        #expect(try await second.allNotes().map(\.relativePath) == before.map(\.relativePath))
    }

    @Test("Rebuild carries last-opened across, because no file records it")
    func rebuildPreservesLastOpened() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(title: "Opened")
        let metadata = try temp.metadataStore()
        try await metadata.rebuild(from: try await temp.store.scan())

        let opened = Date(timeIntervalSince1970: 1_700_000_000)
        try await metadata.markOpened(id: note.id, at: opened)
        try await metadata.rebuild(from: try await temp.store.scan())
        #expect(try await metadata.recents().first?.lastOpened == opened)
    }

    @Test("Recents order by max(lastOpened, mtime) and cap at the limit (FR-1.2)")
    func recents() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        var notes: [NoteSummary] = []
        for index in 0 ..< 15 {
            let note = try await temp.store.createNote(title: "note \(index)")
            notes.append(NoteSummary(
                id: note.id, relativePath: note.relativePath, title: note.title, folderPath: "",
                tags: [], created: note.created,
                modified: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
                size: 0, contentHash: note.contentHash
            ))
        }
        try await metadata.upsert(notes)

        let recents = try await metadata.recents(limit: 10)
        #expect(recents.count == 10)
        #expect(recents.map(\.note.title) == (5 ... 14).reversed().map { "note \($0)" })

        // Opening the oldest note floats it to the top.
        try await metadata.markOpened(id: notes[0].id, at: Date(timeIntervalSince1970: 2_000_000))
        let after = try await metadata.recents(limit: 10)
        #expect(after.first?.note.title == "note 0")
        #expect(after.first?.sortDate == Date(timeIntervalSince1970: 2_000_000))
    }

    @Test("Upsert is keyed by identity, so a moved note updates rather than duplicates")
    func upsertByIdentity() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let note = try await temp.store.createNote(title: "Movable")
        try await metadata.upsert(try await temp.store.scan().notes)
        #expect(try await metadata.noteCount() == 1)

        let moved = try await temp.store.move(note.relativePath, toFolder: "Commands")
        try await metadata.upsert(moved)
        #expect(try await metadata.noteCount() == 1)
        #expect(try await metadata.note(id: note.id)?.relativePath == "Commands/Movable.md")
        #expect(try await metadata.folders().map(\.path) == ["Commands"])
    }

    @Test("Removing a folder removes its notes")
    func removeFolder() async throws {
        let temp = try TempLibrary()
        _ = try await temp.store.createNote(inFolder: "Commands/Docker", title: "run")
        _ = try await temp.store.createNote(title: "keep")
        let metadata = try temp.metadataStore()
        try await metadata.rebuild(from: try await temp.store.scan())

        try await metadata.removeFolder("Commands")
        #expect(try await metadata.allNotes().map(\.relativePath) == ["keep.md"])
        #expect(try await metadata.folders().isEmpty)
    }

    @Test("Tags survive the JSON round trip through SQLite")
    func tagRoundTrip() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let tags = ["shell", "two words", "ünïcode", "with,comma", "with\"quote"]
        try temp.writeExternal(
            "---\ntags:\n" + tags.map { "  - \(FrontMatter.encodeScalar($0))" }.joined(separator: "\n") + "\n---\nbody\n",
            to: "tagged.md"
        )
        try await metadata.rebuild(from: try await temp.store.scan())
        #expect(try await metadata.allNotes().first?.tags == tags)
    }
}
