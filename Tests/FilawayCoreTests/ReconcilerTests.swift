import Foundation
import Testing

@testable import FilawayCore

/// Reconciler behaviour is driven through `reconcile()` rather than FSEvents so
/// the assertions are deterministic; `WatcherTests` covers the live stream.
@Suite("Reconciler (DS-4)")
struct ReconcilerTests {
    /// Builds a library with a seeded database and a watcher over it.
    private func fixture() async throws -> (TempLibrary, MetadataStore, LibraryWatcher) {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata)
        return (temp, metadata, watcher)
    }

    @Test("First reconcile of an existing folder adopts every note (FR-7.1)")
    func adoptExistingFolder() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("one\n", to: "one.md")
        try temp.writeExternal("two\n", to: "Commands/two.md")
        try temp.writeExternal("skip me", to: "notes.txt")

        let changes = try await watcher.reconcile()
        #expect(changes.filter { if case .added = $0 { return true } else { return false } }.count == 2)
        #expect(changes.contains(.folderAdded("Commands")))
        #expect(try await metadata.allNotes().map(\.relativePath) == ["Commands/two.md", "one.md"])
    }

    @Test("An external edit is reported as modified, once")
    func externalEdit() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("before\n", to: "note.md")
        try await watcher.reconcile()

        try temp.writeExternal("after\n", to: "note.md")
        let changes = try await watcher.reconcile()
        #expect(changes.count == 1)
        #expect(changes.first?.note?.relativePath == "note.md")
        if case .modified = changes[0] {} else { Issue.record("expected .modified, got \(changes[0])") }
        #expect(try await metadata.note(relativePath: "note.md")?.contentHash == Hashing.sha256Hex("after\n"))

        // Reconciling again with nothing changed yields nothing.
        #expect(try await watcher.reconcile().isEmpty)
    }

    @Test("An externally deleted note is reported as removed and leaves the database")
    func externalDelete() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("gone soon\n", to: "note.md")
        try await watcher.reconcile()
        let id = try await metadata.note(relativePath: "note.md")?.id

        try temp.removeExternal("note.md")
        let changes = try await watcher.reconcile()
        #expect(changes == [.removed(relativePath: "note.md", id: id)])
        #expect(try await metadata.noteCount() == 0)
    }

    @Test("A move is detected via the front-matter id, keeping the note's identity")
    func moveDetectedByID() async throws {
        let (temp, metadata, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "curl")
        try await watcher.reconcile()

        try temp.makeExternalFolder("Commands")
        try temp.moveExternal("curl.md", to: "Commands/curl.md")
        let changes = try await watcher.reconcile()

        let moves = changes.compactMap { change -> (String, String)? in
            if case let .moved(from, to, _) = change { return (from, to) } else { return nil }
        }
        #expect(moves.count == 1)
        #expect(moves.first?.0 == "curl.md")
        #expect(moves.first?.1 == "Commands/curl.md")
        #expect(try await metadata.noteCount() == 1, "a move must not duplicate the note")
        #expect(try await metadata.note(id: note.id)?.relativePath == "Commands/curl.md")
    }

    @Test("A rename of an id-less note is detected by content hash")
    func moveDetectedByHash() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("no front matter here\n", to: "old name.md")
        try await watcher.reconcile()
        let before = try await metadata.note(relativePath: "old name.md")

        try temp.moveExternal("old name.md", to: "new name.md")
        let changes = try await watcher.reconcile()
        #expect(changes.count == 1)
        if case let .moved(from, to, note) = changes[0] {
            #expect(from == "old name.md")
            #expect(to == "new name.md")
            #expect(note.id == before?.id, "identity must carry across the rename")
            #expect(note.title == "new name")
        } else {
            Issue.record("expected .moved, got \(changes[0])")
        }
        #expect(try await metadata.noteCount() == 1)
    }

    @Test("A copied note gets a fresh identity rather than colliding")
    func copyGetsFreshIdentity() async throws {
        let (temp, metadata, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "original")
        try await watcher.reconcile()

        let raw = try temp.readExternal(note.relativePath)
        try temp.writeExternal(raw, to: "copy.md")
        let changes = try await watcher.reconcile()

        #expect(changes.count == 1)
        #expect(changes[0].note?.relativePath == "copy.md")
        #expect(changes[0].note?.id != note.id, "a duplicate must not reuse the identity")
        #expect(try await metadata.noteCount() == 2)
        #expect(try await metadata.note(id: note.id)?.relativePath == "original.md")
    }

    @Test("An id-less note keeps the identity the database gave it across edits")
    func identityStableAcrossEdits() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("v1\n", to: "plain.md")
        try await watcher.reconcile()
        let id = try await metadata.note(relativePath: "plain.md")?.id

        try temp.writeExternal("v2\n", to: "plain.md")
        try await watcher.reconcile()
        #expect(try await metadata.note(relativePath: "plain.md")?.id == id)
        #expect(try await metadata.noteCount() == 1)
    }

    @Test("The store's own writes update the database but are never emitted")
    func echoSuppression() async throws {
        let (temp, metadata, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "mine")
        #expect(try await watcher.reconcile().isEmpty, "a create by the app is not an external change")
        #expect(try await metadata.noteCount() == 1)

        try await temp.store.save(body: "edited by the app\n", to: note.relativePath)
        #expect(try await watcher.reconcile().isEmpty)
        #expect(try await metadata.note(relativePath: "mine.md")?.contentHash
            == (try await temp.store.summary(of: "mine.md")).contentHash)

        let moved = try await temp.store.move(note.relativePath, toFolder: "Commands")
        let moveChanges = try await watcher.reconcile()
        #expect(moveChanges.allSatisfy { if case .folderAdded = $0 { return true } else { return false } })
        #expect(try await metadata.note(id: note.id)?.relativePath == moved.relativePath)

        let trashed = try await temp.store.deleteNote(moved.relativePath)
        temp.trackTrashed(trashed)
        let deleteChanges = try await watcher.reconcile()
        #expect(!deleteChanges.contains { if case .removed = $0 { return true } else { return false } })
        #expect(try await metadata.noteCount() == 0)
    }

    @Test("An external edit that lands after our own write is not suppressed")
    func echoSuppressionIsContentSpecific() async throws {
        let (temp, metadata, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "mine")
        try await watcher.reconcile()

        try await temp.store.save(body: "app version\n", to: note.relativePath)
        try temp.writeExternal("someone else's version\n", to: note.relativePath)

        let changes = try await watcher.reconcile()
        #expect(changes.count == 1)
        if case .modified = changes[0] {} else { Issue.record("expected .modified, got \(changes[0])") }
        #expect(try await metadata.note(relativePath: "mine.md")?.contentHash
            == Hashing.sha256Hex("someone else's version\n"))
    }

    @Test("A targeted reconcile sees the same changes as a full one")
    func targetedReconcile() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("a\n", to: "a.md")
        try await watcher.reconcile()

        try temp.writeExternal("b\n", to: "Commands/b.md")
        try temp.writeExternal("a2\n", to: "a.md")
        let changes = try await watcher.reconcile(paths: ["a.md", "Commands/b.md"])
        #expect(changes.contains { $0.relativePath == "Commands/b.md" })
        #expect(changes.contains { $0.relativePath == "a.md" })
        #expect(changes.contains(.folderAdded("Commands")))
        #expect(try await metadata.noteCount() == 2)
        #expect(try await watcher.reconcile().isEmpty, "a full reconcile finds nothing left over")
    }

    @Test("An externally removed folder disappears from the database")
    func folderRemoval() async throws {
        let (temp, metadata, watcher) = try await fixture()
        try temp.writeExternal("x\n", to: "Commands/x.md")
        try await watcher.reconcile()

        try FileManager.default.removeItem(at: temp.url("Commands"))
        let changes = try await watcher.reconcile()
        #expect(changes.contains(.folderRemoved("Commands")))
        #expect(try await metadata.noteCount() == 0)
        #expect(try await metadata.folders().isEmpty)
    }

    // MARK: - External-edit conflict rule

    @Test("A dirty buffer wins and the external version is preserved beside it")
    func conflictKeepsBoth() async throws {
        let (temp, metadata, watcher) = try await fixture()
        let note = try await temp.store.createNote(inFolder: "Commands", title: "curl")
        try await temp.store.save(body: "original\n", to: note.relativePath)
        try await watcher.reconcile()

        // Someone edits the file while the editor holds unsaved changes.
        try temp.writeExternal("---\nid: \(note.id.uuidString)\n---\nexternal version\n", to: note.relativePath)
        let resolution = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "my unsaved buffer\n")

        #expect(resolution.didConflict)
        let copyPath = try #require(resolution.externalCopyPath)
        #expect(copyPath.hasPrefix("Commands/curl (external edit "))
        #expect(copyPath.hasSuffix(").md"))

        // The buffer is the file; the external bytes are safe next to it.
        #expect(try await temp.store.read(note.relativePath).body == "my unsaved buffer\n")
        #expect(try await temp.store.read(copyPath).body == "external version\n")
        #expect(try await temp.store.read(copyPath).id != note.id, "the copy must have its own identity")
        #expect(try await metadata.noteCount() == 2)
        #expect(try await metadata.note(id: note.id)?.relativePath == note.relativePath)
        #expect(try await watcher.reconcile().isEmpty, "conflict resolution leaves the database consistent")
    }

    @Test("A conflict copy emits .conflict and the copy as .added")
    func conflictEmitsChanges() async throws {
        let (temp, metadata, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "note")
        try await watcher.reconcile()
        let collector = ChangeCollector()
        await collector.attach(to: watcher)

        try temp.writeExternal("---\nid: \(note.id.uuidString)\n---\nexternal\n", to: note.relativePath)
        _ = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "buffer\n")
        _ = await waitUntil { await collector.snapshot().count >= 3 }
        let changes = await collector.snapshot()
        await collector.detach()

        #expect(changes.contains { if case .conflict = $0 { return true } else { return false } })
        #expect(changes.contains { if case let .added(added) = $0 { return added.title.contains("external edit") } else { return false } })
        _ = metadata
    }

    @Test("No conflict copy when the buffer matches what is on disk")
    func noConflictWhenClean() async throws {
        let (temp, _, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "note")
        try await temp.store.save(body: "same text\n", to: note.relativePath)
        try await watcher.reconcile()

        let resolution = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "same text\n")
        #expect(!resolution.didConflict)
        #expect(resolution.externalCopyPath == nil)
        #expect(temp.allMarkdownPaths() == ["note.md"])
    }

    @Test("A note deleted externally while dirty is restored from the buffer")
    func conflictAfterExternalDelete() async throws {
        let (temp, _, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "note")
        try await watcher.reconcile()
        try temp.removeExternal(note.relativePath)

        let resolution = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "rescued\n")
        #expect(!resolution.didConflict)
        #expect(try await temp.store.read(note.relativePath).body == "rescued\n")
    }

    @Test("Two conflicts on the same note in the same minute do not overwrite each other")
    func repeatedConflicts() async throws {
        let (temp, _, watcher) = try await fixture()
        let note = try await temp.store.createNote(title: "note")
        try await watcher.reconcile()

        try temp.writeExternal("---\nid: \(note.id.uuidString)\n---\nexternal one\n", to: note.relativePath)
        let first = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "buffer one\n")
        try temp.writeExternal("---\nid: \(note.id.uuidString)\n---\nexternal two\n", to: note.relativePath)
        let second = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "buffer two\n")

        #expect(first.externalCopyPath != second.externalCopyPath)
        #expect(try await temp.store.read(#require(first.externalCopyPath)).body == "external one\n")
        #expect(try await temp.store.read(#require(second.externalCopyPath)).body == "external two\n")
    }
}
