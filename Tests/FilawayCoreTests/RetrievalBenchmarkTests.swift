import Foundation
import Testing

@testable import FilawayCore

/// M3-07 — the benchmark itself, end to end, with no model.
///
/// This is the variant that runs on every machine and every CI runner: the
/// deterministic ``HashedEmbedder`` stands in for Core ML, so the corpus, the
/// mtime stamping, the index build, both retrieval arms, RRF, the temporal
/// filter, the answer step and every metric are exercised whether or not the
/// `.mlpackage` is usable. The thresholds are deliberately loose — a hashed
/// bag-of-words is *not* a semantic model, and the numbers it produces are a
/// floor, not a target. ``RetrievalGateTests`` is where the real bar lives.
@Suite("Retrieval benchmark")
struct RetrievalBenchmarkTests {
    static func fixtures() throws -> ([CorpusNote], RetrievalQuerySet) {
        (try DevCorpus.load(), try RetrievalQuerySet.load())
    }

    @Test("the whole pipeline runs on the dev corpus with a model-free embedder")
    func endToEndWithHashedEmbedder() async throws {
        let (corpus, queries) = try Self.fixtures()
        let temp = try TempLibrary()
        let report = try await RetrievalBenchmark.run(
            corpus: corpus,
            queries: queries,
            library: temp.library,
            embedder: HashedEmbedder(identifier: "test:hashed/384d/v1", dimension: 384),
            configuration: .init(negativeVectorThreshold: 0.45),
            label: "hashed"
        )

        // The fixture half: nothing points into thin air.
        #expect(report.missingExpectedPaths.isEmpty)
        #expect(report.outcomes.count == queries.queries.count)
        #expect(report.noteCount == corpus.count)
        #expect(report.chunkCount > corpus.count, "every note should chunk into at least one piece")
        #expect(report.embeddingCount == report.chunkCount)

        // The retrieval half. Measured on this corpus at 70% / 83% / 0.78 /
        // 61%; the gates below leave room for the chunker moving underneath.
        let metrics = report.overall
        #expect(metrics.count >= 60)
        #expect(metrics.noteTop1 >= 0.55, "note top-1 \(metrics.noteTop1)")
        #expect(metrics.noteTop3 >= 0.72, "note top-3 \(metrics.noteTop3)")
        #expect(metrics.mrr >= 0.65, "MRR@10 \(metrics.mrr)")
        #expect(metrics.answerTop1 >= 0.45, "answer top-1 \(metrics.answerTop1)")
        #expect(metrics.answerCeiling >= metrics.answerTop1)

        // Every query really did run against the vector arm.
        #expect(report.outcomes.allSatisfy { $0.usedVectors })
        #expect(report.p95 < 1, "p95 \(report.p95)")
    }

    @Test("the temporal arm hard-filters, so a dated query cannot answer with the wrong week")
    func temporalQueriesFilter() async throws {
        let (corpus, queries) = try Self.fixtures()
        let temp = try TempLibrary()
        let report = try await RetrievalBenchmark.run(
            corpus: corpus, queries: queries, library: temp.library,
            embedder: HashedEmbedder(dimension: 384), label: "hashed"
        )
        let temporal = report.outcomes.filter { $0.category == .temporal }
        #expect(temporal.count >= 5)
        for outcome in temporal {
            #expect(outcome.parsedRange != nil, "\(outcome.id): no range parsed")
            #expect(outcome.rangeMatchedExpectation != false, "\(outcome.id): wrong range")
        }
        // FR-5.3 is a filter, not a bias: with a range applied, the expected
        // note is nearly always first, because almost nothing else survives.
        let metrics = RetrievalMetrics.over(temporal)
        #expect(metrics.noteTop1 >= 0.75, "temporal top-1 \(metrics.noteTop1)")
    }

    @Test("the BM25-only baseline still answers, and says it used no vectors")
    func keywordOnlyBaseline() async throws {
        let (corpus, queries) = try Self.fixtures()
        let temp = try TempLibrary()
        let report = try await RetrievalBenchmark.run(
            corpus: corpus, queries: queries, library: temp.library,
            embedder: HashedEmbedder(dimension: 384),
            configuration: .init(keywordOnly: true), label: "bm25"
        )
        #expect(report.outcomes.allSatisfy { $0.usedVectors == false })
        #expect(report.overall.noteTop1 >= 0.55, "BM25 top-1 \(report.overall.noteTop1)")
        // FR-5.5: keyword-only is a real, working mode, not a stub.
        #expect(report.overall.mrr >= 0.6)
    }

    @Test("the local answer heuristic prefers the winning note's code block")
    func localHeuristicPrefersCode() async throws {
        let selector = LocalHeuristicSelector()
        let prose = Self.chunk(id: 1, note: Self.noteA, kind: .prose, score: 0.9, text: "how to do the thing")
        let code = Self.chunk(id: 2, note: Self.noteA, kind: .code, score: 0.1, text: "do --the-thing")
        let otherCode = Self.chunk(id: 3, note: Self.noteB, kind: .code, score: 0.85, text: "something else")

        // The best chunk's own note wins, even when another note's code scores
        // far higher — that is the rule M3-07 measured into existence.
        #expect(await selector.selectChunk(query: "q", chunks: [prose, otherCode, code]) == 2)
        // A code chunk that is already on top is simply kept.
        #expect(await selector.selectChunk(query: "q", chunks: [otherCode, prose]) == 3)
        // Nothing to show is `nil`, never a crash.
        #expect(await selector.selectChunk(query: "q", chunks: []) == nil)
        // The cosine floor abstains — the FR-5.5 "no confident answer" path.
        let shy = LocalHeuristicSelector(minimumVectorScore: 0.95)
        #expect(await shy.selectChunk(query: "q", chunks: [prose, code]) == nil)
    }

    @Test("a replay record picks the chunk it names, and `answered: false` abstains")
    func replaySelector() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("filaway-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ record: ReplaySelector.Record, _ name: String) throws {
            try JSONEncoder().encode(record)
                .write(to: directory.appendingPathComponent("\(name).json"))
        }
        try write(.init(query: "find the thing", snippet: "do --the-thing"), "a")
        try write(.init(query: "nothing here", snippet: nil, answered: false), "b")

        let selector = ReplaySelector(directory: directory)
        let prose = Self.chunk(id: 1, note: Self.noteA, kind: .prose, score: 0.9, text: "how to do the thing")
        let code = Self.chunk(id: 2, note: Self.noteA, kind: .code, score: 0.1, text: "do --the-thing")
        #expect(await selector.selectChunk(query: "Find the thing", chunks: [prose, code]) == 2)
        #expect(await selector.selectChunk(query: "nothing here", chunks: [prose, code]) == nil)
        // An unrecorded query falls back rather than failing the whole run.
        #expect(await selector.selectChunk(query: "unrecorded", chunks: [prose, code]) == 2)
    }

    // MARK: - Support

    static let noteA = NoteID()
    static let noteB = NoteID()

    static func chunk(
        id: Int64, note: NoteID, kind: ChunkKind, score: Double, text: String
    ) -> RankedChunk {
        RankedChunk(
            id: id, noteID: note, title: "Note", relativePath: "Note.md", modified: Date(),
            kind: kind, headingPath: ["Note"], range: MatchRange(location: 0, length: 1),
            language: kind == .code ? "sh" : nil, text: text, score: score,
            vectorRank: 1, vectorScore: Float(score), keywordRank: nil
        )
    }
}
