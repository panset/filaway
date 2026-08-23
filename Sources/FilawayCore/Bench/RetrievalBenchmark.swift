import Foundation

/// M3-07: does natural-language retrieval actually find the note, and does the
/// answer card show the right command?
///
/// ```swift
/// let report = try await RetrievalBenchmark.run(
///     corpus: DevCorpus.load(), queries: .load(), library: library, embedder: embedder
/// )
/// report.overall.noteTop1     // spec §8: ≥ 0.90
/// report.overall.answerTop1   // FR-5.2: the card shows the right chunk
/// ```
///
/// The run is: materialise the corpus into `library` **with its mtimes**, scan,
/// rebuild the metadata database, build the semantic index with `embedder`,
/// then push every query through `TemporalQueryParser` + `HybridSearch` and,
/// optionally, an ``AnswerSelecting`` step standing in for M3-05.
///
/// Nothing here touches the network. The Claude step is either absent (the
/// default local heuristic) or replayed.
public enum RetrievalBenchmark {
    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var candidateLimit: Int
        public var chunkLimit: Int
        public var noteLimit: Int
        public var rrfK: Double
        public var chunker: Chunker.Configuration
        /// Below this cosine, a query with no answer counts as correctly
        /// rejected. Measured, not guessed — ``RetrievalReport/separation``
        /// prints both distributions so the number can be re-derived after any
        /// change to the model or the chunker.
        ///
        /// M3-07's finding is that **the two distributions overlap**: on the
        /// development corpus answerable queries run 0.57–0.88 and
        /// unanswerable ones 0.59–0.70, so 0.70 rejects every negative at the
        /// cost of suppressing a third of the real answers. A cosine floor is
        /// therefore a backstop, not the mechanism — the abstain decision
        /// belongs to the answer step, which can read the chunks.
        public var negativeVectorThreshold: Float
        /// Queries run once before timing starts, to warm the caches.
        public var warmups: Int
        /// Repeat every query this many times and keep the best latency. The
        /// hit-rate metrics are unaffected; this only cleans up the timings.
        public var latencyRepeats: Int
        /// Skip the vector arm entirely — the BM25-only baseline.
        public var keywordOnly: Bool
        /// The soft recency multiplier ADR-040 applies when no hard date range
        /// was parsed. A benchmark knob because it is a *tuning* choice, and
        /// M3-07 is where it gets measured rather than assumed.
        public var recencyPrior: RecencyPrior
        /// How many chunks the answer step is shown. Eight is what
        /// `SemanticResults.promptChunks` hands M3-05; the knob exists because
        /// widening it is one of the cheap levers on answer accuracy.
        public var promptChunkCount: Int

        public init(
            candidateLimit: Int = 50,
            chunkLimit: Int = 20,
            noteLimit: Int = 10,
            rrfK: Double = 20,
            chunker: Chunker.Configuration = .init(),
            negativeVectorThreshold: Float = 0.70,
            warmups: Int = 3,
            latencyRepeats: Int = 1,
            keywordOnly: Bool = false,
            recencyPrior: RecencyPrior = .default,
            promptChunkCount: Int = SemanticResults.promptChunkLimit
        ) {
            self.candidateLimit = candidateLimit
            self.chunkLimit = chunkLimit
            self.noteLimit = noteLimit
            self.rrfK = rrfK
            self.chunker = chunker
            self.negativeVectorThreshold = negativeVectorThreshold
            self.warmups = warmups
            self.latencyRepeats = max(1, latencyRepeats)
            self.keywordOnly = keywordOnly
            self.recencyPrior = recencyPrior
            self.promptChunkCount = max(1, promptChunkCount)
        }
    }

    // MARK: - Running

    /// Builds an index over `corpus` in `library` and scores `queries` against it.
    public static func run(
        corpus: [CorpusNote],
        queries: RetrievalQuerySet,
        library: Library,
        embedder: any Embedder,
        selector: any AnswerSelecting = LocalHeuristicSelector(),
        configuration: Configuration = Configuration(),
        label: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RetrievalReport {
        let materializeStart = Date()
        try DevCorpus.materialize(corpus, into: library)
        progress?("corpus:   \(corpus.count) notes materialised in \(seconds(since: materializeStart))")

        let indexStart = Date()
        let snapshot = try await NoteStore(library: library).scan()
        try? FileManager.default.removeItem(at: library.databaseURL)
        let metadata = try MetadataStore(library: library)
        try await metadata.rebuild(from: snapshot)

        let vectors = VectorStore(
            reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
        )
        let indexer = Indexer(
            metadata: metadata,
            embedder: embedder,
            chunker: Chunker(configuration: configuration.chunker),
            vectorStore: vectors,
            configuration: .init(debounce: .zero)
        )
        let indexReport = try await indexer.rebuildAll()
        let indexSeconds = Date().timeIntervalSince(indexStart)

        let loadStart = Date()
        try await vectors.ensureLoaded()
        let matrixLoadSeconds = Date().timeIntervalSince(loadStart)
        let memory = await vectors.memory()
        progress?("index:    \(indexReport.chunksInserted) chunks over \(indexReport.notesIndexed) notes "
            + "in \(seconds(since: indexStart)), matrix \(memory.description)")

        let hybrid = HybridSearch(
            metadata: metadata,
            embedder: configuration.keywordOnly ? nil : embedder,
            vectorStore: configuration.keywordOnly ? nil : vectors,
            parser: TemporalQueryParser(calendar: queries.calendar)
        )
        let options = HybridSearch.Options(
            candidateLimit: configuration.candidateLimit,
            chunkLimit: configuration.chunkLimit,
            noteLimit: configuration.noteLimit,
            rrfK: configuration.rrfK,
            recencyPrior: configuration.recencyPrior
        )

        for query in queries.queries.prefix(configuration.warmups) {
            _ = await hybrid.semanticCandidates(query.text, options: options, now: queries.now(for: query))
        }

        // Every expected path must exist, or a "miss" is a fixture bug rather
        // than a retrieval one — and would be invisible in the numbers.
        let paths = Set(corpus.map(\.relativePath))
        var missingPaths: [String] = []

        var outcomes: [QueryOutcome] = []
        outcomes.reserveCapacity(queries.queries.count)
        for query in queries.queries {
            if let expected = query.expectedPath, !paths.contains(expected) {
                missingPaths.append(expected)
            }
            let now = queries.now(for: query)
            var best = TimeInterval.greatestFiniteMagnitude
            var results = SemanticResults.empty(query: query.text)
            for _ in 0 ..< configuration.latencyRepeats {
                let start = Date()
                results = await hybrid.semanticCandidates(query.text, options: options, now: now)
                best = min(best, Date().timeIntervalSince(start))
            }

            let promptChunks = Array(results.chunks.prefix(configuration.promptChunkCount))
            let selectStart = Date()
            let selected = await selector.selectChunk(query: query.text, chunks: promptChunks)
            let selectSeconds = Date().timeIntervalSince(selectStart)

            outcomes.append(outcome(
                for: query, results: results, promptChunks: promptChunks, selected: selected,
                retrievalSeconds: best, answerSeconds: selectSeconds,
                threshold: configuration.negativeVectorThreshold
            ))
        }

        return RetrievalReport(
            label: label ?? embedder.identifier,
            selectorLabel: selector.label,
            keywordOnly: configuration.keywordOnly,
            negativeVectorThreshold: configuration.negativeVectorThreshold,
            noteCount: corpus.count,
            goldenCount: corpus.filter(\.isGolden).count,
            chunkCount: indexReport.chunksInserted,
            embeddingCount: indexReport.embeddingsComputed,
            indexSeconds: indexSeconds,
            matrixLoadSeconds: matrixLoadSeconds,
            matrixBytes: memory.bytes,
            missingExpectedPaths: missingPaths.sorted(),
            outcomes: outcomes
        )
    }

    // MARK: - Scoring

    private static func outcome(
        for query: RetrievalQuery,
        results: SemanticResults,
        promptChunks: [RankedChunk],
        selected: Int64?,
        retrievalSeconds: TimeInterval,
        answerSeconds: TimeInterval,
        threshold: Float
    ) -> QueryOutcome {
        let noteRank = query.expectedPath.flatMap { expected in
            results.notes.firstIndex { $0.relativePath == expected }.map { $0 + 1 }
        }
        let chunkRank = query.expectedPath.flatMap { expected in
            results.chunks.firstIndex { $0.relativePath == expected }.map { $0 + 1 }
        }
        // Where the chunk that *contains the answer* ranked, which is a
        // different question from where its note ranked: a short note's prose
        // half matches a paraphrase, and its code half carries the command.
        var answerChunkRank: Int?
        if let snippet = query.expectedSnippet, let expected = query.expectedPath {
            let needle = collapse(snippet)
            answerChunkRank = results.chunks.firstIndex {
                $0.relativePath == expected && collapse($0.text).contains(needle)
            }.map { $0 + 1 }
        }

        var answerHit = false
        if let snippet = query.expectedSnippet, let selected,
           let chunk = results.chunks.first(where: { $0.id == selected }) {
            answerHit = collapse(chunk.text).contains(collapse(snippet))
                && chunk.relativePath == query.expectedPath
        }

        // The snippet is present *somewhere* in the retrieved set: separates
        // "retrieval never found it" from "the answer step picked the wrong
        // one of the eight it was given".
        var snippetInPrompt = false
        if let snippet = query.expectedSnippet {
            let needle = collapse(snippet)
            snippetInPrompt = promptChunks.contains {
                $0.relativePath == query.expectedPath && collapse($0.text).contains(needle)
            }
        }

        let topCosine = results.chunks.first?.vectorScore
        let rejected: Bool = if selected == nil {
            true
        } else if results.usedVectors {
            (topCosine ?? 0) < threshold
        } else {
            results.notes.isEmpty
        }

        return QueryOutcome(
            id: query.id,
            category: query.category,
            text: query.text,
            expectedPath: query.expectedPath,
            noteRank: noteRank,
            chunkRank: chunkRank,
            answerChunkRank: answerChunkRank,
            topNotePath: results.notes.first?.relativePath,
            answerHit: answerHit,
            snippetInPromptChunks: snippetInPrompt,
            selectedChunkID: selected,
            topScore: results.chunks.first?.score ?? 0,
            topVectorScore: topCosine,
            rejected: rejected,
            rangeMatchedExpectation: query.expectedRange.map { $0.dateRange == results.dateRange },
            parsedRange: results.dateRange,
            usedVectors: results.usedVectors,
            retrievalSeconds: retrievalSeconds,
            answerSeconds: answerSeconds
        )
    }

    /// Whitespace-insensitive comparison, so a snippet that the note wraps over
    /// two lines still matches the chunk text.
    public static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(start))
    }
}

// MARK: - Results

/// What one query did.
public struct QueryOutcome: Sendable, Codable, Equatable {
    public var id: String
    public var category: RetrievalCategory
    public var text: String
    public var expectedPath: String?
    /// 1-based rank of the expected note in `SemanticResults.notes`, `nil` if
    /// it never appeared.
    public var noteRank: Int?
    /// 1-based rank of the expected note's first chunk in `results.chunks`.
    public var chunkRank: Int?
    /// 1-based rank, in `results.chunks`, of the chunk that actually contains
    /// ``RetrievalQuery/expectedSnippet``. `nil` when it never surfaced.
    public var answerChunkRank: Int?
    /// What won, when the expected note did not.
    public var topNotePath: String?
    /// The selected chunk really is in the expected note and really does
    /// contain the expected snippet — FR-5.2's answer card being right.
    public var answerHit: Bool
    /// The answer was among the eight chunks handed to the answer step. The gap
    /// between this and ``answerHit`` is what a better extractor can recover.
    public var snippetInPromptChunks: Bool
    public var selectedChunkID: Int64?
    public var topScore: Double
    public var topVectorScore: Float?
    /// For a negative query: the pipeline declined to answer.
    public var rejected: Bool
    /// `nil` when the query set states no expectation.
    public var rangeMatchedExpectation: Bool?
    public var parsedRange: DateRange?
    public var usedVectors: Bool
    /// `HybridSearch.semanticCandidates` alone — the number NFR-1 budgets.
    public var retrievalSeconds: TimeInterval
    /// The answer step. Zero-ish for the local heuristic, seconds for Claude.
    public var answerSeconds: TimeInterval

    public var noteTop1: Bool { noteRank == 1 }
    public var noteTop3: Bool { (noteRank ?? .max) <= 3 }
    public var reciprocalRank: Double { noteRank.map { 1 / Double($0) } ?? 0 }
}

/// Aggregated metrics over a set of outcomes.
public struct RetrievalMetrics: Sendable, Codable, Equatable {
    public var count: Int
    public var noteTop1: Double
    public var noteTop3: Double
    public var mrr: Double
    public var answerTop1: Double
    /// Answer present in the prompt chunks — the ceiling the answer step could
    /// reach without any change to retrieval.
    public var answerCeiling: Double
    public var p50: TimeInterval
    public var p95: TimeInterval

    public static func over(_ outcomes: [QueryOutcome]) -> RetrievalMetrics {
        let n = Double(max(outcomes.count, 1))
        let latencies = outcomes.map(\.retrievalSeconds)
        return RetrievalMetrics(
            count: outcomes.count,
            noteTop1: Double(outcomes.filter(\.noteTop1).count) / n,
            noteTop3: Double(outcomes.filter(\.noteTop3).count) / n,
            mrr: outcomes.reduce(0) { $0 + $1.reciprocalRank } / n,
            answerTop1: Double(outcomes.filter(\.answerHit).count) / n,
            answerCeiling: Double(outcomes.filter(\.snippetInPromptChunks).count) / n,
            p50: percentile(latencies, 0.5),
            p95: percentile(latencies, 0.95)
        )
    }

    static func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

/// One benchmark run, printable as a table or as JSON.
public struct RetrievalReport: Sendable, Codable, Equatable {
    public var label: String
    public var selectorLabel: String
    public var keywordOnly: Bool
    public var negativeVectorThreshold: Float
    public var noteCount: Int
    public var goldenCount: Int
    public var chunkCount: Int
    public var embeddingCount: Int
    public var indexSeconds: TimeInterval
    public var matrixLoadSeconds: TimeInterval
    public var matrixBytes: Int
    /// Expected paths the corpus does not contain — a fixture bug, always.
    public var missingExpectedPaths: [String]
    public var outcomes: [QueryOutcome]

    public var positives: [QueryOutcome] { outcomes.filter { $0.expectedPath != nil } }
    public var negatives: [QueryOutcome] { outcomes.filter { $0.expectedPath == nil } }

    /// Every query that has an answer. The spec §8 gate reads `noteTop1` here.
    public var overall: RetrievalMetrics { .over(positives) }

    /// Latency over *all* queries, negatives included — a user pays for those too.
    public var p50: TimeInterval { RetrievalMetrics.percentile(outcomes.map(\.retrievalSeconds), 0.5) }
    public var p95: TimeInterval { RetrievalMetrics.percentile(outcomes.map(\.retrievalSeconds), 0.95) }
    public var answerP95: TimeInterval { RetrievalMetrics.percentile(outcomes.map(\.answerSeconds), 0.95) }

    public var negativeRejectionRate: Double {
        guard !negatives.isEmpty else { return 1 }
        return Double(negatives.filter(\.rejected).count) / Double(negatives.count)
    }

    /// False rejections: queries that *do* have an answer but would have been
    /// suppressed by the same threshold. The cost side of the negative gate.
    public var falseRejectionRate: Double {
        guard !positives.isEmpty else { return 0 }
        return Double(positives.filter(\.rejected).count) / Double(positives.count)
    }

    public var byCategory: [(RetrievalCategory, RetrievalMetrics)] {
        RetrievalCategory.allCases.compactMap { category in
            let matching = outcomes.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, .over(matching))
        }
    }

    /// Mean top-chunk cosine for answerable and unanswerable queries. When
    /// these two overlap, no threshold can separate them and the negative gate
    /// belongs in the answer step instead.
    public var separation: (positive: Float, negative: Float) {
        func mean(_ values: [Float]) -> Float {
            values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        }
        return (mean(positives.compactMap(\.topVectorScore)), mean(negatives.compactMap(\.topVectorScore)))
    }

    public var failures: [QueryOutcome] {
        positives.filter { !$0.noteTop1 } + negatives.filter { !$0.rejected }
    }

    // MARK: - Rendering

    public func table() -> String {
        var out = ""
        out += "corpus:   \(noteCount) notes (\(goldenCount) golden), \(chunkCount) chunks, "
        out += "\(embeddingCount) embeddings in \(fixed(indexSeconds, 1)) s\n"
        out += "matrix:   \(bytesString(matrixBytes)), lazy-loaded in \(millis(matrixLoadSeconds))\n"
        out += "embedder: \(label)\(keywordOnly ? "  (vector arm disabled — BM25 baseline)" : "")\n"
        out += "answer:   \(selectorLabel)\n"
        if !missingExpectedPaths.isEmpty {
            out += "WARNING:  \(missingExpectedPaths.count) expected paths are not in the corpus: "
            out += missingExpectedPaths.prefix(3).joined(separator: ", ") + "\n"
        }
        out += "\n"
        out += "category      n    top-1   top-3    MRR@10  answer  ceiling    p50      p95\n"
        for (category, metrics) in byCategory {
            out += row(category.rawValue, metrics)
        }
        out += row("— positives", overall)
        out += "\n"
        out += "negatives:    \(negatives.count) — rejected \(percent(negativeRejectionRate)) "
        out += "(top cosine < \(fixed(Double(negativeVectorThreshold), 2)) or the answer step abstained)\n"
        out += "              false rejections among answerable queries: \(percent(falseRejectionRate))\n"
        let gap = separation
        out += "cosine:       answerable \(fixed(Double(gap.positive), 3)) vs unanswerable "
        out += "\(fixed(Double(gap.negative), 3)) (mean top chunk)\n"
        out += "latency:      p50 \(millis(p50))  p95 \(millis(p95))  (retrieval only, no answer step)\n"
        if answerP95 > 0.001 {
            out += "answer step:  p95 \(millis(answerP95))\n"
        }
        return out
    }

    /// The failures, worst first — the only part worth reading when a gate trips.
    public func failureTable(limit: Int = 20) -> String {
        let rows = failures.prefix(limit)
        guard !rows.isEmpty else { return "no failures\n" }
        var out = "failures (\(failures.count)):\n"
        for outcome in rows {
            let rank = outcome.noteRank.map(String.init) ?? "—"
            out += "  [\(outcome.category.rawValue)] \(outcome.text)\n"
            if let expected = outcome.expectedPath {
                out += "      expected \(expected) — rank \(rank)"
                out += ", answer chunk rank \(outcome.answerChunkRank.map(String.init) ?? "—")\n"
                if let winner = outcome.topNotePath, winner != expected {
                    out += "      won by  \(winner)\n"
                }
            } else {
                out += "      unanswerable, but answered with cosine "
                out += "\(fixed(Double(outcome.topVectorScore ?? 0), 3))\n"
            }
        }
        return out
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// One Markdown row for `docs/verification/M3-retrieval.md`.
    public func markdownRow(name: String) -> String {
        let metrics = overall
        return "| \(name) | \(percent(metrics.noteTop1)) | \(percent(metrics.noteTop3)) | "
            + "\(fixed(metrics.mrr, 3)) | \(percent(metrics.answerTop1)) | "
            + "\(percent(negativeRejectionRate)) | \(millis(p50)) | \(millis(p95)) |"
    }

    private func row(_ name: String, _ metrics: RetrievalMetrics) -> String {
        let label = name.padding(toLength: 13, withPad: " ", startingAt: 0)
        let count = String(metrics.count).padding(toLength: 5, withPad: " ", startingAt: 0)
        return label + count
            + percent(metrics.noteTop1).padding(toLength: 8, withPad: " ", startingAt: 0)
            + percent(metrics.noteTop3).padding(toLength: 8, withPad: " ", startingAt: 0)
            + fixed(metrics.mrr, 3).padding(toLength: 10, withPad: " ", startingAt: 0)
            + percent(metrics.answerTop1).padding(toLength: 8, withPad: " ", startingAt: 0)
            + percent(metrics.answerCeiling).padding(toLength: 9, withPad: " ", startingAt: 0)
            + millis(metrics.p50).padding(toLength: 9, withPad: " ", startingAt: 0)
            + millis(metrics.p95) + "\n"
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    private func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private func millis(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }

    private func bytesString(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
