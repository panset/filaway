import ArgumentParser
import FilawayCore
import Foundation

/// Benchmark harness. `scan` lands with M1-05; `corpus`, `keyword`, `semantic`,
/// `retrieval` and `prompts` arrive with M1-07 and M3-07.
@main
struct FilawayBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filaway-bench",
        abstract: "Corpus generation and performance benchmarks for Filaway.",
        version: FilawayCore.version,
        subcommands: [Scan.self],
        defaultSubcommand: Scan.self
    )
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

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func format(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}
