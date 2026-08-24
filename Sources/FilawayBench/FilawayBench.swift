import ArgumentParser
import FilawayCore
import Foundation

/// Benchmark harness. `scan` lands with M1-05, `keyword` and `all` with M1-07;
/// `semantic`, `retrieval` and `prompts` arrive with M3-07.
@main
struct FilawayBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filaway-bench",
        abstract: "Corpus generation and performance benchmarks for Filaway.",
        version: FilawayCore.version,
        subcommands: [
            Scan.self, Keyword.self, All.self, EmbedCommand.self,
            IndexCommand.self, SemanticCommand.self, RetrievalCommand.self,
            CorpusCommand.self, ChurnCommand.self, LaunchCommand.self, RetrievalLogCommand.self,
            OllamaCommand.self,
        ],
        defaultSubcommand: Scan.self
    )
}

/// A throwaway library under `/tmp`, or an existing notes folder.
struct BenchLibrary {
    let library: Library
    let generated: Bool

    init(root: String?) {
        generated = root == nil
        let notesRoot = root.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("filaway-bench-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
        let supportRoot = notesRoot.deletingLastPathComponent().appendingPathComponent("Support", isDirectory: true)
        library = Library(root: notesRoot, supportRoot: supportRoot)
    }

    func removeIfGenerated() {
        guard generated else { return }
        try? FileManager.default.removeItem(at: library.root.deletingLastPathComponent())
    }
}

func median(_ values: [TimeInterval]) -> TimeInterval { percentile(values, 0.5) }

/// Nearest-rank percentile; `values` need not be sorted.
func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank - 1, 0), sorted.count - 1)]
}

func format(_ seconds: TimeInterval) -> String {
    seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
}

func formatMillis(_ seconds: TimeInterval) -> String {
    String(format: "%.1f ms", seconds * 1000)
}

func megabytes(ofFileAt url: URL) -> Double {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    return Double(size) / 1_048_576
}

/// `filaway-bench scan --notes 5000` — times a cold library scan and a full
/// database rebuild (NFR-2: smooth at 5,000 notes, graceful at 20,000).
struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Time a full library scan and metadata rebuild on a synthetic corpus."
    )

    @Option(name: .shortAndLong, help: "Number of synthetic notes to generate.")
    var notes = 5_000

    @Option(help: "Approximate body size per note, in bytes (NFR-2's 50 MB at 5k notes is 10000).")
    var bytes = 2_048

    @Option(help: "How many times to repeat the timed scan.")
    var repeats = 3

    @Option(help: "Use an existing notes folder instead of generating a corpus.")
    var root: String?

    @Flag(help: "Keep the generated corpus and print its path.")
    var keep = false

    mutating func run() async throws {
        let generated = root == nil
        let notesRoot = root.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("filaway-bench-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
        let supportRoot = notesRoot.deletingLastPathComponent().appendingPathComponent("Support", isDirectory: true)
        let library = Library(root: notesRoot, supportRoot: supportRoot)
        defer {
            if generated, !keep {
                try? FileManager.default.removeItem(at: notesRoot.deletingLastPathComponent())
            }
        }

        if generated {
            let start = Date()
            try SyntheticCorpus.generate(noteCount: notes, into: library, approximateBytes: bytes)
            print("corpus:   \(notes) notes generated in \(format(Date().timeIntervalSince(start)))")
        }

        let store = NoteStore(library: library)
        var scanSeconds: [TimeInterval] = []
        var snapshot = try await store.scan()
        for _ in 0 ..< max(1, repeats) {
            let start = Date()
            snapshot = try await store.scan()
            scanSeconds.append(Date().timeIntervalSince(start))
        }

        let totalBytes = snapshot.notes.reduce(0) { $0 + $1.size }
        print("library:  \(snapshot.notes.count) notes, \(snapshot.folderPaths.count) folders, "
            + "\(String(format: "%.1f", Double(totalBytes) / 1_048_576)) MB")
        print("scan:     min \(format(scanSeconds.min() ?? 0))  median \(format(median(scanSeconds)))  "
            + "max \(format(scanSeconds.max() ?? 0))")

        try? FileManager.default.removeItem(at: library.databaseURL)
        let metadata = try MetadataStore(library: library)
        var rebuildSeconds: [TimeInterval] = []
        for _ in 0 ..< max(1, repeats) {
            let start = Date()
            try await metadata.rebuild(from: snapshot)
            rebuildSeconds.append(Date().timeIntervalSince(start))
        }
        print("rebuild:  min \(format(rebuildSeconds.min() ?? 0))  median \(format(median(rebuildSeconds)))  "
            + "max \(format(rebuildSeconds.max() ?? 0))")
        print("total:    \(format((scanSeconds.min() ?? 0) + (rebuildSeconds.min() ?? 0))) "
            + "(scan + rebuild, best of \(repeats))")

        if keep, generated { print("corpus kept at \(notesRoot.path)") }
    }
}

/// `filaway-bench keyword --notes 5000 --queries 200` — the NFR-1 gate.
///
/// Builds a synthetic corpus, rebuilds the database and its FTS indexes, then
/// runs the five query shapes FR-5.1 promises (word, prefix, two words, a
/// misremembered title, a substring inside a shell command) and reports the
/// distribution. Exits non-zero when p95 reaches 100 ms.
struct Keyword: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyword",
        abstract: "Measure as-you-type keyword search latency on a synthetic corpus (FR-5.1, NFR-1)."
    )

    @Option(name: .shortAndLong, help: "Number of synthetic notes to generate.")
    var notes = 5_000

    @Option(help: "Approximate body size per note, in bytes.")
    var bytes = 2_048

    @Option(help: "How many searches to time in total, spread over the query shapes.")
    var queries = 200

    @Option(help: "Results requested per search, as the UI would.")
    var limit = 25

    @Option(help: "Fail the run when p95 reaches this many milliseconds (NFR-1 is 100).")
    var budgetMillis = 100.0

    @Option(help: "Use an existing notes folder instead of generating a corpus.")
    var root: String?

    @Flag(help: "Keep the generated corpus and print its path.")
    var keep = false

    mutating func run() async throws {
        let bench = BenchLibrary(root: root)
        defer { if !keep { bench.removeIfGenerated() } }

        if bench.generated {
            let start = Date()
            try SyntheticCorpus.generate(noteCount: notes, into: bench.library, approximateBytes: bytes)
            print("corpus:   \(notes) notes generated in \(format(Date().timeIntervalSince(start)))")
        }

        let store = NoteStore(library: bench.library)
        let snapshot = try await store.scan()
        let totalBytes = snapshot.notes.reduce(0) { $0 + $1.size }
        print("library:  \(snapshot.notes.count) notes, "
            + "\(String(format: "%.1f", Double(totalBytes) / 1_048_576)) MB of Markdown")

        try? FileManager.default.removeItem(at: bench.library.databaseURL)
        let metadata = try MetadataStore(library: bench.library)
        let rebuildStart = Date()
        try await metadata.rebuild(from: snapshot)
        let rebuildSeconds = Date().timeIntervalSince(rebuildStart)
        let indexed = try await metadata.textIndexCount()
        print("index:    rebuild \(format(rebuildSeconds)) for \(indexed) notes, "
            + "database \(String(format: "%.1f", megabytes(ofFileAt: bench.library.databaseURL))) MB")

        let search = SearchService(metadata: metadata)
        let shapes = QueryShape.representative(for: snapshot.notes)
        _ = await search.keyword("warm up the caches", limit: limit)

        var timings: [String: [TimeInterval]] = [:]
        var all: [TimeInterval] = []
        var emptyShapes: [String] = []
        for index in 0 ..< max(shapes.count, queries) {
            let shape = shapes[index % shapes.count]
            let start = Date()
            let hits = await search.keyword(shape.query, limit: limit)
            let seconds = Date().timeIntervalSince(start)
            timings[shape.name, default: []].append(seconds)
            all.append(seconds)
            if hits.isEmpty, !emptyShapes.contains(shape.name) { emptyShapes.append(shape.name) }
        }

        print("")
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
        if !emptyShapes.isEmpty {
            print("warning:  no results for \(emptyShapes.joined(separator: ", ")) — the corpus may not contain them")
        }
        if keep, bench.generated { print("corpus kept at \(bench.library.root.path)") }

        guard p95 * 1000 < budgetMillis else {
            print("FAIL      p95 \(formatMillis(p95)) reaches the \(Int(budgetMillis)) ms budget (NFR-1)")
            throw ExitCode.failure
        }
        print("PASS      p95 \(formatMillis(p95)) < \(Int(budgetMillis)) ms (NFR-1)")
    }
}

/// One representative query and the name it reports under.
struct QueryShape {
    let name: String
    let query: String

    /// The five shapes FR-5.1 names, anchored on words the synthetic corpus
    /// actually contains so the timings measure real result sets.
    static func representative(for notes: [NoteSummary]) -> [QueryShape] {
        let title = notes.first(where: { $0.title.count > 12 })?.title ?? "fetch documents 1"
        return [
            QueryShape(name: "single word", query: "tokens"),
            QueryShape(name: "prefix", query: "docum"),
            QueryShape(name: "two words", query: "token budget"),
            QueryShape(name: "typo'd title", query: transpose(title)),
            QueryShape(name: "code substring", query: "pplication/json"),
        ]
    }

    /// Swaps two adjacent characters near the middle — the commonest typo, and
    /// the one plain edit distance is worst at.
    static func transpose(_ text: String) -> String {
        var characters = Array(text)
        guard characters.count > 4 else { return text }
        let index = characters.count / 2
        characters.swapAt(index, index - 1)
        return String(characters)
    }
}

/// `filaway-bench all` — scan and keyword on one shared corpus.
struct All: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "Run every benchmark against a single generated corpus."
    )

    @Option(name: .shortAndLong, help: "Number of synthetic notes to generate.")
    var notes = 5_000

    @Option(help: "Approximate body size per note, in bytes.")
    var bytes = 2_048

    @Option(help: "How many searches to time in total.")
    var queries = 200

    mutating func run() async throws {
        let bench = BenchLibrary(root: nil)
        defer { bench.removeIfGenerated() }
        let start = Date()
        try SyntheticCorpus.generate(noteCount: notes, into: bench.library, approximateBytes: bytes)
        print("corpus:   \(notes) notes generated in \(format(Date().timeIntervalSince(start)))")
        let root = bench.library.root.path

        // Parsed rather than constructed: ArgumentParser's property wrappers
        // only hold values after a parse.
        print("\n=== scan ===")
        var scan = try Scan.parse(["--root", root])
        try await scan.run()

        print("\n=== keyword ===")
        var keyword = try Keyword.parse(["--root", root, "--queries", String(queries)])
        try await keyword.run()
    }
}
