import Foundation

/// One "did you find it?" entry from the M4-11 dogfood week (spec §8).
///
/// Spec §8's second criterion is *"find a specific stored command via natural
/// language in under 10 seconds, at least 90% of the time"*. The M3-07
/// benchmark measures that against a fixed corpus of one developer's notes;
/// this measures it against the only corpus that settles it — the user's own
/// library, over a week of real searches.
public struct RetrievalOutcome: Codable, Sendable, Equatable {
    /// When the search happened.
    public var at: Date
    /// What was typed. The one piece of user text in the file, and the reason
    /// the log never leaves the machine (see ``RetrievalOutcomeLog``).
    public var query: String
    /// Whether the note the user wanted was found at all.
    public var found: Bool
    /// Wall-clock seconds from starting to type to having the answer.
    public var seconds: Double
    /// Free-form, optional: "it was third", "I had to rephrase".
    public var note: String?

    public init(at: Date = Date(), query: String, found: Bool, seconds: Double, note: String? = nil) {
        self.at = at
        self.query = query
        self.found = found
        self.seconds = max(0, seconds)
        self.note = (note?.isEmpty ?? true) ? nil : note
    }
}

/// The append-only JSONL file behind Help → "Log Retrieval Outcome…" (M4-11).
///
/// ```
/// ~/Library/Application Support/Filaway/retrieval-log.jsonl
/// ```
///
/// **Deliberately outside the per-library folder.** The point of the log is a
/// week of the user's own searching; pointing the app at a different notes
/// folder mid-week must not split the sample in two, so the path has no
/// `libraryKey` in it.
///
/// **NFR-4.** This file holds *queries*, which are user text, so it is local
/// only: nothing uploads it, and `Help → Export diagnostics` must not include
/// it (M4-08 owns that exclusion). Note *content* never enters it — an outcome
/// is a query, a yes/no and a stopwatch reading.
///
/// One JSON object per line, appended with `O_APPEND`, so a crash mid-week
/// costs at most the line being written and `filaway-bench retrieval-log
/// summarize` can read a file the app still has open.
public struct RetrievalOutcomeLog: Sendable {
    public let url: URL

    /// The default location: `<Application Support>/Filaway/retrieval-log.jsonl`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Filaway", isDirectory: true)
            .appendingPathComponent("retrieval-log.jsonl", isDirectory: false)
    }

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    // MARK: - Writing

    /// Appends one outcome. Creates the file and its folder on first use.
    public func append(_ outcome: RetrievalOutcome) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so a human reading the file sees the same shape twice,
        // and so a diff of two logs is a diff of their contents.
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(outcome)
        line.append(0x0A)

        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    // MARK: - Reading

    /// Every outcome in the file, oldest first. A malformed line is skipped,
    /// not fatal: this is a hand-editable file.
    public func readAll() throws -> [RetrievalOutcome] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(RetrievalOutcome.self, from: Data(line.utf8))
            }
            .sorted { $0.at < $1.at }
    }

    /// What spec §8 asks for, computed over a log.
    public struct Summary: Sendable, Equatable {
        public var count = 0
        public var hits = 0
        public var misses: [RetrievalOutcome] = []
        public var overBudget: [RetrievalOutcome] = []
        /// Median seconds over **every** entry, hit or miss.
        public var medianSeconds: Double = 0
        /// Median seconds over the hits alone — the number §8's "under 10
        /// seconds" is really about.
        public var medianHitSeconds: Double = 0
        public var p90Seconds: Double = 0
        public var maxSeconds: Double = 0
        public var firstAt: Date?
        public var lastAt: Date?
        /// Distinct days the log has entries on — a week of dogfooding is
        /// seven of these, not seven entries.
        public var days = 0

        /// Fraction found at all.
        public var hitRate: Double { count == 0 ? 0 : Double(hits) / Double(count) }
        /// Fraction found **and** inside the budget — the actual §8 criterion.
        public var successRate: Double {
            count == 0 ? 0 : Double(hits - overBudget.count) / Double(count)
        }

        public var meetsSpecSection8: Bool { count > 0 && successRate >= 0.90 }
    }

    /// Spec §8's criterion: found, in under `budgetSeconds`, at least 90% of
    /// the time.
    public static func summarize(
        _ outcomes: [RetrievalOutcome], budgetSeconds: Double = 10
    ) -> Summary {
        var summary = Summary()
        guard !outcomes.isEmpty else { return summary }
        summary.count = outcomes.count
        summary.hits = outcomes.count(where: { $0.found })
        summary.misses = outcomes.filter { !$0.found }
        summary.overBudget = outcomes.filter { $0.found && $0.seconds > budgetSeconds }
        summary.medianSeconds = percentile(outcomes.map(\.seconds), 0.5)
        summary.medianHitSeconds = percentile(outcomes.filter(\.found).map(\.seconds), 0.5)
        summary.p90Seconds = percentile(outcomes.map(\.seconds), 0.9)
        summary.maxSeconds = outcomes.map(\.seconds).max() ?? 0
        summary.firstAt = outcomes.map(\.at).min()
        summary.lastAt = outcomes.map(\.at).max()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        summary.days = Set(outcomes.map { calendar.startOfDay(for: $0.at) }).count
        return summary
    }

    /// Nearest-rank percentile over an unsorted array.
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
