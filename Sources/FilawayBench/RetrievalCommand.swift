import ArgumentParser
import FilawayCore
import Foundation

/// `filaway-bench corpus generate` — writes `Tests/Fixtures/corpus/dev`.
struct CorpusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus",
        abstract: "Generate the committed development corpus (M3-07).",
        subcommands: [Generate.self, Stats.self],
        defaultSubcommand: Stats.self
    )

    /// `filaway-bench corpus generate --seed 20260823`
    struct Generate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate",
            abstract: "Regenerate Tests/Fixtures/corpus/dev from the curated tables."
        )

        @Option(help: "PRNG seed for the distractor half. Fixed in the committed corpus.")
        var seed: UInt64 = DevCorpusGenerator.defaultSeed

        @Option(help: "How many distractor notes to write alongside the golden ones.")
        var distractors = 240

        @Option(help: "Output directory (default: Tests/Fixtures/corpus/dev).")
        var out: String?

        mutating func run() async throws {
            let directory = out.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? DevCorpus.defaultDirectory
            let notes = DevCorpusGenerator.generate(seed: seed, distractors: distractors)
            let bytes = try DevCorpus.write(notes, to: directory)
            let golden = notes.filter(\.isGolden).count
            print("wrote \(notes.count) notes (\(golden) golden, \(notes.count - golden) distractors), "
                + "\(String(format: "%.0f", Double(bytes) / 1024)) KB")
            print("  → \(directory.path)")
            print("  now = \(ISO8601.string(from: DevCorpusGenerator.referenceNow)) (seed \(seed))")
        }
    }

    /// `filaway-bench corpus stats` — what is committed right now.
    struct Stats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stats", abstract: "Describe the committed corpus and query set."
        )

        mutating func run() async throws {
            let notes = try DevCorpus.load()
            let bytes = notes.reduce(0) { $0 + $1.fileText.utf8.count }
            let folders = Set(notes.compactMap { note -> String? in
                let parts = note.relativePath.split(separator: "/").dropLast()
                return parts.isEmpty ? nil : parts.joined(separator: "/")
            })
            print("corpus:   \(notes.count) notes, \(notes.filter(\.isGolden).count) golden, "
                + "\(String(format: "%.0f", Double(bytes) / 1024)) KB, \(folders.count) folders")
            let dates = notes.map(\.modified).sorted()
            if let first = dates.first, let last = dates.last {
                print("dates:    \(ISO8601.string(from: first)) … \(ISO8601.string(from: last))")
            }
            guard let queries = try? RetrievalQuerySet.load() else {
                print("queries:  none at \(DevCorpus.defaultQuerySetURL.path)")
                return
            }
            print("queries:  \(queries.queries.count) "
                + "(\(queries.negatives.count) negative), now = \(ISO8601.string(from: queries.now)) "
                + "[\(queries.timeZone)]")
            for category in RetrievalCategory.allCases {
                let n = queries.queries.filter { $0.category == category }.count
                if n > 0 { print("          \(category.rawValue): \(n)") }
            }
        }
    }
}

/// `filaway-bench retrieval --embedder bge` — the M3-07 gate.
///
/// Materialises the committed corpus into a throwaway library, indexes it with
/// the chosen embedder, and scores the committed query set: note top-1/top-3,
/// MRR@10, answer-chunk top-1, negative rejection, and latency. Exits non-zero
/// below the gate, so it works in CI exactly like `filaway-bench keyword`.
struct RetrievalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retrieval",
        abstract: "Score natural-language retrieval on the dev corpus (M3-07, spec §8)."
    )

    @Option(help: "bge (the bundled Core ML model) | hashed (deterministic, model-free) | bm25 (no vector arm).")
    var embedder = "bge"

    @Option(help: "Core ML compute units: all | cpu | cpuAndGPU | cpuAndNeuralEngine.")
    var computeUnits = "all"

    @Option(help: "Answer step: local (the offline heuristic) | replay (recorded Claude) | ollama (a live local model) | none.")
    var answer = "local"

    @Option(help: "Model for --answer ollama (default: the house local tag).")
    var answerModel: String?

    @Option(help: "Ollama base URL for --answer ollama.")
    var ollamaURL = OllamaConfiguration.defaultBaseURL.absoluteString

    @Option(help: "Seconds one live answer call may take. Not NFR-1's 5 s race — the report counts that separately.")
    var answerTimeout: TimeInterval = 60

    @Option(help: "Chunks each retriever contributes before fusion.")
    var candidates = 50

    @Option(help: "RRF smoothing constant (ADR-047 lowered the default to 20).")
    var rrfK = 20.0

    @Option(help: "Top-chunk cosine below which an unanswerable query counts as rejected.")
    var negativeThreshold: Float = 0.70

    @Option(help: "Recency prior: default | none | recent.")
    var recency = "default"

    @Option(help: "Override the recency prior's ceiling (0.2 is ADR-040's default).")
    var recencyBoost: Double?

    @Option(help: "Prompt chunks handed to the answer step (the app uses SemanticResults.promptChunkLimit).")
    var promptChunks = SemanticResults.promptChunkLimit

    @Flag(
        inversion: .prefixedNo,
        help: "M4-07 typo repair: expand query words the library has never indexed."
    )
    var typoExpansion = true

    @Option(help: "Fail below this note top-1 rate (spec §8 is 0.90).")
    var gateNoteTop1 = 0.90

    @Option(help: "Fail below this answer-chunk top-1 rate.")
    var gateAnswerTop1 = 0.85

    @Option(help: "Fail when retrieval p95 reaches this many milliseconds.")
    var gateP95Millis = 1_000.0

    @Option(help: "Corpus directory (default: Tests/Fixtures/corpus/dev).")
    var corpus: String?

    @Option(help: "Query set (default: Tests/Fixtures/queries/dev.json).")
    var queries: String?

    @Flag(help: "Print the report as JSON instead of a table.")
    var json = false

    @Flag(help: "Print every failing query.")
    var failures = false

    @Flag(help: "Score without applying the gate (exit 0 whatever the numbers).")
    var noGate = false

    mutating func run() async throws {
        let corpusNotes = try DevCorpus.load(
            from: corpus.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DevCorpus.defaultDirectory
        )
        let querySet = try RetrievalQuerySet.load(
            from: queries.map { URL(fileURLWithPath: $0) } ?? DevCorpus.defaultQuerySetURL
        )

        let bench = BenchLibrary(root: nil)
        defer { bench.removeIfGenerated() }

        let (embedderInstance, description) = try await Self.resolve(
            embedder, computeUnits: computeUnits
        )
        let selector = try Self.selector(
            answer,
            keywordOnly: embedder.lowercased() == "bm25",
            threshold: negativeThreshold,
            answerTimeout: answerTimeout,
            ollama: OllamaConfiguration(
                baseURL: URL(string: ollamaURL) ?? OllamaConfiguration.defaultBaseURL,
                model: answerModel.map { AIModel($0) } ?? .defaultOllama
            )
        )
        let configuration = RetrievalBenchmark.Configuration(
            candidateLimit: candidates,
            rrfK: rrfK,
            negativeVectorThreshold: negativeThreshold,
            keywordOnly: embedder.lowercased() == "bm25",
            recencyPrior: Self.prior(recency, boost: recencyBoost),
            promptChunkCount: promptChunks,
            typoExpansion: typoExpansion
        )

        if !json {
            print("# filaway-bench retrieval — M3-07")
            print("")
        }
        let echo: @Sendable (String) -> Void = { line in print(line) }
        let progress: (@Sendable (String) -> Void)? = json ? nil : echo
        let report = try await RetrievalBenchmark.run(
            corpus: corpusNotes, queries: querySet, library: bench.library,
            embedder: embedderInstance, selector: selector,
            configuration: configuration, label: description,
            progress: progress
        )

        if json {
            FileHandle.standardOutput.write(try report.json())
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("")
            print(report.table())
            if let live = selector as? LiveAnswerSelector { print(live.stats.line) }
            if failures { print(report.failureTable()) }
            print("markdown row for docs/verification/M3-retrieval.md:")
            print(report.markdownRow(name: description))
        }

        guard !noGate else { return }
        var problems: [String] = []
        if report.overall.noteTop1 < gateNoteTop1 {
            problems.append(String(
                format: "note top-1 %.0f%% < %.0f%%", report.overall.noteTop1 * 100, gateNoteTop1 * 100
            ))
        }
        if report.overall.answerTop1 < gateAnswerTop1 {
            problems.append(String(
                format: "answer top-1 %.0f%% < %.0f%%", report.overall.answerTop1 * 100, gateAnswerTop1 * 100
            ))
        }
        if report.p95 * 1000 >= gateP95Millis {
            problems.append(String(format: "p95 %.0f ms ≥ %.0f ms", report.p95 * 1000, gateP95Millis))
        }
        guard problems.isEmpty else {
            if !json { print("\nFAIL      " + problems.joined(separator: "; ")) }
            throw ExitCode.failure
        }
        if !json { print("\nPASS      spec §8 gate met") }
    }

    static func prior(_ name: String, boost: Double?) -> RecencyPrior {
        var prior: RecencyPrior = switch name.lowercased() {
        case "none", "off": .none
        case "recent": .recent
        default: .default
        }
        if let boost { prior.maxBoost = boost }
        return prior
    }

    static func resolve(
        _ kind: String, computeUnits: String
    ) async throws -> (any Embedder, String) {
        switch kind.lowercased() {
        case "hashed", "fake":
            return (HashedBenchEmbedder(), "hashed bag-of-words (no model)")
        case "bm25", "keyword", "none":
            // The vector arm is switched off in the configuration; the embedder
            // is still needed to build an index the keyword arm can read chunks
            // from, and the cheapest one will do.
            return (HashedBenchEmbedder(), "BM25 only (FTS5, no vectors)")
        default:
            let units = EmbedCommand.parseComputeUnits(computeUnits)
            let (embedder, active) = await EmbedderFactory.default(computeUnits: units)
            guard let embedder else {
                throw ValidationError(
                    "no embedder available — build with the bundled model, or pass --embedder hashed"
                )
            }
            return (embedder, "\(active.displayName) · \(active.detail)")
        }
    }

    static func selector(
        _ kind: String,
        keywordOnly: Bool,
        threshold: Float,
        answerTimeout: TimeInterval,
        ollama: OllamaConfiguration
    ) throws -> any AnswerSelecting {
        switch kind.lowercased() {
        case "replay":
            return ReplaySelector()
        case "ollama", "local-model":
            // P2-04: the real `answer.v1` call against the daemon, one query at
            // a time. No key, no bill, ~4 s a query on an 8B model.
            guard ollama.validate() else {
                throw ValidationError("--ollama-url must be https, or http to loopback (NFR-4)")
            }
            return LiveAnswerSelector(
                provider: OllamaProvider(configuration: ollama, retryPolicy: .none),
                kind: .ollama,
                model: ollama.model,
                timeout: answerTimeout
            )
        case "none":
            return LocalHeuristicSelector(codeMargin: 0, minimumVectorScore: nil)
        default:
            // Deliberately non-abstaining: the runner applies `threshold`
            // itself, so the negative-rejection number measures one rule
            // rather than two interacting ones.
            _ = (keywordOnly, threshold)
            return LocalHeuristicSelector()
        }
    }
}
