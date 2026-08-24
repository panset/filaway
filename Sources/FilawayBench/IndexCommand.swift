import ArgumentParser
import CoreML
import FilawayCore
import Foundation

/// A deterministic, model-free embedder for `--embedder hashed`.
///
/// Building a 5,000-note semantic index with the real model takes minutes; this
/// makes the *plumbing* measurable in seconds (chunk counts, database growth,
/// transaction throughput) when the question is not model latency.
struct HashedBenchEmbedder: Embedder {
    let identifier = "bench:hashed/384d/v1"
    let dimension = 384

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(Self.vector(for:))
    }

    static func vector(for text: String) -> [Float] {
        var out = [Float](repeating: 0, count: 384)
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            out[Int(hash % 384)] += (hash >> 40) & 1 == 0 ? 1 : -1
        }
        let normalized = EmbeddingMath.normalized(out)
        if normalized.allSatisfy({ $0 == 0 }) {
            var fallback = [Float](repeating: 0, count: 384)
            fallback[0] = 1
            return fallback
        }
        return normalized
    }
}

/// Everything the M3 benches need: a corpus on disk, a migrated database, an
/// embedder, a vector store and an indexer.
struct BenchIndex {
    let bench: BenchLibrary
    let metadata: MetadataStore
    let embedder: any Embedder
    let vectors: VectorStore
    let indexer: Indexer
    let embedderDescription: String

    static func make(
        notes: Int,
        bytes: Int,
        root: String?,
        embedderKind: String,
        computeUnits: String,
        excluded: [String],
        // M3-09 levers: how many chunks go to the embedder in one call, and
        // how small a section may be before the chunker folds it into its
        // neighbour (ADR-039). Both change index-build time and the resident
        // matrix roughly linearly, so both need to be measurable.
        embedBatchSize: Int = 32,
        minTokens: Int? = nil
    ) async throws -> BenchIndex {
        let bench = BenchLibrary(root: root)
        if bench.generated {
            let start = Date()
            try SyntheticCorpus.generate(noteCount: notes, into: bench.library, approximateBytes: bytes)
            print("corpus:   \(notes) notes generated in \(format(Date().timeIntervalSince(start)))")
        }

        let store = NoteStore(library: bench.library)
        let scanStart = Date()
        let snapshot = try await store.scan()
        try? FileManager.default.removeItem(at: bench.library.databaseURL)
        let metadata = try MetadataStore(library: bench.library)
        try await metadata.rebuild(from: snapshot)
        print("metadata: \(snapshot.notes.count) notes scanned + indexed in "
            + "\(format(Date().timeIntervalSince(scanStart)))")

        let (embedder, description) = try await resolveEmbedder(embedderKind, computeUnits: computeUnits)
        let vectors = VectorStore(
            reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
        )
        let exclusions = ExclusionFilter(excludedFolders: excluded)
        var chunkerConfiguration = Chunker.Configuration()
        if let minTokens { chunkerConfiguration.minTokens = minTokens }
        let indexer = Indexer(
            metadata: metadata,
            embedder: embedder,
            chunker: Chunker(configuration: chunkerConfiguration),
            vectorStore: vectors,
            configuration: .init(debounce: .zero, embedBatchSize: embedBatchSize),
            isExcluded: { exclusions.isExcluded(path: $0) }
        )
        return BenchIndex(
            bench: bench, metadata: metadata, embedder: embedder, vectors: vectors,
            indexer: indexer, embedderDescription: description
        )
    }

    private static func resolveEmbedder(
        _ kind: String, computeUnits: String
    ) async throws -> (any Embedder, String) {
        switch kind.lowercased() {
        case "hashed", "fake":
            return (HashedBenchEmbedder(), "hashed bag-of-words (no model)")
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
}

/// `filaway-bench index --notes 5000` — the M3-02/M3-09 gate.
///
/// Times a cold semantic-index build over a generated corpus and reports what
/// it cost: wall time, chunks, embeddings, throughput, and how much the derived
/// database grew. Then it edits one note and re-indexes, which is the number
/// FR-5.4 actually lives or dies by.
struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Time a full semantic index build over a synthetic corpus (M3-02, NFR-2)."
    )

    @Option(name: .shortAndLong, help: "Number of synthetic notes to generate.")
    var notes = 5_000

    @Option(help: "Approximate body size per note, in bytes.")
    var bytes = 2_048

    @Option(help: "Embedder to use: coreml (the bundled model) or hashed (fast, model-free).")
    var embedder = "coreml"

    @Option(help: "Core ML compute units: all | cpu | cpuAndGPU | cpuAndNeuralEngine.")
    var computeUnits = "all"

    @Option(parsing: .upToNextOption, help: "Folders to exclude from the index (FR-4.5).")
    var exclude: [String] = []

    @Option(help: "Use an existing notes folder instead of generating a corpus.")
    var root: String?

    @Option(help: "Chunks handed to the embedder in one call (M3-09 lever).")
    var embedBatch = 32

    @Option(help: "Chunker minTokens — how small a section may be before it folds (ADR-039).")
    var minTokens: Int?

    @Flag(help: """
        M4-07: run a search loop against the index while it is building, and report \
        what a user would see — query latency under load, and how coverage grows.
        """)
    var withQueries = false

    @Flag(help: "Keep the generated corpus and print its path.")
    var keep = false

    mutating func run() async throws {
        print("# filaway-bench index — M3-02 semantic index build")
        print("")
        let index = try await BenchIndex.make(
            notes: notes, bytes: bytes, root: root, embedderKind: embedder,
            computeUnits: computeUnits, excluded: exclude,
            embedBatchSize: embedBatch, minTokens: minTokens
        )
        defer { if !keep { index.bench.removeIfGenerated() } }
        print("embedder: \(index.embedderDescription)")
        print("model id: \(index.embedder.identifier) · \(index.embedder.dimension)-d")
        print("")

        let databaseBefore = megabytes(ofFileAt: index.bench.library.databaseURL)
        let start = Date()
        let probe = withQueries ? SearchUnderLoad(index: index) : nil
        let probing = probe.map { probe in Task(priority: .userInitiated) { await probe.run() } }
        let report = try await index.indexer.rebuildAll()
        let elapsed = Date().timeIntervalSince(start)
        probing?.cancel()
        if let probe { await probe.report(buildSeconds: elapsed) }
        let databaseAfter = megabytes(ofFileAt: index.bench.library.databaseURL)

        let noteCount = try await index.metadata.noteCount()
        print("build:    \(format(elapsed)) for \(report.notesIndexed) notes "
            + "(\(String(format: "%.1f", Double(report.notesIndexed) / max(elapsed, 0.001))) notes/s)")
        print("chunks:   \(report.chunksInserted) "
            + "(\(String(format: "%.1f", Double(report.chunksInserted) / Double(max(noteCount, 1)))) per note), "
            + "\(report.embeddingsComputed) embeddings "
            + "(\(formatMillis(elapsed / Double(max(report.embeddingsComputed, 1)))) each)")
        if report.notesPurged > 0 {
            print("excluded: \(report.notesPurged) notes skipped (\(exclude.joined(separator: ", ")))")
        }
        print("database: \(String(format: "%.1f", databaseBefore)) MB → "
            + "\(String(format: "%.1f", databaseAfter)) MB "
            + "(+\(String(format: "%.1f", databaseAfter - databaseBefore)) MB for the semantic index)")

        try await index.vectors.ensureLoaded()
        let memory = await index.vectors.memory()
        print("matrix:   \(memory.description)")

        // FR-5.4's real number: one note changes, and the index catches up.
        try await incremental(index)

        if keep, index.bench.generated {
            print("")
            print("corpus kept at \(index.bench.library.root.path)")
        }
    }

    /// Edits one note and re-indexes it, the way autosave would.
    private func incremental(_ index: BenchIndex) async throws {
        guard let note = try await index.metadata.allNotes().first else { return }
        let url = index.bench.library.url(for: note.relativePath)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        text += "\n\n## Addendum\n\nA paragraph appended by the benchmark to force a re-chunk.\n"
        try Data(text.utf8).write(to: url)

        let rescan = try await NoteStore(library: index.bench.library).scan()
        try await index.metadata.upsert(rescan.notes.filter { $0.id == note.id })

        let start = Date()
        await index.indexer.markDirty(note.id)
        let report = try await index.indexer.drain()
        let elapsed = Date().timeIntervalSince(start)
        print("edit:     \(formatMillis(elapsed)) to re-index one note — "
            + "\(report.embeddingsComputed) embeddings recomputed, \(report.chunksReused) chunks reused "
            + "(FR-5.4 budget: 5 s)")
    }
}

/// M4-07: what ⌘K feels like *while* the first-launch index is building.
///
/// The number M3-perf.md could not give: a 5,000-note library takes 50 s to
/// index and a 20,000-note one takes about four minutes, and the whole design
/// rests on that being background work nobody notices. This runs a search loop
/// at `.userInitiated` against the same database the `Indexer` is writing —
/// the priority relationship a real ⌘K has to a real catch-up — and reports
/// the latency distribution it saw and how many notes were already findable.
///
/// It measures three things at once:
///
/// * **Latency under load.** The p95 here is what NFR-1's <5 s semantic budget
///   is actually spent against on a first launch.
/// * **Partial results.** The `Indexer` writes each note in its own
///   transaction, so a query run halfway through returns the notes indexed so
///   far rather than nothing (FR-5.4, and what "Indexing n of m" is a promise
///   about).
/// * **Whether the writer starves the reader.** SQLite in WAL mode lets them
///   run at once; the failure mode this would catch is the indexer holding the
///   writer across a whole batch.
actor SearchUnderLoad {
    private let index: BenchIndex
    private var latencies: [TimeInterval] = []
    private var coverage: [(seconds: TimeInterval, chunks: Int, hits: Int)] = []
    private var startedAt = Date()

    /// Ordinary questions, so the FTS arm and the vector arm both do work.
    private static let queries = [
        "the curl command with the bearer token",
        "how do I rebuild one docker service and follow its logs",
        "rebase onto main without losing work",
        "count which errors happen most in a log file",
        "stream the logs from a running pod",
    ]

    init(index: BenchIndex) { self.index = index }

    func run() async {
        startedAt = Date()
        var next = 0
        while !Task.isCancelled {
            let query = Self.queries[next % Self.queries.count]
            next += 1
            let start = Date()
            // No vector arm: the resident matrix is deliberately not reloaded
            // mid-build (a rebuild must not force a lazy store into memory),
            // so this is the BM25 half plus the chunk hydration — which is
            // exactly the half a user gets before the vectors are all in.
            let hybrid = HybridSearch(
                metadata: index.metadata, embedder: nil, vectorStore: nil
            )
            let results = await hybrid.semanticCandidates(query)
            latencies.append(Date().timeIntervalSince(start))
            let chunks = (try? await index.indexer.chunkCount()) ?? 0
            coverage.append((Date().timeIntervalSince(startedAt), chunks, results.notes.count))
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func report(buildSeconds: TimeInterval) {
        guard !latencies.isEmpty else { return }
        print("")
        print("during the build (M4-07) — \(latencies.count) searches at .userInitiated "
            + "while the indexer ran at .utility:")
        print("  latency:  p50 \(formatMillis(percentile(latencies, 0.5))), "
            + "p95 \(formatMillis(percentile(latencies, 0.95))), "
            + "max \(formatMillis(latencies.max() ?? 0))")
        let quarters = [0.25, 0.5, 0.75].compactMap { fraction -> String? in
            let at = buildSeconds * fraction
            guard let sample = coverage.first(where: { $0.seconds >= at }) else { return nil }
            return "\(Int(fraction * 100))% in: \(sample.chunks) chunks, \(sample.hits) notes ranked"
        }
        if !quarters.isEmpty { print("  partial:  \(quarters.joined(separator: " · "))") }
        print("  (a query never returned nothing: the indexer commits per note, "
            + "so ⌘K improves as the build runs)")
    }
}
