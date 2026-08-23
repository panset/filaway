import Foundation
import Testing

@testable import FilawayCore

@Suite("Path rules (DS-1)")
struct PathRulesTests {
    @Test("Illegal filename characters are replaced, not dropped silently")
    func sanitizing() {
        #expect(PathRules.sanitizeTitle("curl/POST") == "curl-POST")
        #expect(PathRules.sanitizeTitle("10:30 standup") == "10-30 standup")
        #expect(PathRules.sanitizeTitle("back\\slash") == "back-slash")
        #expect(PathRules.sanitizeTitle("line\nbreak") == "line break")
        #expect(PathRules.sanitizeTitle("  padded  ") == "padded")
        #expect(PathRules.sanitizeTitle("multiple    spaces") == "multiple spaces")
        #expect(PathRules.sanitizeTitle("...hidden") == "hidden")
        #expect(PathRules.sanitizeTitle("trailing...") == "trailing")
        #expect(PathRules.sanitizeTitle("") == PathRules.untitled)
        #expect(PathRules.sanitizeTitle("   ") == PathRules.untitled)
        #expect(PathRules.sanitizeTitle("...") == PathRules.untitled)
        #expect(PathRules.sanitizeTitle("a\u{0000}b") == "ab")
        #expect(PathRules.sanitizeTitle("émigré") == "émigré")
    }

    @Test("Very long titles are clamped on a character boundary")
    func longTitles() {
        let title = PathRules.sanitizeTitle(String(repeating: "é", count: 400))
        #expect(title.utf8.count <= PathRules.maxTitleBytes)
        #expect(title.allSatisfy { $0 == "é" })

        let suffixed = PathRules.suffixed(title, 12)
        #expect(suffixed.utf8.count <= PathRules.maxTitleBytes)
        #expect(suffixed.hasSuffix(" 12"))
    }

    @Test("Relative paths normalise and never escape the root")
    func normalisation() {
        #expect(PathRules.normalize("/Commands//curl.md/") == "Commands/curl.md")
        #expect(PathRules.normalize("./Commands/./curl.md") == "Commands/curl.md")
        #expect(PathRules.normalize("../../etc/passwd") == "etc/passwd")
        #expect(PathRules.normalize("Commands/../Docs/x.md") == "Docs/x.md")
        #expect(PathRules.folderPath(of: "Commands/Docker/run.md") == "Commands/Docker")
        #expect(PathRules.title(of: "Commands/Docker/run.md") == "run")
        #expect(PathRules.depth(ofFolder: "") == 0)
        #expect(PathRules.depth(ofFolder: "A/B") == 2)
        #expect(PathRules.isNotePath("a.md"))
        #expect(PathRules.isNotePath("a.MD"))
        #expect(!PathRules.isNotePath("a.txt"))
        #expect(!PathRules.isNotePath(".md"))
        #expect(!PathRules.isNotePath("Folder"))
    }

    @Test("Folder paths deeper than two levels are rejected")
    func depthCap() throws {
        #expect(try PathRules.sanitizeFolderPath("A/B") == "A/B")
        #expect(throws: StorageError.folderTooDeep("A/B/C")) {
            try PathRules.sanitizeFolderPath("A/B/C")
        }
    }
}

@Suite("NoteStore (DS-1, DS-2)")
struct NoteStoreTests {
    @Test("A new note gets a unique Untitled name and a stamped front-matter block")
    func createNote() async throws {
        let temp = try TempLibrary()
        let first = try await temp.store.createNote()
        let second = try await temp.store.createNote()
        let third = try await temp.store.createNote()

        #expect(first.relativePath == "Untitled note.md")
        #expect(second.relativePath == "Untitled note 2.md")
        #expect(third.relativePath == "Untitled note 3.md")
        #expect(first.title == "Untitled note")
        #expect(first.id != second.id)

        let raw = try temp.readExternal(first.relativePath)
        #expect(raw.hasPrefix("---\nid: \(first.id.uuidString)\ncreated: "))
        #expect(raw.contains("\n---\n"))
        // DS-1: the title is the filename, never duplicated as an H1.
        #expect(!first.body.contains("# Untitled note"))
        #expect(first.body.isEmpty)
    }

    @Test("Saving preserves foreign front-matter and never touches the body")
    func savePreservesForeignKeys() async throws {
        let temp = try TempLibrary()
        try temp.writeExternal("---\ntitle: Theirs\naliases:\n  - alias\n---\nOriginal body\n", to: "external.md")

        try await temp.store.save(body: "New body\n", to: "external.md", tags: ["shell"])
        let raw = try temp.readExternal("external.md")
        #expect(raw.contains("title: Theirs"))
        #expect(raw.contains("aliases:\n  - alias"))
        #expect(raw.contains("tags:\n  - shell"))
        #expect(raw.hasSuffix("\nNew body\n"))

        let note = try await temp.store.read("external.md")
        #expect(note.body == "New body\n")
        #expect(note.tags == ["shell"])
        #expect(note.id != nil as NoteID?)
    }

    @Test("Writes are atomic and leave nothing but .md files in the notes root")
    func atomicWrite() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(inFolder: "Commands", title: "curl")
        for index in 0 ..< 20 {
            try await temp.store.save(body: "body \(index)\n", to: note.relativePath)
            #expect(temp.strayEntries().isEmpty, "temp file leaked into the notes root")
        }
        #expect(try await temp.store.read(note.relativePath).body == "body 19\n")
        #expect(temp.allMarkdownPaths() == ["Commands/curl.md"])
    }

    @Test("Rename moves the file and suffixes on collision")
    func rename() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(title: "First")
        _ = try await temp.store.createNote(title: "Second")

        let renamed = try await temp.store.rename(note.relativePath, to: "Second")
        #expect(renamed.relativePath == "Second 2.md")
        #expect(renamed.title == "Second 2")
        #expect(renamed.id == note.id, "rename must keep the note's identity")
        #expect(temp.allMarkdownPaths() == ["Second 2.md", "Second.md"])

        let sanitized = try await temp.store.rename(renamed.relativePath, to: "a/b:c")
        #expect(sanitized.relativePath == "a-b-c.md")
    }

    @Test("Rename to the same title is a no-op; a case-only rename works")
    func renameEdgeCases() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(title: "Notes")
        let same = try await temp.store.rename(note.relativePath, to: "Notes")
        #expect(same.relativePath == "Notes.md")

        let cased = try await temp.store.rename(note.relativePath, to: "NOTES")
        #expect(cased.relativePath == "NOTES.md")
        #expect(temp.allMarkdownPaths() == ["NOTES.md"])
    }

    @Test("Move enforces the two-folder depth cap")
    func moveDepth() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(title: "curl")

        let moved = try await temp.store.move(note.relativePath, toFolder: "Commands/Docker")
        #expect(moved.relativePath == "Commands/Docker/curl.md")
        #expect(moved.folderPath == "Commands/Docker")
        #expect(moved.id == note.id)

        await #expect(throws: StorageError.folderTooDeep("Commands/Docker/Compose")) {
            try await temp.store.move(moved.relativePath, toFolder: "Commands/Docker/Compose")
        }
        await #expect(throws: StorageError.folderTooDeep("A/B/C")) {
            try await temp.store.createFolder("A/B/C")
        }
        await #expect(throws: StorageError.folderTooDeep("A/B/C")) {
            try await temp.store.createNote(inFolder: "A/B/C")
        }
    }

    @Test("Moving into a folder that already has that title suffixes the name")
    func moveCollision() async throws {
        let temp = try TempLibrary()
        _ = try await temp.store.createNote(inFolder: "Commands", title: "curl")
        let other = try await temp.store.createNote(title: "curl")
        let moved = try await temp.store.move(other.relativePath, toFolder: "Commands")
        #expect(moved.relativePath == "Commands/curl 2.md")
    }

    @Test("Delete moves a note to the Trash instead of removing it")
    func deleteNoteGoesToTrash() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(title: "Disposable")
        let body = try temp.readExternal(note.relativePath)

        let trashed = try await temp.store.deleteNote(note.relativePath)
        temp.trackTrashed(trashed)

        #expect(!FileManager.default.fileExists(atPath: temp.url(note.relativePath).path))
        #expect(FileManager.default.fileExists(atPath: trashed.path), "the note must still exist somewhere")
        #expect(try String(contentsOf: trashed, encoding: .utf8) == body, "trashed content must be intact")
        await #expect(throws: StorageError.notFound("Disposable.md")) {
            try await temp.store.deleteNote("Disposable.md")
        }
    }

    @Test("Deleting a folder trashes it whole, notes included")
    func deleteFolderGoesToTrash() async throws {
        let temp = try TempLibrary()
        _ = try await temp.store.createNote(inFolder: "Scratch", title: "one")
        _ = try await temp.store.createNote(inFolder: "Scratch", title: "two")

        let trashed = try await temp.store.deleteFolder("Scratch")
        temp.trackTrashed(trashed)

        #expect(temp.allMarkdownPaths().isEmpty)
        #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("one.md").path))
        #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("two.md").path))
    }

    @Test("Scan finds every note, folder and tag")
    func scan() async throws {
        let temp = try TempLibrary()
        _ = try await temp.store.createNote(title: "Root note")
        _ = try await temp.store.createNote(inFolder: "Commands", title: "curl")
        _ = try await temp.store.createNote(inFolder: "Commands/Docker", title: "run")
        try await temp.store.createFolder("Empty")
        try temp.writeExternal("not markdown", to: "ignored.txt")
        try temp.writeExternal("---\ntags: [a, b]\n---\nhi\n", to: "Commands/foreign.md")

        let snapshot = try await temp.store.scan()
        #expect(snapshot.notes.map(\.relativePath) == [
            "Commands/Docker/run.md", "Commands/curl.md", "Commands/foreign.md", "Root note.md",
        ])
        #expect(snapshot.folderPaths == ["Commands", "Commands/Docker", "Empty"])
        #expect(snapshot.notes.first { $0.title == "foreign" }?.tags == ["a", "b"])

        let tree = snapshot.tree
        #expect(tree.subfolders.map(\.name) == ["Commands", "Empty"])
        #expect(tree.notes.map(\.title) == ["Root note"])
        #expect(tree.subfolders[0].notes.map(\.title) == ["curl", "foreign"])
        #expect(tree.subfolders[0].subfolders.map(\.name) == ["Docker"])
    }

    @Test("Scan reuses cached summaries for settled, unchanged files")
    func scanReuse() async throws {
        let temp = try TempLibrary()
        let note = try await temp.store.createNote(title: "Cached")
        try temp.backdate(note.relativePath, by: 60)

        let first = try await temp.store.scan()
        var cache = first.notesByPath
        // Poison the cache: a reused entry keeps the poisoned hash.
        let original = first.notes[0]
        cache[note.relativePath] = NoteSummary(
            id: original.id, relativePath: original.relativePath, title: original.title,
            folderPath: original.folderPath, tags: ["poison"], created: original.created,
            modified: original.modified, size: original.size, contentHash: "poisoned"
        )
        let second = try await temp.store.scan(reusing: cache)
        #expect(second.notes[0].contentHash == "poisoned")

        // A file modified moments ago is always re-read, whatever the cache says.
        try await temp.store.save(body: "changed\n", to: note.relativePath)
        let third = try await temp.store.scan(reusing: cache)
        #expect(third.notes[0].contentHash != "poisoned")
    }

    @Test("A note without front-matter gets a stable, path-derived identity")
    func derivedIdentity() async throws {
        let temp = try TempLibrary()
        try temp.writeExternal("plain body\n", to: "plain.md")
        let first = try await temp.store.summary(of: "plain.md")
        let second = try await temp.store.summary(of: "plain.md")
        #expect(first.id == second.id)
        #expect(first.id.isDerived(fromRelativePath: "plain.md"))
        #expect(first.id != NoteID.derived(fromRelativePath: "other.md"))
    }

    @Test("Non-UTF-8 files are reported, not silently mangled")
    func invalidUTF8() async throws {
        let temp = try TempLibrary()
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: temp.url("bad.md"))
        await #expect(throws: StorageError.notUTF8("bad.md")) {
            try await temp.store.read("bad.md")
        }
    }

    @Test("The library key is stable per root and differs between roots")
    func libraryKey() throws {
        let temp = try TempLibrary()
        #expect(temp.library.key == Library(root: temp.root).key)
        #expect(temp.library.key.count == 16)
        #expect(temp.library.key != Library(root: temp.supportRoot).key)
        #expect(temp.library.databaseURL.path.hasSuffix("\(temp.library.key)/filaway.sqlite"))
    }

    @Test("Bookmarks round-trip the root, including across a rename (NFR-5)")
    func bookmarks() throws {
        let temp = try TempLibrary()
        let bookmark = try temp.library.bookmarkData()
        let (restored, _) = try Library.resolving(bookmark: bookmark, supportRoot: temp.supportRoot)
        #expect(restored.root == temp.library.root)
        #expect(restored.key == temp.library.key)
    }
}
