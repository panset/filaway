import ArgumentParser
import FilawayCore

/// Benchmark harness. Subcommands (`corpus`, `keyword`, `semantic`,
/// `retrieval`, `prompts`) arrive with M1-07 and M3-07.
@main
struct FilawayBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filaway-bench",
        abstract: "Corpus generation and performance benchmarks for Filaway.",
        version: FilawayCore.version,
        subcommands: [EmbedCommand.self]
    )

    func run() throws {
        print("filaway-bench \(FilawayCore.version) — no benchmarks implemented yet.")
        print("Planned subcommands: corpus, keyword, semantic, retrieval, prompts.")
        print("Run 'filaway-bench --help' for usage.")
    }
}
