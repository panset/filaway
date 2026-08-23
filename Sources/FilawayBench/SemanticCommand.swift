import ArgumentParser
import Darwin
import FilawayCore
import Foundation

/// `filaway-bench semantic --notes 5000` — the M3-03/M3-09 gate.
///
/// Builds a semantic index over a generated corpus, then times the **offline**
/// half of FR-5.1: embed the query, run both retrieval arms, fuse with RRF,
/// aggregate to notes. The Claude answer-extraction step (M3-05) is not part of
/// this measurement — NFR-1's 5 s budget has to hold with that on top, so this
/// number wants to be well under 500 ms.
///
/// It also reports what the resident matrix costs, which is NFR-2's other half.
struct SemanticCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "semantic",
        abstract: "Measure offline semantic query latency and vector memory (M3-03, NFR-1, NFR-2)."
    )

    @Option(name: .shortAndLong, help: "Number of synthetic notes to generate.")
    var notes = 5_000

    @Option(help: "Approximate body size per note, in bytes.")
    var bytes = 2_048

    @Option(help: "How many searches to time in total, spread over the query shapes.")
    var queries = 100

    @Option(help: "Chunks each retriever contributes before fusion.")
    var candidates = 50

    @Option(help: "Embedder to use: coreml (the bundled model) or hashed (fast, model-free).")
    var embedder = "coreml"

    @Option(help: "Core ML compute units: all | cpu | cpuAndGPU | cpuAndNeuralEngine.")
    var computeUnits = "all"

    @Option(help: "Fail the run when p95 reaches this many milliseconds.")
    var budgetMillis = 500.0

    @Option(help: "Use an existing notes folder instead of generating a corpus.")
    var root: String?

    @Flag(help: "Keep the generated corpus and print its path.")
    var keep = false

    mutating func run() async throws {
        print("# filaway-bench semantic — M3-03 hybrid retrieval")
        print("")
        let index = try await BenchIndex.make(
            notes: notes, bytes: bytes, root: root, embedderKind: embedder,
            computeUnits: computeUnits, excluded: []
        )
        defer { if !keep { index.bench.removeIfGenerated() } }
        print("embedder: \(index.embedderDescription)")
        print("")

        let buildStart = Date()
        let report = try await index.indexer.rebuildAll()
        print("index:    \(report.chunksInserted) chunks over \(report.notesIndexed) notes in "
            + "\(format(Date().timeIntervalSince(buildStart)))")

        // The matrix is loaded lazily, exactly as the app does it on the first
        // semantic query — so this timing is the one a user actually waits for.
        let residentBefore = EmbedCommand.residentBytes()
        let loadStart = Date()
        try await index.vectors.ensureLoaded()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let memory = await index.vectors.memory()
        let residentAfter = EmbedCommand.residentBytes()
        print("matrix:   \(memory.description), lazy-loaded in \(formatMillis(loadSeconds)) "
            + "(process +\(String(format: "%.1f", EmbedCommand.megabytes(residentAfter &- residentBefore))) MB)")
        print("")

        let hybrid = HybridSearch(
            metadata: index.metadata, embedder: index.embedder, vectorStore: index.vectors
        )
        let options = HybridSearch.Options(candidateLimit: candidates)
        let shapes = SemanticQueryShape.all
        _ = await hybrid.semanticCandidates("warm up the caches", options: options)

        var timings: [String: [TimeInterval]] = [:]
        var all: [TimeInterval] = []
        var empty: [String] = []
        for iteration in 0 ..< max(shapes.count, queries) {
            let shape = shapes[iteration % shapes.count]
            let start = Date()
            let results = await hybrid.semanticCandidates(shape.query, options: options)
            let seconds = Date().timeIntervalSince(start)
            timings[shape.name, default: []].append(seconds)
            all.append(seconds)
            if results.isEmpty, !empty.contains(shape.name) { empty.append(shape.name) }
        }

        print("query shape          n     p50       p95       max      example")
        for shape in shapes {
            guard let values = timings[shape.name] else { continue }
            let name = shape.name.padding(toLength: 20, withPad: " ", startingAt: 0)
            let count = String(values.count).padding(toLength: 6, withPad: " ", startingAt: 0)
            let p50 = formatMillis(percentile(values, 0.5)).padding(toLength: 10, withPad: " ", startingAt: 0)
            let p95 = formatMillis(percentile(values, 0.95)).padding(toLength: 10, withPad: " ", startingAt: 0)
            let worst = formatMillis(values.max() ?? 0).padding(toLength: 9, withPad: " ", startingAt: 0)
            print("\(name) \(count)\(p50)\(p95)\(worst)\(shape.query.prefix(28))")
        }

        let p95 = percentile(all, 0.95)
        print("")
        print("overall:  \(all.count) searches — p50 \(formatMillis(percentile(all, 0.5))), "
            + "p95 \(formatMillis(p95)), max \(formatMillis(all.max() ?? 0))")
        print("          (embed + vector top-\(candidates) + BM25 top-\(candidates) + RRF; no Claude)")
        if !empty.isEmpty {
            print("warning:  no results for \(empty.joined(separator: ", "))")
        }
        if keep, index.bench.generated { print("corpus kept at \(index.bench.library.root.path)") }

        guard p95 * 1000 < budgetMillis else {
            print("FAIL      p95 \(formatMillis(p95)) reaches the \(Int(budgetMillis)) ms budget")
            throw ExitCode.failure
        }
        print("PASS      p95 \(formatMillis(p95)) < \(Int(budgetMillis)) ms "
            + "(NFR-1 allows 5 s including the Claude step)")
    }
}

/// The query shapes FR-5.1/5.2/5.3 promise, anchored on vocabulary
/// ``SyntheticCorpus`` actually writes.
struct SemanticQueryShape {
    let name: String
    let query: String

    static let all: [SemanticQueryShape] = [
        .init(name: "command lookup", query: "the curl command to fetch documents as json"),
        .init(name: "paraphrase", query: "how do I bring the container stack back up"),
        // `SyntheticCorpus` writes every file at generation time, so "today"
        // is the only hard date range that can match anything. It exercises
        // the same path as "two days ago" — parse, then filter inside the
        // vector top-k — while still returning results to time.
        .init(name: "temporal", query: "the thing I edited today about tokens"),
        .init(name: "recency", query: "the ranking notes I touched recently"),
        .init(name: "code fragment", query: "rsync deploy to the server over ssh"),
        .init(name: "concept", query: "why does the token budget run out mid session"),
    ]
}
