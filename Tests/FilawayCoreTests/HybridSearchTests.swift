import Foundation
import GRDB
import Testing

@testable import FilawayCore

/// M3-03 — reciprocal rank fusion, on its own.
@Suite("Reciprocal rank fusion")
struct HybridFusionTests {
    /// A direct model of what ``HybridSearch`` does, so the ordering rules can
    /// be asserted without a database.
    static func rrf(_ lists: [[Int]], k: Double = 60) -> [Int] {
        var scores: [Int: Double] = [:]
        for list in lists {
            for (index, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(index + 1))
            }
        }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    @Test("a document both retrievers like beats one either likes alone")
    func consensusWins() {
        // 7 is second on both lists; 1 and 2 are first on one list each.
        let fused = Self.rrf([[1, 7, 3], [2, 7, 4]])
        #expect(fused.first == 7)
    }

    @Test("a single list is passed through unchanged")
    func singleList() {
        #expect(Self.rrf([[5, 9, 1, 3]]) == [5, 9, 1, 3])
    }

    @Test("k controls how flat the fusion is")
    func kFlattensTheCurve() {
        // With a small k, being first somewhere is worth a great deal.
        #expect(Self.rrf([[1, 7], [2, 7]], k: 1).first == 7)
        // 1/(1+1) + 0 = 0.5 for id 1; 1/(1+2) * 2 = 0.667 for id 7.
        let sharp = Self.rrf([[1, 2, 3, 4, 5, 6, 7, 8, 9, 10], [11, 12, 13, 1]], k: 1)
        #expect(sharp.first == 1)
    }

    @Test("everything present is ranked, nothing is dropped")
    func unionIsComplete() {
        let fused = Self.rrf([[1, 2], [3, 4]])
        #expect(Set(fused) == [1, 2, 3, 4])
    }
}

/// M3-03 — the whole offline retrieval path (FR-5.1, FR-5.3, FR-5.5).
@Suite("HybridSearch")
struct HybridSearchTests {
    struct Fixture {
        let temp: TempLibrary
        let metadata: MetadataStore
        let embedder: HashedEmbedder
        let vectors: VectorStore
        let indexer: Indexer
        let hybrid: HybridSearch

        init(withVectors: Bool = true, calendar: Calendar = HybridSearchTests.calendar) throws {
            temp = try TempLibrary()
            metadata = try temp.metadataStore()
            embedder = HashedEmbedder(
                dimension: 256, queryPrefix: "Represent this sentence for searching relevant passages: "
            )
            vectors = VectorStore(
                reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
            )
            indexer = Indexer(
                metadata: metadata, embedder: embedder, vectorStore: vectors,
                configuration: .init(debounce: .zero)
            )
            hybrid = HybridSearch(
                metadata: metadata,
                embedder: withVectors ? embedder : nil,
                vectorStore: withVectors ? vectors : nil,
                parser: TemporalQueryParser(calendar: calendar)
            )
        }

        @discardableResult
        func addNote(_ relativePath: String, _ body: String, modified: Date? = nil) async throws -> NoteSummary {
            try temp.writeExternal(body, to: relativePath)
            if let modified {
                try FileManager.default.setAttributes(
                    [.modificationDate: modified], ofItemAtPath: temp.url(relativePath).path
                )
            }
            let snapshot = try await temp.store.scan()
            try await metadata.upsert(snapshot.notes)
            return try #require(try await metadata.note(relativePath: relativePath))
        }

        func indexEverything() async throws {
            _ = try await indexer.catchUp()
            try await vectors.reload()
            await hybrid.invalidate()
        }
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 12
        components.hour = 14
        return calendar.date(from: components)!
    }()

    static func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// A miniature developer library, the kind FR-5.1/5.2 describe.
    static let corpus: [(path: String, body: String, ageDays: Int)] = [
        ("Commands/curl.md", """
        # Fetch documents

        The documents endpoint is paginated and needs a bearer token.

        ```sh
        curl -sSL -H 'Accept: application/json' \\
             -H "Authorization: Bearer $API_TOKEN" \\
             https://example.com/api/documents | jq '.items[]'
        ```

        The cursor comes back in the Link header.
        """, 30),

        ("Commands/docker.md", """
        # Rebuild the stack

        Bring the compose stack up from scratch when the image drifted.

        ```sh
        docker compose up -d --build && docker compose logs -f app
        ```
        """, 2),

        ("Infra/postgres.md", """
        # Vacuum the database

        Autovacuum falls behind on the events table during a backfill.

        ```sh
        psql -h localhost -U filaway -c 'vacuum analyze events;'
        ```
        """, 200),

        ("Meetings/auth-review.md", """
        # Auth review

        We agreed the bearer token should be rotated by the gateway, not by each
        service, and that the refresh window stays at fifteen minutes.
        """, 2),

        ("Ideas/ranking.md", """
        # Ranking notes

        Ranking improved once recency stopped dominating the score entirely.
        """, 400),
    ]

    static func makeIndexedFixture(withVectors: Bool = true) async throws -> Fixture {
        let fixture = try Fixture(withVectors: withVectors)
        for entry in corpus {
            try await fixture.addNote(entry.path, entry.body, modified: daysAgo(entry.ageDays))
        }
        try await fixture.indexEverything()
        return fixture
    }

    // MARK: - Retrieval

    @Test("a natural-language question finds the note that answers it")
    func findsTheAnsweringNote() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "curl command to fetch documents", now: Self.now
        )
        #expect(results.usedVectors)
        #expect(!results.isEmpty)
        #expect(results.notes.first?.relativePath == "Commands/curl.md")
        #expect(results.chunks.first?.noteID == results.notes.first?.id)
    }

    @Test("the best chunk carries a range that opens the note at the command")
    func bestChunkHasAUsableRange() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "curl command to fetch documents", now: Self.now
        )
        let note = try #require(results.notes.first)
        let body = try #require(try await fixture.metadata.text(id: note.id)).body
        let slice = try #require(note.bestChunk.range.substring(in: body))
        #expect(!slice.isEmpty)
        #expect(body.utf16.count >= note.bestChunk.range.upperBound)
    }

    @Test("a code chunk is retrievable as a code chunk")
    func codeChunksAreDistinguished() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "docker compose up build logs", now: Self.now
        )
        let code = try #require(results.chunks.first { $0.kind == .code })
        #expect(code.language == "sh")
        #expect(code.text.contains("docker compose"))
        #expect(code.headingBreadcrumb.contains("Rebuild the stack"))
    }

    @Test("results are sorted, deduplicated by note, and capped")
    func shapeOfTheResults() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "token",
            options: .init(chunkLimit: 5, noteLimit: 3),
            now: Self.now
        )
        #expect(results.chunks.count <= 5)
        #expect(results.notes.count <= 3)
        #expect(Set(results.notes.map(\.id)).count == results.notes.count)
        for index in 1 ..< max(1, results.chunks.count) {
            #expect(results.chunks[index - 1].score >= results.chunks[index].score)
        }
        for index in 1 ..< max(1, results.notes.count) {
            #expect(results.notes[index - 1].score >= results.notes[index].score)
        }
    }

    @Test("the prompt slice M3-05 consumes is the top eight chunks")
    func promptChunks() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates("bearer token rotation", now: Self.now)
        #expect(results.promptChunks.count <= 8)
        #expect(results.promptChunks == Array(results.chunks.prefix(8)))
        #expect(results.promptChunks.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: - Fusion behaviour

    @Test("both arms contribute, and a consensus chunk is marked as one")
    func bothArmsContribute() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "vacuum analyze events postgres", now: Self.now
        )
        #expect(results.chunks.contains { $0.vectorRank != nil })
        #expect(results.chunks.contains { $0.keywordRank != nil })
        #expect(results.chunks.contains { $0.isConsensus })
        // A consensus chunk should be at or near the top.
        let consensusIndex = results.chunks.firstIndex(where: \.isConsensus)
        #expect(consensusIndex == 0)
    }

    @Test("without an embedder the search still works, on BM25 alone (FR-5.5)")
    func keywordOnlyDegradation() async throws {
        let fixture = try await Self.makeIndexedFixture(withVectors: false)
        #expect(await fixture.hybrid.supportsVectors == false)
        let results = await fixture.hybrid.semanticCandidates(
            "vacuum analyze events", now: Self.now
        )
        #expect(!results.usedVectors)
        #expect(!results.isEmpty)
        #expect(results.notes.first?.relativePath == "Infra/postgres.md")
        #expect(results.chunks.allSatisfy { $0.vectorRank == nil })
    }

    @Test("the keyword arm ORs its terms, so a long question still matches")
    func keywordArmUsesOr() {
        let expression = try! #require(HybridSearch.orExpression(for: "what was the curl command for documents"))
        #expect(expression.contains(" OR "))
        #expect(!expression.contains(" AND "))
        #expect(expression.contains("\"documents\""))
        #expect(expression.contains("\"curl\""))
        // Stopwords do not spend the term budget.
        #expect(!expression.contains("\"the\""))
        #expect(!expression.contains("\"was\""))
    }

    @Test("a query of pure stopwords still produces an expression")
    func stopwordOnlyQuery() {
        #expect(HybridSearch.orExpression(for: "what is it") != nil)
        #expect(HybridSearch.orExpression(for: "   ") == nil)
        #expect(HybridSearch.orExpression(for: "!!!") == nil)
    }

    // MARK: - Temporal (FR-5.3)

    @Test("a parsed date range hard-filters the results")
    func temporalHardFilter() async throws {
        let fixture = try await Self.makeIndexedFixture()
        // Both the docker note and the auth note were touched two days ago.
        let results = await fixture.hybrid.semanticCandidates(
            "the thing I edited two days ago about auth", now: Self.now
        )
        #expect(results.dateRange != nil)
        #expect(results.strippedQuery == "the thing I edited about auth")
        #expect(!results.isEmpty)
        #expect(results.notes.first?.relativePath == "Meetings/auth-review.md")
        // Nothing outside the window may appear at all.
        for note in results.notes {
            #expect(results.dateRange?.contains(note.modified) == true)
        }
    }

    @Test("a date range with nothing in it returns nothing rather than the wrong thing")
    func emptyDateRange() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "the curl command from yesterday", now: Self.now
        )
        #expect(results.dateRange != nil)
        #expect(results.isEmpty)
    }

    @Test("`recently` biases without filtering")
    func recentlyIsASoftBoost() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let plain = await fixture.hybrid.semanticCandidates("ranking score", now: Self.now)
        let recent = await fixture.hybrid.semanticCandidates("ranking score recently", now: Self.now)
        #expect(recent.dateRange == nil)
        // The 400-day-old ranking note is still reachable; it is just weighted
        // down relative to a fresh note.
        #expect(!recent.isEmpty)
        let old = try #require(plain.notes.first { $0.relativePath == "Ideas/ranking.md" })
        let boosted = recent.notes.first { $0.relativePath == "Ideas/ranking.md" }
        if let boosted {
            #expect(boosted.score <= old.score * 1.0001)
        }
    }

    @Test("an explicit range in the options overrides the parsed one")
    func explicitRangeOverrides() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let range = DateRange(
            start: Self.daysAgo(210), end: Self.daysAgo(190)
        )
        let results = await fixture.hybrid.semanticCandidates(
            "the command from yesterday",
            options: .init(dateRange: range),
            now: Self.now
        )
        #expect(results.dateRange == range)
        #expect(results.notes.allSatisfy { $0.relativePath == "Infra/postgres.md" })
    }

    @Test("the recency prior nudges a tie but never overturns relevance")
    func recencyIsMild() async throws {
        let fixture = try await Self.makeIndexedFixture()
        // The postgres note is 200 days old and is the only real answer here.
        let results = await fixture.hybrid.semanticCandidates(
            "vacuum analyze events autovacuum backfill", now: Self.now
        )
        #expect(results.notes.first?.relativePath == "Infra/postgres.md")
    }

    // MARK: - Filters

    @Test("excluded folders never appear in results (FR-4.5)")
    func exclusionsAreEnforced() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let options = HybridSearch.Options(exclusions: ExclusionFilter(excludedFolders: ["Infra"]))
        let results = await fixture.hybrid.semanticCandidates(
            "vacuum analyze events", options: options, now: Self.now
        )
        #expect(results.notes.allSatisfy { !$0.relativePath.hasPrefix("Infra/") })
        #expect(results.chunks.allSatisfy { !$0.relativePath.hasPrefix("Infra/") })
    }

    @Test("a folder scope restricts both arms")
    func folderScope() async throws {
        let fixture = try await Self.makeIndexedFixture()
        let results = await fixture.hybrid.semanticCandidates(
            "token",
            options: .init(folderPath: "Commands"),
            now: Self.now
        )
        #expect(!results.isEmpty)
        #expect(results.notes.allSatisfy { $0.relativePath.hasPrefix("Commands/") })
    }

    // MARK: - Freshness and edge cases

    @Test("an edit is retrievable as soon as it is indexed (FR-5.4)")
    func freshEditIsRetrievable() async throws {
        let fixture = try await Self.makeIndexedFixture()
        // A vector search always returns *something* — that is what top-k
        // means — so the assertion is about identity, not emptiness.
        let before = await fixture.hybrid.semanticCandidates("mysterious kumquat protocol", now: Self.now)
        #expect(before.notes.allSatisfy { $0.relativePath != "Ideas/kumquat.md" })

        try await fixture.addNote(
            "Ideas/kumquat.md",
            "# Kumquat\n\nThe mysterious kumquat protocol negotiates over UDP, apparently.",
            modified: Self.daysAgo(0)
        )
        _ = try await fixture.indexer.catchUp()
        await fixture.hybrid.invalidate()

        let results = await fixture.hybrid.semanticCandidates("mysterious kumquat protocol", now: Self.now)
        #expect(results.notes.first?.relativePath == "Ideas/kumquat.md")
    }

    @Test("an empty query returns nothing rather than everything")
    func emptyQuery() async throws {
        let fixture = try await Self.makeIndexedFixture()
        #expect(await fixture.hybrid.semanticCandidates("", now: Self.now).isEmpty)
        #expect(await fixture.hybrid.semanticCandidates("   ", now: Self.now).isEmpty)
    }

    @Test("an empty index answers empty rather than failing")
    func emptyIndex() async throws {
        let fixture = try Fixture()
        let results = await fixture.hybrid.semanticCandidates("anything at all", now: Self.now)
        #expect(results.isEmpty)
        #expect(results.notes.isEmpty)
    }

    @Test("the query prefix is applied to the query and never to a chunk")
    func queryPrefixIsQueryOnly() async throws {
        let fixture = try await Self.makeIndexedFixture()
        // Every stored chunk text is the raw note text.
        let texts = try await fixture.metadata.reader.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM chunks")
        }
        #expect(texts.allSatisfy { !$0.contains("Represent this sentence") })
        #expect(!fixture.embedder.queryPrefix.isEmpty)
    }
}
