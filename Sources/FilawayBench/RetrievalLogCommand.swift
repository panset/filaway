import ArgumentParser
import FilawayCore
import Foundation

/// `filaway-bench retrieval-log summarize` — the M4-11 read-back.
///
/// Help → "Log Retrieval Outcome…" appends a line per search to
/// `~/Library/Application Support/Filaway/retrieval-log.jsonl`; this turns a
/// week of those lines into the two numbers spec §8 asks for — the hit rate
/// and the median seconds — and names every entry that failed the bar, because
/// the misses are the only part of the log worth reading twice.
struct RetrievalLogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retrieval-log",
        abstract: "Read back the Help → Log Retrieval Outcome… dogfood log (M4-11, spec §8).",
        subcommands: [Summarize.self, Add.self],
        defaultSubcommand: Summarize.self
    )

    /// `filaway-bench retrieval-log summarize`
    struct Summarize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "summarize",
            abstract: "Hit rate and median seconds over the retrieval log."
        )

        @Option(help: "Log file to read (default: Application Support/Filaway/retrieval-log.jsonl).")
        var file: String?

        @Option(help: "Seconds a search may take and still count as a success (spec §8: 10).")
        var budgetSeconds = 10.0

        @Flag(help: "List every entry, not just the failures.")
        var all = false

        mutating func run() async throws {
            let log = RetrievalOutcomeLog(url: file.map { URL(fileURLWithPath: $0) })
            let outcomes = try log.readAll()
            print("# filaway-bench retrieval-log — spec §8 success criteria")
            print("")
            print("file:     \(log.url.path)")
            guard !outcomes.isEmpty else {
                print("")
                print("empty — nothing logged yet. Use Help → “Log Retrieval Outcome…” after a ⌘K search.")
                return
            }

            let summary = RetrievalOutcomeLog.summarize(outcomes, budgetSeconds: budgetSeconds)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            let first = summary.firstAt.map(formatter.string(from:)) ?? "—"
            let last = summary.lastAt.map(formatter.string(from:)) ?? "—"
            print("window:   \(first) → \(last) (\(summary.days) \(summary.days == 1 ? "day" : "days"))")
            print("searches: \(summary.count)")
            print("")
            let label = { (text: String) in text.padding(toLength: 15, withPad: " ", startingAt: 0) }
            print("\(label("hit rate:"))\(percent(summary.hitRate)) "
                + "(\(summary.hits)/\(summary.count) found)")
            print("\(label("under \(Int(budgetSeconds)) s:"))\(percent(summary.successRate)) "
                + "— found *and* inside the budget (spec §8 bar: 90%)")
            print("\(label("median:"))\(seconds(summary.medianSeconds)) over every search")
            print("\(label("median (hits):"))\(seconds(summary.medianHitSeconds))")
            print("\(label("p90 / max:"))\(seconds(summary.p90Seconds)) / \(seconds(summary.maxSeconds))")

            if !summary.misses.isEmpty {
                print("")
                print("not found (\(summary.misses.count)):")
                for outcome in summary.misses { print("  \(line(outcome))") }
            }
            if !summary.overBudget.isEmpty {
                print("")
                print("found but over \(Int(budgetSeconds)) s (\(summary.overBudget.count)):")
                for outcome in summary.overBudget { print("  \(line(outcome))") }
            }
            if all {
                print("")
                print("every entry:")
                for outcome in outcomes { print("  \(line(outcome))") }
            }

            print("")
            if summary.meetsSpecSection8 {
                print("PASS      \(percent(summary.successRate)) ≥ 90% found in under \(Int(budgetSeconds)) s")
            } else {
                print("BELOW BAR \(percent(summary.successRate)) < 90% found in under "
                    + "\(Int(budgetSeconds)) s — see the entries above")
            }
            if summary.days < 7 {
                print("note:     \(summary.days) of the 7 dogfood days logged; the sample is not the week yet")
            }
        }

        private func line(_ outcome: RetrievalOutcome) -> String {
            let stamp = ISO8601DateFormatter().string(from: outcome.at)
            let suffix = outcome.note.map { " — \($0)" } ?? ""
            return "\(stamp)  \(seconds(outcome.seconds).padding(toLength: 8, withPad: " ", startingAt: 0))"
                + "  “\(outcome.query)”\(suffix)"
        }

        private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
    }

    /// `filaway-bench retrieval-log add` — the same append the menu item does,
    /// for scripting the protocol and for testing it without a GUI session.
    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Append one outcome, the way Help → Log Retrieval Outcome… does."
        )

        @Argument(help: "The query that was typed.")
        var query: String

        @Option(help: "Seconds from starting to type to having the answer.")
        var seconds: Double

        @Flag(inversion: .prefixedNo, help: "Whether the note was found at all.")
        var found = true

        @Option(help: "Free-form remark.")
        var note: String?

        @Option(help: "Log file to append to.")
        var file: String?

        mutating func run() async throws {
            let log = RetrievalOutcomeLog(url: file.map { URL(fileURLWithPath: $0) })
            try log.append(RetrievalOutcome(query: query, found: found, seconds: seconds, note: note))
            print("appended to \(log.url.path)")
        }
    }
}
