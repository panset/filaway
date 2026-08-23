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
        excluded: [String]
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
        let indexer = Indexer(
            metadata: metadata,
            embedder: embedder,
            vectorStore: vectors,
            configuration: .init(debounce: .zero),
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

    @Flag(help: "Keep the generated corpus and print its path.")
    var keep = false

    mutating func run() async throws {
        print("# filaway-bench index — M3-02 semantic index build")
        print("")
        let index = try await BenchIndex.make(
            notes: notes, bytes: bytes, root: root, embedderKind: embedder,
            computeUnits: computeUnits, excluded: exclude
        )
        defer { if !keep { index.bench.removeIfGenerated() } }
        print("embedder: \(index.embedderDescription)")
        print("model id: \(index.embedder.identifier) · \(index.embedder.dimension)-d")
        print("")

        let databaseBefore = megabytes(ofFileAt: index.bench.library.databaseURL)
        let start = Date()
        let report = try await index.indexer.rebuildAll()
        let elapsed = Date().timeIntervalSince(start)
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
