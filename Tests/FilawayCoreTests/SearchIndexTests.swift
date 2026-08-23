import Foundation
import Testing

@testable import FilawayCore

/// The FTS index is derived data with a contract: it must agree with the notes
/// folder after *every* path that changes it — the app's own writes, the
/// reconciler's, and a full rebuild (M1-06, DS-3, DS-4).
@Suite("Search index consistency (M1-06)")
struct SearchIndexTests {
    /// Every note in the database has exactly one indexed row, whose text is
    /// what is on disk right now.
    private func assertConsistent(_ temp: TempLibrary, _ stack: SearchStack, _ comment: Comment) async throws {
        let notes = try await stack.metadata.allNotes()
        #expect(try await stack.metadata.textIndexCount() == notes.count, comment)
        #expect(try await stack.metadata.staleTextNotes().isEmpty, comment)
        for note in notes {
            let indexed = try #require(try await stack.metadata.text(id: note.id), comment)
            #expect(indexed.relativePath == note.relativePath, comment)
            #expect(indexed.title == note.title, comment)
            let onDisk = try await temp.store.read(note.relativePath).body
            #expect(indexed.body == onDisk, comment)
        }
    }

    @Test("A rebuild indexes every note and nothing else")
    func rebuildIndexesEverything() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("One", body: "alpha")
        try await temp.makeNote("Two", folder: "Sub", body: "beta")
        try temp.writeExternal("no front matter, just gamma\n", to: "Three.md")

        let stack = try await temp.searchStack()
        try await assertConsistent(temp, stack, "after rebuild")
        #expect(await stack.search.keyword("gamma").titles == ["Three"])

        // Rebuilding again must not double up or lose anything.
        try await stack.metadata.rebuild(from: try await temp.store.scan())
        try await assertConsistent(temp, stack, "after a second rebuild")
        #expect(await stack.search.keyword("gamma").count == 1)
    }

    @Test("Deleting the database costs only a rebuild")
    func rebuildFromScratch() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Recoverable", body: "the needle")
        _ = try await temp.searchStack()

        try FileManager.default.removeItem(at: temp.library.databaseURL)
        let fresh = try await temp.searchStack()
        #expect(await fresh.search.keyword("needle").titles == ["Recoverable"])
    }

    @Test("`indexingText: false` defers the work without leaving stale rows")
    func deferredIndexing() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Deferred", body: "the needle")
        let metadata = try temp.metadataStore()
        try await metadata.rebuild(from: try await temp.store.scan(), indexingText: false)

        #expect(try await metadata.textIndexCount() == 0)
        let search = SearchService(metadata: metadata)
        #expect(await search.keyword("needle").isEmpty)

        // The catch-up path: whatever `staleTextNotes` names, indexed, is enough.
        let stale = try await metadata.staleTextNotes()
        #expect(stale.count == 1)
        try await metadata.indexText(stale.map {
            NoteText(
                id: $0.id, relativePath: $0.relativePath, title: $0.title,
                body: "the needle", contentHash: $0.contentHash
            )
        })
        #expect(try await metadata.staleTextNotes().isEmpty)
        #expect(await search.keyword("needle").titles == ["Deferred"])
    }

    // MARK: - External changes (DS-4)

    @Test("An externally added note becomes searchable on reconcile")
    func externalAdd() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Existing", body: "alpha")
        let stack = try await temp.searchStack()

        try temp.writeExternal("# Added\n\nzeppelin\n", to: "Added.md")
        try await stack.watcher.reconcile()

        #expect(await stack.search.keyword("zeppelin").titles == ["Added"])
        try await assertConsistent(temp, stack, "after an external add")
    }

    @Test("An externally edited note reindexes: the old text stops matching")
    func externalEdit() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Edited", body: "the original zeppelin")
        let stack = try await temp.searchStack()
        #expect(await stack.search.keyword("zeppelin").count == 1)

        try temp.writeExternal("# Edited\n\nthe replacement dirigible\n", to: "Edited.md")
        try await stack.watcher.reconcile()

        #expect(await stack.search.keyword("zeppelin").isEmpty, "stale text must not linger in the index")
        #expect(await stack.search.keyword("dirigible").titles == ["Edited"])
        try await assertConsistent(temp, stack, "after an external edit")
    }

    @Test("A moved note keeps its text and reports the new path")
    func externalMove() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Movable", body: "zeppelin")
        let stack = try await temp.searchStack()

        try temp.makeExternalFolder("Archive")
        try temp.moveExternal("Movable.md", to: "Archive/Movable.md")
        try await stack.watcher.reconcile()

        let hits = await stack.search.keyword("zeppelin")
        #expect(hits.count == 1)
        #expect(hits[0].relativePath == "Archive/Movable.md")
        try await assertConsistent(temp, stack, "after an external move")
    }

    @Test("A renamed note is findable by its new title and not its old one")
    func rename() async throws {
        let temp = try TempLibrary()
        let note = try await temp.makeNote("Beforehand", body: "unchanged text")
        let stack = try await temp.searchStack()
        #expect(await stack.search.keyword("Beforehand").count == 1)

        _ = try await temp.store.rename(note.relativePath, to: "Afterwards")
        try await stack.watcher.reconcile()

        #expect(await stack.search.keyword("Afterwards").count == 1)
        #expect(await stack.search.keyword("Beforehand").isEmpty)
        try await assertConsistent(temp, stack, "after a rename")
    }

    @Test("A deleted note leaves no trace in the index")
    func externalDelete() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Doomed", body: "zeppelin")
        try await temp.makeNote("Survivor", body: "alpha")
        let stack = try await temp.searchStack()

        try temp.removeExternal("Doomed.md")
        try await stack.watcher.reconcile()

        #expect(await stack.search.keyword("zeppelin").isEmpty)
        #expect(try await stack.metadata.textIndexCount() == 1)
        try await assertConsistent(temp, stack, "after an external delete")
    }

    @Test("Removing a folder unindexes everything inside it")
    func folderRemoval() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Inside", folder: "Doomed", body: "zeppelin")
        try await temp.makeNote("Outside", body: "alpha")
        let stack = try await temp.searchStack()

        try temp.removeExternal("Doomed")
        try await stack.watcher.reconcile()

        #expect(await stack.search.keyword("zeppelin").isEmpty)
        try await assertConsistent(temp, stack, "after a folder removal")
    }

    @Test("The app's own save reindexes without waiting for a reconcile")
    func ownWrite() async throws {
        let temp = try TempLibrary()
        let note = try await temp.makeNote("Live", body: "the original zeppelin")
        let stack = try await temp.searchStack()

        let summary = try await temp.store.save(body: "now a dirigible", to: note.relativePath)
        try await stack.metadata.upsert(summary)

        #expect(await stack.search.keyword("zeppelin").isEmpty)
        #expect(await stack.search.keyword("dirigible").titles == ["Live"])
        try await assertConsistent(temp, stack, "after an in-app save")
    }

    @Test("A note whose file cannot be read is skipped, not fatal")
    func unreadableFile() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Readable", body: "alpha")
        let snapshot = try await temp.store.scan()
        // Point the loader at a note that is not on disk.
        let metadata = try MetadataStore(library: temp.library, textLoader: .disabled)
        try await metadata.rebuild(from: snapshot)
        #expect(try await metadata.noteCount() == 1)
        #expect(try await metadata.textIndexCount() == 0)
    }

    // MARK: - Search-side cache

    @Test("The title cache notices new notes without being told")
    func titleCacheRevalidates() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("First", body: "alpha")
        let stack = try await temp.searchStack()
        #expect(await stack.search.keyword("Second").isEmpty)

        try temp.writeExternal("# Second\n\nbeta\n", to: "Second.md")
        try await stack.watcher.reconcile()

        #expect(await stack.search.keyword("Second").titles == ["Second"])
    }
}
