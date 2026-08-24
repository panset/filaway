import Foundation

/// `DateRange` is a search type and has no business knowing about JSON; the
/// bench module needs it encodable so a run can be replayed from its report.
/// Written out by hand because synthesis only happens in the declaring file.
extension DateRange: Codable {
    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try container.decode(Date.self, forKey: .start),
            end: try container.decode(Date.self, forKey: .end)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}

/// What kind of retrieval a query exercises. The benchmark reports every metric
/// per category, because the shapes fail in different ways: a `command` query
/// that misses is a BM25 problem, a `paraphrase` that misses is an embedding
/// problem, and a `temporal` that misses is usually the parser.
public enum RetrievalCategory: String, Codable, Sendable, CaseIterable {
    /// Names the tool: "the jq one-liner that pulled the ids".
    case command
    /// Describes the outcome, never the tool: "count which errors happen most".
    case paraphrase
    /// Carries a time phrase (FR-5.3): "the auth thing from two days ago".
    case temporal
    /// Misspelled, as typed in a hurry.
    case typo
    /// Nothing in the corpus answers it. The right behaviour is to say so.
    case negative
}

/// One benchmark query (M3-07).
public struct RetrievalQuery: Codable, Sendable, Equatable {
    public var id: String
    public var category: RetrievalCategory
    public var text: String
    /// Path of the note that answers it, relative to the library root.
    /// `nil` for ``RetrievalCategory/negative``.
    public var expectedPath: String?
    /// A substring of the chunk that answers it — the answer card's content
    /// (FR-5.2). Matched against the selected chunk's text after collapsing
    /// whitespace, so line wrapping in the note does not matter.
    public var expectedSnippet: String?
    /// Overrides the set's `now`, for a query whose phrasing needs one.
    public var now: Date?
    /// The date range the temporal parser is expected to produce, if any.
    /// Purely an assertion — the runner never feeds it to the search.
    public var expectedRange: Range?
    /// Free-text note for whoever reads a failure.
    public var comment: String?

    public struct Range: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var dateRange: DateRange { DateRange(start: start, end: end) }
    }

    public var isNegative: Bool { expectedPath == nil }
}

/// `Tests/Fixtures/queries/dev.json` (M3-07).
public struct RetrievalQuerySet: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// The instant every relative date phrase is resolved against. Fixed in the
    /// file, because "two days ago" has to mean the same thing in 2027.
    public var now: Date
    /// IANA identifier the runner's calendar uses, so "last week" is the same
    /// Monday-to-Sunday on a developer's machine and on a CI runner.
    public var timeZone: String
    public var description: String?
    public var queries: [RetrievalQuery]

    public init(
        version: Int = RetrievalQuerySet.currentVersion,
        now: Date,
        timeZone: String = "UTC",
        description: String? = nil,
        queries: [RetrievalQuery]
    ) {
        self.version = version
        self.now = now
        self.timeZone = timeZone
        self.description = description
        self.queries = queries
    }

    public var positives: [RetrievalQuery] { queries.filter { !$0.isNegative } }
    public var negatives: [RetrievalQuery] { queries.filter(\.isNegative) }

    /// The calendar temporal parsing must use for the fixed `now` to mean what
    /// the file says. Monday-first, so "last week" is Monday to Sunday.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    public func now(for query: RetrievalQuery) -> Date { query.now ?? now }

    // MARK: - Codable

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.date(from: raw) else {
                throw BenchError.querySetInvalid("bad date \(raw)")
            }
            return date
        }
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        return encoder
    }

    public static func load(from url: URL = DevCorpus.defaultQuerySetURL) throws -> RetrievalQuerySet {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchError.querySetMissing(url.path)
        }
        return try decoder.decode(RetrievalQuerySet.self, from: Data(contentsOf: url))
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }
}
