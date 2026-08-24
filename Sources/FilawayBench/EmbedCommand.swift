import ArgumentParser
import CoreML
import Darwin
import FilawayCore
import Foundation

/// `filaway-bench embed` — the measurement harness for the M1-08 embedder spike
/// (plan §5 risk #4): compile/load timing, per-embedding latency at two input
/// lengths, resident-memory cost, and a directional retrieval hit rate against
/// a BM25 baseline.
///
/// The Core ML packages are **not** committed (they are 43–66 MB); regenerate
/// them with `Tools/embedder/convert.py` — see `Tools/embedder/README.md`. Any
/// package that is missing is skipped with a note.
struct EmbedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Embedder spike: load/latency/memory/retrieval numbers (M1-08)."
    )

    @Option(name: .long, help: "Directory holding the converted .mlpackage files.")
    var out = "Tools/embedder/out"

    @Option(name: .long, parsing: .upToNextOption,
            help: "Package basenames to measure (default: every *.mlpackage in --out).")
    var packages: [String] = []

    @Option(name: .long, help: "Core ML compute units: all | cpu | cpuAndGPU | cpuAndNeuralEngine.")
    var computeUnits = "all"

    @Option(name: .long, help: "Timed iterations per latency measurement.")
    var iterations = 20

    @Flag(name: .long, help: "Delete the compiled-model cache first, to time a cold first launch.")
    var recompile = false

    @Flag(name: .long, help: "Skip the Core ML models.")
    var skipCoreml = false

    @Flag(name: .long, help: "Skip the NaturalLanguage embedders.")
    var skipNl = false

    @Flag(name: .long, help: "Download NLContextualEmbedding assets if they are missing.")
    var downloadAssets = false

    func run() async throws {
        print("# filaway-bench embed — M1-08 embedder spike")
        print("host: \(Self.hostDescription())")
        print("compute units: \(computeUnits)")
        print("corpus: \(RetrievalSpikeCorpus.notes.count) notes, \(RetrievalSpikeCorpus.queries.count) queries")
        print("")

        var rows: [Row] = []

        if !skipCoreml {
            for url in try resolvePackages() {
                do {
                    rows.append(try await measureCoreML(package: url))
                } catch {
                    print("SKIP \(url.lastPathComponent): \(error)")
                }
            }
        }

        if !skipNl {
            rows.append(contentsOf: try await measureNaturalLanguage())
        }

        let baseline = measureBaseline()
        print("")
        print("## Results")
        print("")
        Row.printTable(rows + [baseline])
    }

    // MARK: - Core ML

    private func resolvePackages() throws -> [URL] {
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        if !packages.isEmpty {
            return packages.map { name in
                let file = name.hasSuffix(".mlpackage") ? name : "\(name).mlpackage"
                return file.contains("/")
                    ? URL(fileURLWithPath: file)
                    : directory.appendingPathComponent(file)
            }
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            print("SKIP Core ML: \(directory.path) does not exist — see Tools/embedder/README.md")
            return []
        }
        return contents.filter { $0.pathExtension == "mlpackage" }.sorted { $0.path < $1.path }
    }

    private func measureCoreML(package url: URL) async throws -> Row {
        let stem = url.deletingPathExtension().lastPathComponent
        let descriptor = try EmbeddingModelDescriptor(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        )
        if recompile { try? CompiledModelStore.removeCachedModel(forPackageAt: url) }

        let before = Self.residentBytes()
        let start = ContinuousClock.now
        let (embedder, compilation) = try await CoreMLEmbedder.load(
            packageAt: url, computeUnits: Self.parseComputeUnits(computeUnits)
        )
        let loadMS = Self.milliseconds(since: start)
        _ = try await embedder.embed(["warm up the graph"])
        let afterLoad = Self.residentBytes()

        print("## \(stem)")
        print("- package on disk: \(Self.megabytes(Self.directorySize(url))) MB")
        print("- compile: \(compilation.didCompile ? "cold, \(Self.format(compilation.compileDuration * 1000)) ms" : "cached (0 ms)")")
        print("- load+first-embed: \(Self.format(loadMS)) ms · resident +\(Self.megabytes(afterLoad - before)) MB")

        let short = Self.shortText
        let long = Self.longText
        let shortTokens = await embedder.tokenCount(short)
        let longTokens = await embedder.tokenCount(long)

        let singleShort = try await Self.time(iterations) { _ = try await embedder.embed([short]) }
        let singleLong = try await Self.time(iterations) { _ = try await embedder.embed([long]) }
        let batchShort = try await Self.timeBatch(32, iterations: max(iterations / 4, 3)) { texts in
            _ = try await embedder.embed(texts)
        }
        print("- tokens: short=\(shortTokens), long=\(longTokens) (fixed seq \(descriptor.maxSequenceLength))")
        print("- single short: \(Self.format(singleShort.mean)) ms mean, \(Self.format(singleShort.p95)) ms p95")
        print("- single long:  \(Self.format(singleLong.mean)) ms mean, \(Self.format(singleLong.p95)) ms p95")
        print("- batch of 32:  \(Self.format(batchShort.mean)) ms total → \(Self.format(batchShort.mean / 32)) ms/embedding")

        let retrieval = try await Self.evaluateRetrieval(embedder)
        print("- retrieval: top-1 \(Self.percent(retrieval.top1)), top-3 \(Self.percent(retrieval.top3)), MRR \(Self.format(retrieval.mrr, digits: 3))")
        let peak = Self.residentBytes()
        print("- resident after full corpus: \(Self.megabytes(peak)) MB total (+\(Self.megabytes(peak - before)) MB)")
        print("")

        return Row(
            name: stem,
            dimension: descriptor.dimension,
            diskMB: Self.megabytes(Self.directorySize(url)),
            loadMS: loadMS,
            singleShortMS: singleShort.mean,
            singleLongMS: singleLong.mean,
            batchedMS: batchShort.mean / 32,
            memoryMB: Self.megabytes(peak - before),
            top1: retrieval.top1,
            top3: retrieval.top3,
            mrr: retrieval.mrr
        )
    }

    // MARK: - NaturalLanguage

    private func measureNaturalLanguage() async throws -> [Row] {
        var rows: [Row] = []

        if downloadAssets, !NLContextualEmbedder.assetsAvailable() {
            print("requesting NLContextualEmbedding assets…")
            let start = ContinuousClock.now
            let ok = try await NLContextualEmbedder.prepareAssets()
            print("assets \(ok ? "available" : "unavailable") after \(Self.format(Self.milliseconds(since: start) / 1000)) s")
        }

        if NLContextualEmbedder.assetsAvailable() {
            rows.append(try await measure(name: "NLContextualEmbedding (mean-pooled)") {
                try NLContextualEmbedder()
            })
        } else {
            print("SKIP NLContextualEmbedding: assets not installed (run with --download-assets)")
            print("")
        }

        if NLSentenceEmbedder.isAvailable() {
            rows.append(try await measure(name: "NLEmbedding.sentenceEmbedding") {
                try NLSentenceEmbedder()
            })
        } else {
            print("SKIP NLEmbedding.sentenceEmbedding: unavailable for English")
            print("")
        }
        return rows
    }

    private func measure(name: String, make: () throws -> some Embedder) async throws -> Row {
        let before = Self.residentBytes()
        let start = ContinuousClock.now
        let embedder = try make()
        _ = try await embedder.embed(["warm up"])
        let loadMS = Self.milliseconds(since: start)

        print("## \(name)")
        print("- identifier: \(embedder.identifier) · \(embedder.dimension)-d")
        print("- load+first-embed: \(Self.format(loadMS)) ms")

        let singleShort = try await Self.time(iterations) { _ = try await embedder.embed([Self.shortText]) }
        let singleLong = try await Self.time(iterations) { _ = try await embedder.embed([Self.longText]) }
        let batch = try await Self.timeBatch(32, iterations: max(iterations / 4, 3)) { texts in
            _ = try await embedder.embed(texts)
        }
        print("- single short: \(Self.format(singleShort.mean)) ms mean, \(Self.format(singleShort.p95)) ms p95")
        print("- single long:  \(Self.format(singleLong.mean)) ms mean, \(Self.format(singleLong.p95)) ms p95")
        print("- batch of 32:  \(Self.format(batch.mean)) ms total → \(Self.format(batch.mean / 32)) ms/embedding")

        let retrieval = try await Self.evaluateRetrieval(embedder)
        print("- retrieval: top-1 \(Self.percent(retrieval.top1)), top-3 \(Self.percent(retrieval.top3)), MRR \(Self.format(retrieval.mrr, digits: 3))")
        let peak = Self.residentBytes()
        print("- resident: +\(Self.megabytes(peak - before)) MB")
        print("")

        return Row(
            name: name, dimension: embedder.dimension, diskMB: 0, loadMS: loadMS,
            singleShortMS: singleShort.mean, singleLongMS: singleLong.mean,
            batchedMS: batch.mean / 32, memoryMB: Self.megabytes(peak - before),
            top1: retrieval.top1, top3: retrieval.top3, mrr: retrieval.mrr
        )
    }

    // MARK: - Baseline

    private func measureBaseline() -> Row {
        let notes = RetrievalSpikeCorpus.notes
        let ranker = TermOverlapRanker(documents: notes.map(\.text))
        var top1 = 0, top3 = 0
        var reciprocalRank = 0.0
        let start = ContinuousClock.now
        for query in RetrievalSpikeCorpus.queries {
            let ranking = ranker.ranking(for: query.text).map { notes[$0].id }
            if ranking.first == query.expected { top1 += 1 }
            if ranking.prefix(3).contains(query.expected) { top3 += 1 }
            if let rank = ranking.firstIndex(of: query.expected) {
                reciprocalRank += 1.0 / Double(rank + 1)
            }
        }
        let elapsed = Self.milliseconds(since: start)
        let count = Double(RetrievalSpikeCorpus.queries.count)
        print("## BM25 baseline (TermOverlapRanker)")
        print("- \(Self.format(elapsed / count, digits: 3)) ms per query over \(notes.count) notes")
        print("- retrieval: top-1 \(Self.percent(Double(top1) / count)), top-3 \(Self.percent(Double(top3) / count)), MRR \(Self.format(reciprocalRank / count, digits: 3))")
        print("")
        return Row(
            name: "BM25 baseline (no model)", dimension: 0, diskMB: 0, loadMS: 0,
            singleShortMS: elapsed / count, singleLongMS: elapsed / count, batchedMS: elapsed / count,
            memoryMB: 0, top1: Double(top1) / count, top3: Double(top3) / count,
            mrr: reciprocalRank / count
        )
    }

    // MARK: - Shared measurement helpers

    struct Retrieval { let top1: Double; let top3: Double; let mrr: Double }

    static func evaluateRetrieval(_ embedder: some Embedder) async throws -> Retrieval {
        let notes = RetrievalSpikeCorpus.notes
        let noteVectors = try await embedder.embed(notes.map(\.text))
        let queryVectors = try await embedder.embed(RetrievalSpikeCorpus.queries.map(\.text))
        var top1 = 0, top3 = 0
        var reciprocalRank = 0.0
        for (index, query) in RetrievalSpikeCorpus.queries.enumerated() {
            let scores = noteVectors.map { EmbeddingMath.dot(queryVectors[index], $0) }
            let ranking = scores.indices.sorted { scores[$0] > scores[$1] }.map { notes[$0].id }
            if ranking.first == query.expected { top1 += 1 }
            if ranking.prefix(3).contains(query.expected) { top3 += 1 }
            if let rank = ranking.firstIndex(of: query.expected) {
                reciprocalRank += 1.0 / Double(rank + 1)
            }
        }
        let count = Double(RetrievalSpikeCorpus.queries.count)
        return Retrieval(
            top1: Double(top1) / count, top3: Double(top3) / count, mrr: reciprocalRank / count
        )
    }

    struct Timing { let mean: Double; let p95: Double }

    static func time(_ iterations: Int, _ body: () async throws -> Void) async rethrows -> Timing {
        for _ in 0 ..< 3 { try await body() } // warm up
        var samples: [Double] = []
        for _ in 0 ..< iterations {
            let start = ContinuousClock.now
            try await body()
            samples.append(milliseconds(since: start))
        }
        return summarize(samples)
    }

    static func timeBatch(
        _ size: Int, iterations: Int, _ body: ([String]) async throws -> Void
    ) async rethrows -> Timing {
        let texts = (0 ..< size).map { index in
            "\(RetrievalSpikeCorpus.notes[index % RetrievalSpikeCorpus.notes.count].text) #\(index)"
        }
        try await body(texts)
        var samples: [Double] = []
        for _ in 0 ..< iterations {
            let start = ContinuousClock.now
            try await body(texts)
            samples.append(milliseconds(since: start))
        }
        return summarize(samples)
    }

    private static func summarize(_ samples: [Double]) -> Timing {
        guard !samples.isEmpty else { return Timing(mean: 0, p95: 0) }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return Timing(mean: samples.reduce(0, +) / Double(samples.count), p95: sorted[index])
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    /// ~32 WordPiece tokens.
    static let shortText = "git reset --soft HEAD~1 undoes the last commit but keeps every change staged, which is what you want before rewriting a message."

    /// ~200 WordPiece tokens.
    static let longText = String(
        repeating: "When a deployment stops picking up a changed ConfigMap the pods have to be recreated; " +
            "kubectl rollout restart deployment/checkout does it without editing the manifest, and " +
            "kubectl rollout status blocks until the new replica set is healthy. ",
        count: 6
    )

    // MARK: - Process metrics

    /// Physical footprint — the number Activity Monitor shows as "Memory".
    /// (`proc_pid_rusage` rather than `task_info`, because `mach_task_self_` is
    /// a mutable global that Swift 6 will not let us touch.)
    static func residentBytes() -> UInt64 {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), Int32(RUSAGE_INFO_CURRENT), rebound)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    static func directorySize(_ url: URL) -> UInt64 {
        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys
        ) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    static func parseComputeUnits(_ raw: String) -> MLComputeUnits {
        switch raw.lowercased() {
        case "cpu", "cpuonly": .cpuOnly
        case "cpuandgpu", "gpu": .cpuAndGPU
        case "cpuandneuralengine", "ane": .cpuAndNeuralEngine
        default: .all
        }
    }

    static func hostDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let cpu = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "\(cpu), \(memory) GB, \(version)"
    }

    static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
    static func format(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// One line of the summary table.
    struct Row {
        let name: String
        let dimension: Int
        let diskMB: Double
        let loadMS: Double
        let singleShortMS: Double
        let singleLongMS: Double
        let batchedMS: Double
        let memoryMB: Double
        let top1: Double
        let top3: Double
        let mrr: Double

        static func printTable(_ rows: [Row]) {
            print("| embedder | dim | disk MB | load ms | short ms | long ms | batched ms/emb | RSS MB | top-1 | top-3 | MRR |")
            print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
            for row in rows {
                let disk = row.diskMB > 0 ? EmbedCommand.format(row.diskMB, digits: 1) : "—"
                print("| \(row.name) | \(row.dimension > 0 ? String(row.dimension) : "—") | \(disk) "
                    + "| \(EmbedCommand.format(row.loadMS)) | \(EmbedCommand.format(row.singleShortMS)) "
                    + "| \(EmbedCommand.format(row.singleLongMS)) | \(EmbedCommand.format(row.batchedMS)) "
                    + "| \(EmbedCommand.format(row.memoryMB, digits: 1)) | \(EmbedCommand.percent(row.top1)) "
                    + "| \(EmbedCommand.percent(row.top3)) | \(EmbedCommand.format(row.mrr, digits: 3)) |")
            }
        }
    }
}
