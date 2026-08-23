import Foundation
import GRDB
import Testing

@testable import FilawayCore

/// M3-03 — the in-memory Float16 matrix and its top-k (plan §1 "Semantic index").
@Suite("VectorStore")
struct VectorStoreTests {
    // MARK: - Half-precision codec

    @Test("half-precision round-trips within its own resolution")
    func halfRoundTrip() throws {
        let original: [Float] = [0, 1, -1, 0.5, -0.25, 0.1, 65_504, -1e-4, 3.14159]
        let bytes = HalfVector.encode(original)
        #expect(bytes.count == original.count * 2)
        let decoded = try #require(HalfVector.decode(bytes, count: original.count))
        for (index, value) in original.enumerated() {
            // binary16 has ~3 decimal digits; relative error is ~1e-3.
            let tolerance = max(abs(value) * 1e-3, 1e-6)
            #expect(abs(decoded[index] - value) <= tolerance)
        }
    }

    @Test("a unit vector survives the round trip as a unit vector")
    func halfKeepsNormalisation() throws {
        let vector = HashedEmbedder.vector(for: "curl fetch documents json api", dimension: 384)
        let decoded = try #require(HalfVector.decode(HalfVector.encode(vector), count: vector.count))
        #expect(abs(EmbeddingMath.norm(decoded) - 1) < 1e-2)
        #expect(EmbeddingMath.dot(vector, decoded) > 0.9999)
    }

    @Test("a truncated blob decodes to nil rather than to garbage")
    func truncatedBlob() {
        let bytes = HalfVector.encode([1, 2, 3, 4])
        #expect(HalfVector.decode(bytes, count: 8) == nil)
        #expect(HalfVector.decode(Data(), count: 1) == nil)
    }

    // MARK: - Fixture

    /// A store over a synthetic `chunks`/`embeddings` pair, with the vectors
    /// kept alongside so the tests can compute a brute-force reference.
    struct Fixture {
        let temp: TempLibrary
        let metadata: MetadataStore
        let store: VectorStore
        let dimension: Int
        let modelID = "test:hashed/64d/v1"
        private(set) var vectors: [Int64: [Float]] = [:]
        private(set) var notes: [Int64: NoteID] = [:]

        init(chunks: Int, dimension: Int = 64, chunksPerNote: Int = 4) throws {
            temp = try TempLibrary()
            metadata = try temp.metadataStore()
            self.dimension = dimension
            store = VectorStore(reader: metadata.reader, modelID: modelID, dimension: dimension)

            var noteIDs: [NoteID] = []
            for index in 0 ..< max(1, chunks / chunksPerNote + 1) {
                noteIDs.append(NoteID.derived(fromRelativePath: "Notes/note-\(index).md"))
            }
            // One transaction for the whole fixture: at 20,000 chunks a
            // transaction per row is a multi-second fsync storm that slows the
            // rest of the (parallel) suite down with it.
            let modelID = modelID
            var built: [(id: Int64, note: NoteID, vector: [Float])] = []
            try metadata.writer.write { db in
                for (offset, noteID) in noteIDs.enumerated() {
                    try db.execute(sql: """
                        INSERT INTO notes(id, relpath, folder_path, title, content_hash, mtime, size, created, tags)
                        VALUES(?, ?, '', ?, ?, ?, 0, 0, '[]')
                        """, arguments: [
                            noteID.uuidString, "Notes/note-\(offset).md", "note-\(offset)",
                            "hash-\(offset)", Double(1_700_000_000 + offset * 3_600),
                        ])
                }
                // Prepared statements, compiled once: a 20,000-row fixture is
                // about the *matrix*, and re-parsing two INSERTs 20,000 times
                // costs more than everything the test is measuring.
                let chunkStatement = try db.makeStatement(sql: """
                    INSERT INTO chunks(note_id, ordinal, kind, heading_path, range_start,
                                       range_length, text_hash, source_hash, text)
                    VALUES(?, ?, 'prose', '', 0, 1, ?, 'h', ?)
                    """)
                let embeddingStatement = try db.makeStatement(sql: """
                    INSERT INTO embeddings(chunk_id, model_id, dim, vector) VALUES(?, ?, ?, ?)
                    """)
                for index in 0 ..< chunks {
                    let noteID = noteIDs[index % noteIDs.count]
                    let text = "chunk \(index) about \(Self.topics[index % Self.topics.count])"
                    let vector = HashedEmbedder.vector(for: text, dimension: dimension)
                    try chunkStatement.execute(
                        arguments: [noteID.uuidString, index, Hashing.sha256Hex(text), text]
                    )
                    let rowID = db.lastInsertedRowID
                    try embeddingStatement.execute(
                        arguments: [rowID, modelID, dimension, HalfVector.encode(vector)]
                    )
                    built.append((rowID, noteID, vector))
                }
            }
            for entry in built {
                vectors[entry.id] = entry.vector
                notes[entry.id] = entry.note
            }
        }

        static let topics = [
            "docker compose logs", "postgres vacuum analyze", "swift concurrency actors",
            "curl accept json headers", "kubectl rollout restart", "rsync delete archive",
            "git rebase interactive", "jq items map select",
        ]

        func query(_ text: String) -> [Float] {
            HashedEmbedder.vector(for: text, dimension: dimension)
        }

        /// Brute force over Float32, straight from the vectors as generated.
        func reference(_ query: [Float], k: Int) -> [Int64] {
            referenceScores(query, k: k).map(\.id)
        }

        func referenceScores(_ query: [Float], k: Int) -> [(id: Int64, score: Float)] {
            var scored: [(id: Int64, score: Float)] = []
            scored.reserveCapacity(vectors.count)
            for (id, vector) in vectors {
                scored.append((id, EmbeddingMath.dot(query, vector)))
            }
            scored.sort { left, right in
                left.score == right.score ? left.id < right.id : left.score > right.score
            }
            return Array(scored.prefix(k))
        }
    }

    // MARK: - Loading

    @Test("loading is lazy and reports what it holds")
    func lazyLoad() async throws {
        let fixture = try Fixture(chunks: 40)
        #expect(await fixture.store.loaded == false)
        #expect(await fixture.store.count == 0)

        try await fixture.store.ensureLoaded()
        #expect(await fixture.store.loaded)
        #expect(await fixture.store.count == 40)

        let memory = await fixture.store.memory()
        #expect(memory.vectorCount == 40)
        #expect(memory.dimension == 64)
        #expect(memory.bytes >= 40 * 64 * 2)

        await fixture.store.unload()
        #expect(await fixture.store.loaded == false)
    }

    @Test("only the active model's vectors are loaded")
    func filtersByModel() async throws {
        let fixture = try Fixture(chunks: 10)
        try await fixture.metadata.writer.write { db in
            try db.execute(sql: """
                INSERT INTO embeddings(chunk_id, model_id, dim, vector)
                SELECT id, 'other:model', 64, zeroblob(128) FROM chunks
                """)
        }
        try await fixture.store.ensureLoaded()
        #expect(await fixture.store.count == 10)
    }

    // MARK: - Correctness

    @Test("top-k matches a brute-force Float32 reference")
    func topKMatchesReference() async throws {
        let fixture = try Fixture(chunks: 500)
        try await fixture.store.ensureLoaded()
        for text in Fixture.topics + ["something entirely unrelated to any of it"] {
            let query = fixture.query(text)
            let actual = try await fixture.store.topK(query, k: 10)
            let expected = fixture.referenceScores(query, k: 10)
            #expect(actual.count == expected.count)
            #expect(actual.first?.chunkID == expected.first?.id)
            // Float16 rounds at the third decimal, so two chunks whose Float32
            // scores are within that can swap places. What must hold is that
            // the *scores* the store returns are the reference scores: no worse
            // chunk ever displaces a better one by more than the rounding.
            for (index, hit) in actual.enumerated() {
                #expect(abs(hit.score - expected[index].score) < 5e-3)
            }
        }
    }

    @Test("the store's own Float32 reference agrees with its blocked path")
    func blockedPathAgreesWithReference() async throws {
        // More rows than one block, so the block loop actually iterates.
        let fixture = try Fixture(chunks: VectorStore.blockRows + 137)
        try await fixture.store.ensureLoaded()
        let query = fixture.query("docker compose logs follow app")
        let fast = try await fixture.store.topK(query, k: 25)
        let slow = try await fixture.store.referenceTopK(query, k: 25)
        #expect(fast.count == slow.count)
        // `vDSP_mmul` and `vDSP.dot` accumulate in different orders, so an
        // exact tie can land either way; the score sequence must still match.
        for (index, hit) in fast.enumerated() {
            #expect(abs(hit.score - slow[index].score) < 1e-5)
        }
        #expect(fast.first?.chunkID == slow.first?.chunkID)
    }

    @Test("scores are cosines in [-1, 1] and sorted best first")
    func scoresAreSortedCosines() async throws {
        let fixture = try Fixture(chunks: 200)
        try await fixture.store.ensureLoaded()
        let hits = try await fixture.store.topK(fixture.query("swift concurrency actors"), k: 20)
        #expect(hits.count == 20)
        #expect(hits.allSatisfy { $0.score >= -1.001 && $0.score <= 1.001 })
        for index in 1 ..< hits.count {
            #expect(hits[index - 1].score >= hits[index].score)
        }
    }

    @Test("k larger than the corpus returns everything")
    func kLargerThanCorpus() async throws {
        let fixture = try Fixture(chunks: 7)
        try await fixture.store.ensureLoaded()
        #expect(try await fixture.store.topK(fixture.query("anything"), k: 100).count == 7)
        #expect(try await fixture.store.topK(fixture.query("anything"), k: 0).isEmpty)
    }

    @Test("an empty store answers without loading anything")
    func emptyStore() async throws {
        let fixture = try Fixture(chunks: 0)
        #expect(try await fixture.store.topK([Float](repeating: 0, count: 64), k: 5).isEmpty)
        #expect(await fixture.store.count == 0)
    }

    @Test("a query of the wrong dimension is refused, not crashed on")
    func wrongDimension() async throws {
        let fixture = try Fixture(chunks: 10)
        #expect(try await fixture.store.topK([1, 2, 3], k: 5).isEmpty)
    }

    // MARK: - Filtering

    @Test("the note filter is applied before the cut, not after")
    func noteFilterAppliesBeforeTheCut() async throws {
        let fixture = try Fixture(chunks: 200, chunksPerNote: 4)
        try await fixture.store.ensureLoaded()
        let query = fixture.query("kubectl rollout restart deployment")

        let unfiltered = try await fixture.store.topK(query, k: 5)
        let target = try #require(unfiltered.last?.noteID)
        // Restrict to a single note that is *not* the strongest match: the hits
        // must all come from it, and there must still be some.
        let filtered = try await fixture.store.topK(query, k: 5, allow: { $0 == target })
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { $0.noteID == target })

        // A filter that admits nothing yields nothing.
        #expect(try await fixture.store.topK(query, k: 5, allow: { _ in false }).isEmpty)
    }

    // MARK: - Incremental maintenance

    @Test("upsert adds, replaces and reuses tombstoned slots")
    func upsertAndRemove() async throws {
        let fixture = try Fixture(chunks: 20)
        try await fixture.store.ensureLoaded()
        let noteID = NoteID()

        // Add.
        let fresh = HashedEmbedder.vector(for: "a brand new chunk about widgets", dimension: 64)
        await fixture.store.apply(upserts: [.init(chunkID: 9_001, noteID: noteID, vector: fresh)])
        #expect(await fixture.store.count == 21)
        let found = try await fixture.store.topK(fresh, k: 1)
        #expect(found.first?.chunkID == 9_001)
        #expect(found.first?.score ?? 0 > 0.99)

        // Replace in place.
        let replacement = HashedEmbedder.vector(for: "a completely different subject matter", dimension: 64)
        await fixture.store.apply(upserts: [.init(chunkID: 9_001, noteID: noteID, vector: replacement)])
        #expect(await fixture.store.count == 21)
        #expect(try await fixture.store.topK(replacement, k: 1).first?.chunkID == 9_001)

        // Remove, then add again — the freed slot is reused, not appended.
        await fixture.store.remove(chunkIDs: [9_001])
        #expect(await fixture.store.count == 20)
        #expect(try await fixture.store.topK(replacement, k: 25).allSatisfy { $0.chunkID != 9_001 })

        let slotsBefore = await fixture.store.memory().slotCount
        await fixture.store.apply(upserts: [.init(chunkID: 9_002, noteID: noteID, vector: fresh)])
        #expect(await fixture.store.memory().slotCount == slotsBefore)
        #expect(await fixture.store.count == 21)
    }

    @Test("removing a note removes all of its chunks")
    func removeNote() async throws {
        let fixture = try Fixture(chunks: 40, chunksPerNote: 4)
        try await fixture.store.ensureLoaded()
        let before = await fixture.store.count
        let victim = try #require(fixture.notes.values.first)
        let victimChunks = fixture.notes.filter { $0.value == victim }.count

        await fixture.store.removeNotes([victim])
        #expect(await fixture.store.count == before - victimChunks)
        let hits = try await fixture.store.topK(fixture.query("docker compose"), k: 40)
        #expect(hits.allSatisfy { $0.noteID != victim })
    }

    @Test("a mismatched upsert dimension is ignored rather than corrupting the matrix")
    func mismatchedUpsertIsIgnored() async throws {
        let fixture = try Fixture(chunks: 5)
        try await fixture.store.ensureLoaded()
        await fixture.store.apply(upserts: [.init(chunkID: 42, noteID: NoteID(), vector: [1, 2, 3])])
        #expect(await fixture.store.count == 5)
    }

    @Test("growth past the initial capacity keeps every earlier vector intact")
    func growthPreservesVectors() async throws {
        let fixture = try Fixture(chunks: 4)
        try await fixture.store.ensureLoaded()
        let first = try #require(fixture.vectors.keys.sorted().first)
        let original = try #require(fixture.vectors[first])

        let noteID = NoteID()
        let filler = (0 ..< 3_000).map { index in
            VectorStore.Upsert(
                chunkID: Int64(100_000 + index),
                noteID: noteID,
                vector: HashedEmbedder.vector(for: "filler chunk number \(index)", dimension: 64)
            )
        }
        // In batches, so the doubling growth path runs several times rather
        // than once — while still costing three actor hops, not 3,000.
        for batch in stride(from: 0, to: filler.count, by: 1_000) {
            await fixture.store.apply(
                upserts: Array(filler[batch ..< min(batch + 1_000, filler.count)])
            )
        }
        #expect(await fixture.store.count == 3_004)
        let recovered = try #require(try await fixture.store.vector(forChunk: first))
        #expect(EmbeddingMath.dot(original, recovered) > 0.999)
    }

    // MARK: - Scale

    @Test("20,000 chunks fit the documented memory budget", .tags(.slow),
          .enabled(if: TestEnvironment.runsSlowTests))
    func memoryAtScale() async throws {
        let fixture = try Fixture(chunks: 20_000, dimension: 384)
        try await fixture.store.ensureLoaded()
        let memory = await fixture.store.memory()
        #expect(memory.vectorCount == 20_000)
        // 20,000 × 384 × 2 B = 14.6 MB of halves, plus side arrays. A load
        // sizes the allocation exactly, so there is no doubling slack.
        #expect(memory.megabytes < 20)
        #expect(memory.megabytes > 14)

        let query = fixture.query("kubectl rollout restart deployment checkout")
        let hits = try await fixture.store.topK(query, k: 50)
        #expect(hits.count == 50)
        #expect(hits.first?.chunkID == fixture.reference(query, k: 1).first)
    }
}
