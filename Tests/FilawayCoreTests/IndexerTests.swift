import Foundation
import GRDB
import Testing

@testable import FilawayCore

/// M3-02 — the incremental semantic indexer (FR-5.4).
@Suite("Indexer")
struct IndexerTests {
    // MARK: - Fixture

    /// A temp library with a metadata store, an indexer and a vector store, all
    /// running on the deterministic ``HashedEmbedder``.
    struct Fixture {
        let temp: TempLibrary
        let metadata: MetadataStore
        let embedder: HashedEmbedder
        let vectors: VectorStore
        let indexer: Indexer

        init(
            embedder: HashedEmbedder = HashedEmbedder(),
            debounce: Duration = .zero,
            isExcluded: @escaping @Sendable (String) -> Bool = { _ in false }
        ) throws {
            temp = try TempLibrary()
            metadata = try temp.metadataStore()
            self.embedder = embedder
            vectors = VectorStore(
                reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
            )
            indexer = Indexer(
                metadata: metadata,
                embedder: embedder,
                vectorStore: vectors,
                configuration: .init(debounce: debounce, pollInterval: .milliseconds(10)),
                isExcluded: isExcluded
            )
        }

        /// Writes a note to disk and pushes it through the metadata store, the
        /// way a save or a reconcile would.
        ///
        /// Deliberately `upsert`, not `rebuild`: `rebuild` deletes every row of
        /// `notes`, and `chunks` cascades from it, so a rebuild throws the
        /// semantic index away by design. The incremental path is the one under
        /// test here.
        @discardableResult
        func addNote(_ relativePath: String, _ body: String) async throws -> NoteSummary {
            try temp.writeExternal(body, to: relativePath)
            try await rescan()
            return try #require(try await metadata.note(relativePath: relativePath))
        }

        func rescan() async throws {
            let snapshot = try await temp.store.scan()
            try await metadata.upsert(snapshot.notes)
            let live = Set(snapshot.notes.map(\.relativePath))
            for note in try await metadata.allNotes() where !live.contains(note.relativePath) {
                try await metadata.remove(id: note.id)
            }
        }

        func chunkRows(of note: NoteSummary) async throws -> [(id: Int64, hash: String, ordinal: Int)] {
            try await metadata.reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, text_hash, ordinal FROM chunks WHERE note_id = ? ORDER BY ordinal
                    """, arguments: [note.id.uuidString])
                    .map { (id: $0["id"], hash: $0["text_hash"], ordinal: $0["ordinal"]) }
            }
        }
    }

    static let curlNote = """
    # Fetch documents

    Notes on the documents endpoint.

    ## Fetching

    Use this when you want raw JSON.

    ```sh
    curl -sSL -H 'Accept: application/json' https://example.com/api/documents | jq '.items[]'
    ```

    ## Pagination

    The cursor comes back in the Link header, which is easy to forget entirely.
    """

    // MARK: - Basics

    @Test("indexing a note writes chunks and one vector per chunk")
    func indexesANote() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)

        let report = try await fixture.indexer.index(noteID: note.id)
        #expect(report.notesIndexed == 1)
        #expect(report.chunksInserted > 1)
        #expect(report.embeddingsComputed == report.chunksInserted)

        let chunks = try await fixture.chunkRows(of: note)
        #expect(chunks.count == report.chunksInserted)
        #expect(chunks.map(\.ordinal) == Array(0 ..< chunks.count))
        #expect(try await fixture.indexer.embeddingCount() == chunks.count)

        // The code block is there, as its own chunk.
        let stored = try await fixture.metadata.reader.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM chunks WHERE kind = 'code'")
        }
        #expect(stored.contains { $0.contains("curl -sSL") })
    }

    @Test("the vector store sees the note without a reload")
    func vectorStoreIsUpdatedIncrementally() async throws {
        let fixture = try Fixture()
        try await fixture.vectors.ensureLoaded()
        #expect(await fixture.vectors.count == 0)

        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)

        let count = await fixture.vectors.count
        #expect(count > 1)
        let hits = try await fixture.vectors.topK(
            fixture.embedder.vector(for: "curl documents json"), k: 3
        )
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.noteID == note.id })
    }

    // MARK: - Incremental behaviour

    @Test("editing one section re-embeds only the chunks that changed")
    func incrementalReindex() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)
        let before = try await fixture.chunkRows(of: note)

        let edited = Self.curlNote.replacingOccurrences(
            of: "The cursor comes back in the Link header, which is easy to forget entirely.",
            with: "The cursor arrives in the Link header and expires after five minutes exactly."
        )
        try fixture.temp.writeExternal(edited, to: "Commands/curl.md")
        try await fixture.rescan()

        let report = try await fixture.indexer.index(noteID: note.id)
        #expect(report.notesIndexed == 1)
        // Exactly one chunk changed, so exactly one embedding was computed.
        #expect(report.embeddingsComputed == 1)
        #expect(report.chunksInserted == 1)
        #expect(report.chunksDeleted == 1)
        #expect(report.chunksReused == before.count - 1)

        let after = try await fixture.chunkRows(of: note)
        #expect(after.count == before.count)
        #expect(after.map(\.ordinal) == Array(0 ..< after.count))
        // Exactly one chunk's text is new; the rest are byte-identical.
        // (Row ids are not a witness here: SQLite hands a deleted `INTEGER
        // PRIMARY KEY` straight back to the next insert.)
        let kept = Set(after.map(\.hash)).intersection(Set(before.map(\.hash)))
        #expect(kept.count == before.count - 1)
    }

    @Test("inserting a paragraph at the top renumbers chunks but re-embeds almost nothing")
    func insertionShiftsOrdinalsWithoutReembedding() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)
        let before = try await fixture.chunkRows(of: note)

        try fixture.temp.writeExternal(
            "# Fetch documents\n\nA brand new opening paragraph that did not exist before at all.\n\n"
                + Self.curlNote.replacingOccurrences(of: "# Fetch documents\n\n", with: ""),
            to: "Commands/curl.md"
        )
        try await fixture.rescan()
        let report = try await fixture.indexer.index(noteID: note.id)

        // The code chunk and the pagination chunk are byte-identical, so they
        // must survive with their vectors.
        #expect(report.chunksReused >= before.count - 2)
        #expect(report.embeddingsComputed <= 2)
    }

    @Test("re-indexing an unchanged note is free")
    func reindexingUnchangedNoteIsFree() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)
        let report = try await fixture.indexer.index(noteID: note.id)
        #expect(report.embeddingsComputed == 0)
        #expect(report.chunksInserted == 0)
        #expect(report.chunksDeleted == 0)
    }

    @Test("deleting a note removes its chunks and its vectors")
    func deletingANote() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)
        try await fixture.vectors.ensureLoaded()
        #expect(await fixture.vectors.count > 0)

        try fixture.temp.removeExternal("Commands/curl.md")
        try await fixture.rescan()
        await fixture.indexer.apply([.removed(relativePath: "Commands/curl.md", id: note.id)])

        // `chunks.note_id` cascades from `notes`, so the rebuild already
        // unindexed it.
        #expect(try await fixture.indexer.chunkCount() == 0)
        #expect(await fixture.vectors.count == 0)
    }

    @Test("moving a note keeps its chunks and its identity")
    func movingANote() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)
        let before = try await fixture.chunkRows(of: note)

        try fixture.temp.makeExternalFolder("Snippets")
        try fixture.temp.moveExternal("Commands/curl.md", to: "Snippets/curl.md")
        try await fixture.rescan()
        let moved = try #require(try await fixture.metadata.note(relativePath: "Snippets/curl.md"))
        try await fixture.indexer.index(noteID: moved.id)

        let after = try await fixture.chunkRows(of: moved)
        #expect(after.count == before.count)
        // The title is part of every chunk's heading path, and the filename is
        // the title (DS-1) — an unchanged filename means unchanged text.
        #expect(Set(after.map(\.hash)) == Set(before.map(\.hash)))
    }

    // MARK: - Exclusions (FR-4.5)

    @Test("an excluded folder is never indexed")
    func excludedFolderIsNeverIndexed() async throws {
        let exclusions = ExclusionFilter(excludedFolders: ["Private"])
        let fixture = try Fixture(isExcluded: { exclusions.isExcluded(path: $0) })
        let open = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        let secret = try await fixture.addNote("Private/salary.md", "# Salary\n\nA very private number here.")

        await fixture.indexer.markDirty([open.id, secret.id])
        let report = try await fixture.indexer.drain()
        #expect(report.notesIndexed == 1)
        #expect(report.notesPurged == 1)

        let texts = try await fixture.metadata.reader.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM chunks")
        }
        #expect(!texts.contains { $0.contains("private number") })
        #expect(!texts.contains { $0.contains("Salary") })
    }

    @Test("excluding a folder after the fact purges what was already indexed")
    func excludingLaterPurges() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Private/salary.md", "# Salary\n\nA very private number here.")
        try await fixture.indexer.index(noteID: note.id)
        #expect(try await fixture.indexer.chunkCount() > 0)

        let exclusions = ExclusionFilter(excludedFolders: ["Private"])
        let stricter = Indexer(
            metadata: fixture.metadata,
            embedder: fixture.embedder,
            vectorStore: fixture.vectors,
            configuration: .init(debounce: .zero),
            isExcluded: { exclusions.isExcluded(path: $0) }
        )
        let report = try await stricter.index(noteID: note.id)
        #expect(report.notesPurged == 1)
        #expect(try await stricter.chunkCount() == 0)
    }

    // MARK: - Model changes

    @Test("a model change re-embeds the library but keeps the chunks")
    func modelChangeTriggersFullReindex() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.synchronizeModel()
        try await fixture.indexer.index(noteID: note.id)
        let before = try await fixture.chunkRows(of: note)
        #expect(before.count > 1)

        // Same store, different model.
        let other = HashedEmbedder(identifier: "test:hashed/32d/v1", dimension: 32)
        let migrated = Indexer(
            metadata: fixture.metadata,
            embedder: other,
            configuration: .init(debounce: .zero)
        )
        #expect(try await migrated.synchronizeModel())
        #expect(await migrated.pendingCount == 1)
        // Nothing is embedded with the new model yet.
        #expect(try await migrated.embeddingCount() == 0)

        let report = try await migrated.drain()
        #expect(report.embeddingsComputed == before.count)
        #expect(try await migrated.embeddingCount() == before.count)

        // Chunk *rows* survived; only the vectors were replaced.
        let after = try await fixture.chunkRows(of: note)
        #expect(Set(after.map(\.hash)) == Set(before.map(\.hash)))

        // And the old model's vectors are gone.
        let orphans = try await fixture.metadata.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings WHERE model_id <> ?",
                             arguments: [other.identifier]) ?? 0
        }
        #expect(orphans == 0)

        // A second call is a no-op.
        #expect(try await migrated.synchronizeModel() == false)
    }

    @Test("rebuildAll throws the index away and rebuilds it")
    func rebuildAll() async throws {
        let fixture = try Fixture()
        for index in 0 ..< 5 {
            try await fixture.addNote("Notes/note-\(index).md", "# Note \(index)\n\nSome prose about topic \(index).")
        }
        _ = try await fixture.indexer.rebuildAll()
        let first = try await fixture.indexer.chunkCount()
        #expect(first >= 5)

        let report = try await fixture.indexer.rebuildAll()
        #expect(report.notesIndexed == 5)
        #expect(report.chunksReused == 0)
        #expect(try await fixture.indexer.chunkCount() == first)
    }

    @Test("catchUp indexes only what is stale")
    func catchUpIsIncremental() async throws {
        let fixture = try Fixture()
        for index in 0 ..< 4 {
            try await fixture.addNote("Notes/note-\(index).md", "# Note \(index)\n\nSome prose about topic \(index).")
        }
        #expect(try await fixture.indexer.staleNoteIDs().count == 4)
        _ = try await fixture.indexer.catchUp()
        #expect(try await fixture.indexer.staleNoteIDs().isEmpty)
        #expect(try await fixture.indexer.catchUp() == IndexReport())

        try fixture.temp.writeExternal("# Note 2\n\nCompletely different prose now.", to: "Notes/note-2.md")
        try await fixture.rescan()
        #expect(try await fixture.indexer.staleNoteIDs().count == 1)
        let report = try await fixture.indexer.catchUp()
        #expect(report.notesIndexed == 1)
    }

    // MARK: - Queue and status

    @Test("the debounce loop coalesces a burst of saves")
    func debounceCoalescesSaves() async throws {
        // The real 2 s debounce, so the "not yet" window is wide enough to
        // survive a loaded machine running the whole suite in parallel.
        let fixture = try Fixture(debounce: .seconds(2))
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        let indexer = fixture.indexer
        await indexer.start()

        for _ in 0 ..< 5 {
            await indexer.markDirty(note.id)
            try await Task.sleep(for: .milliseconds(20))
        }
        // Five saves in ~100 ms, well inside one debounce window: the queue
        // holds exactly one note and nothing has been written.
        #expect(await indexer.pendingCount == 1)
        #expect(try await indexer.chunkCount() == 0)

        let indexed = await waitUntil(timeout: 15) {
            ((try? await indexer.chunkCount()) ?? 0) > 0
        }
        #expect(indexed)
        #expect(await indexer.pendingCount == 0)
        await indexer.stop()
    }

    @Test("status reports progress and returns to idle")
    func statusReportsProgress() async throws {
        let fixture = try Fixture()
        for index in 0 ..< 3 {
            try await fixture.addNote("Notes/note-\(index).md", "# Note \(index)\n\nProse for note \(index).")
        }
        #expect(await fixture.indexer.status == .idle)

        let stream = await fixture.indexer.statusStream()
        let collector = Task { () -> [IndexStatus] in
            var seen: [IndexStatus] = []
            for await status in stream {
                seen.append(status)
                if seen.count > 1, status == .idle { break }
            }
            return seen
        }
        _ = try await fixture.indexer.rebuildAll()
        let seen = await collector.value

        #expect(seen.first == .idle)
        #expect(seen.last == .idle)
        #expect(seen.contains { if case .reindexing = $0 { true } else { false } })
        #expect(await fixture.indexer.status == .idle)

        let progress = seen.compactMap(\.fraction)
        #expect(progress.contains { $0 > 0 })
        #expect(progress.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("a cancelled rebuild stops early and leaves the database consistent")
    func rebuildIsCancellable() async throws {
        let fixture = try Fixture()
        for index in 0 ..< 40 {
            try await fixture.addNote("Notes/note-\(index).md", "# Note \(index)\n\nProse for note \(index).")
        }
        let indexer = fixture.indexer
        let task = Task { try await indexer.rebuildAll() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // Whatever was written is still coherent: every chunk has a vector.
        let dangling = try await fixture.metadata.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chunks c
                WHERE NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.chunk_id = c.id)
                """) ?? 0
        }
        #expect(dangling == 0)
        #expect(await fixture.indexer.status == .idle)
    }

    @Test("a removed folder drops its notes' vectors from the matrix")
    func folderRemovalDropsVectors() async throws {
        let fixture = try Fixture()
        try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.addNote("Ideas/keep.md", "# Keep\n\nA note that survives the folder removal.")
        _ = try await fixture.indexer.catchUp()
        try await fixture.vectors.ensureLoaded()
        let before = await fixture.vectors.count
        #expect(before > 1)

        // A folder removal deletes its notes inside MetadataStore, by path —
        // there is no `.removed` change naming them.
        try fixture.temp.removeExternal("Commands")
        try await fixture.metadata.removeFolder("Commands")
        await fixture.indexer.apply([.folderRemoved("Commands")])

        let after = await fixture.vectors.count
        #expect(after < before)
        #expect(after > 0)
        let hits = try await fixture.vectors.topK(
            fixture.embedder.vector(for: "curl documents json"), k: 10
        )
        #expect(!hits.isEmpty)
        let survivors = try await fixture.metadata.allNotes().map(\.id)
        #expect(hits.allSatisfy { survivors.contains($0.noteID) })
    }

    @Test("watcher changes feed the queue")
    func watcherChangesFeedTheQueue() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        await fixture.indexer.apply([.modified(note)])
        #expect(await fixture.indexer.pendingCount == 1)
        let report = try await fixture.indexer.drain()
        #expect(report.notesIndexed == 1)
    }

    @Test("a note with no indexed text is skipped, not emptied")
    func noteWithoutTextIsSkipped() async throws {
        let fixture = try Fixture()
        let note = try await fixture.addNote("Commands/curl.md", Self.curlNote)
        try await fixture.indexer.index(noteID: note.id)
        let before = try await fixture.indexer.chunkCount()

        // Drop the text index the way `rebuild(indexingText: false)` would, and
        // delete the file so the on-disk fallback cannot find it either.
        try await fixture.metadata.writer.write { db in
            try db.execute(sql: "DELETE FROM note_text")
        }
        try fixture.temp.removeExternal("Commands/curl.md")

        let report = try await fixture.indexer.index(noteID: note.id)
        #expect(report.notesSkipped == 1)
        #expect(try await fixture.indexer.chunkCount() == before)
    }
}
