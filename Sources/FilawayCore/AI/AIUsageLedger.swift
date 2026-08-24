import Foundation
import GRDB

/// One billed request.
public struct AIUsageRecord: Sendable, Equatable {
    public var id: Int64?
    public var timestamp: Date
    public var model: String
    public var purpose: AIPurpose
    public var usage: AIUsage
    /// The API's `request-id`, when the provider surfaced one.
    public var requestID: String?
    /// Which provider served it (`claude`, `replay`, …) — replayed traffic
    /// costs nothing and is excluded from totals by default.
    public var provider: String

    public init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        model: String,
        purpose: AIPurpose,
        usage: AIUsage,
        requestID: String? = nil,
        provider: String = "claude"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.purpose = purpose
        self.usage = usage
        self.requestID = requestID
        self.provider = provider
    }
}

/// Aggregated usage for a window (FR-6.6).
public struct AIUsageTotals: Sendable, Equatable {
    public var requests: Int
    public var usage: AIUsage

    public init(requests: Int = 0, usage: AIUsage = AIUsage()) {
        self.requests = requests
        self.usage = usage
    }

    public var inputTokens: Int { usage.inputTokens }
    public var outputTokens: Int { usage.outputTokens }
    public var totalTokens: Int { usage.totalInputTokens + usage.outputTokens }
}

/// The monthly token/request counter behind Settings → AI (FR-6.6).
///
/// **Its own SQLite file**, `ai-usage.sqlite`, next to `filaway.sqlite` in the
/// library's Application Support directory — not a migration on
/// ``MetadataStore``. Two reasons: `DatabaseSchema`'s registry already reserves
/// `v2-fts`, `v3-chunks` and `v4-activity` for milestones being built in
/// parallel, and appending there would collide; and usage is *not* derived from
/// the notes folder, so it must survive `Settings → Rebuild index`, which is
/// free to delete `filaway.sqlite` wholesale. See `docs/decisions.md`.
public actor AIUsageLedger {
    private let dbQueue: DatabaseQueue

    /// The ledger's file inside a library's Application Support directory.
    public static func url(in library: Library) -> URL {
        library.supportDirectory.appendingPathComponent("ai-usage.sqlite", isDirectory: false)
    }

    /// Where an unreadable `ai-usage.sqlite` was moved before this ledger opened
    /// a fresh one — `nil` in the normal case. Losing it costs a month of
    /// counters, never a note (NFR-3, ADR-049).
    public let recoveredFromCorruption: URL?

    /// Opens (creating if needed) `<supportDirectory>/ai-usage.sqlite`.
    public init(library: Library) throws {
        try FileManager.default.createDirectory(at: library.supportDirectory, withIntermediateDirectories: true)
        let opened = try DatabaseFile.open(at: Self.url(in: library), configuration: Configuration()) { queue in
            try AIUsageLedger.migrator.migrate(queue)
        }
        dbQueue = opened.queue
        recoveredFromCorruption = opened.movedAside
    }

    /// In-memory ledger, for tests and `filaway-bench`.
    public init(inMemory: Bool = true) throws {
        dbQueue = try DatabaseQueue()
        recoveredFromCorruption = nil
        try AIUsageLedger.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-ai-usage") { db in
            try db.create(table: "ai_usage") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("timestamp", .double).notNull()
                table.column("model", .text).notNull()
                table.column("purpose", .text).notNull()
                table.column("provider", .text).notNull().defaults(to: "claude")
                table.column("input_tokens", .integer).notNull().defaults(to: 0)
                table.column("output_tokens", .integer).notNull().defaults(to: 0)
                table.column("cache_creation_input_tokens", .integer).notNull().defaults(to: 0)
                table.column("cache_read_input_tokens", .integer).notNull().defaults(to: 0)
                table.column("request_id", .text)
            }
            try db.create(index: "ai_usage_on_timestamp", on: "ai_usage", columns: ["timestamp"])
        }
        return migrator
    }

    // MARK: - Writing

    /// Records one request. Never throws away the caller's work: a ledger write
    /// failure must not fail the request that produced it, so callers should
    /// `try?` this.
    @discardableResult
    public func record(_ record: AIUsageRecord) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO ai_usage
                  (timestamp, model, purpose, provider, input_tokens, output_tokens,
                   cache_creation_input_tokens, cache_read_input_tokens, request_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.timestamp.timeIntervalSince1970,
                    record.model,
                    record.purpose.rawValue,
                    record.provider,
                    record.usage.inputTokens,
                    record.usage.outputTokens,
                    record.usage.cacheCreationInputTokens,
                    record.usage.cacheReadInputTokens,
                    record.requestID,
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Records the outcome of a provider call.
    @discardableResult
    public func record(
        response: AIResponse,
        purpose: AIPurpose,
        provider: String = "claude",
        at timestamp: Date = Date()
    ) throws -> Int64 {
        try record(AIUsageRecord(
            timestamp: timestamp,
            model: response.model,
            purpose: purpose,
            usage: response.usage,
            requestID: response.requestID,
            provider: provider
        ))
    }

    // MARK: - Reading

    public func allRecords() throws -> [AIUsageRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_usage ORDER BY timestamp, id").map(Self.record(from:))
        }
    }

    /// Totals over a half-open interval.
    ///
    /// - Parameter provider: one ``AIProvider/identifier``, or `nil` for every
    ///   provider at once. The default is Claude because it is the only one that
    ///   bills; replayed, mocked and local traffic is excluded from it.
    public func totals(from start: Date, to end: Date, provider: String? = "claude") throws -> AIUsageTotals {
        try dbQueue.read { db in
            var sql = """
            SELECT COUNT(*) AS requests,
                   COALESCE(SUM(input_tokens), 0) AS input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS output_tokens,
                   COALESCE(SUM(cache_creation_input_tokens), 0) AS cache_creation_input_tokens,
                   COALESCE(SUM(cache_read_input_tokens), 0) AS cache_read_input_tokens
            FROM ai_usage WHERE timestamp >= ? AND timestamp < ?
            """
            var arguments: [DatabaseValueConvertible?] = [start.timeIntervalSince1970, end.timeIntervalSince1970]
            if let provider {
                sql += " AND provider = ?"
                arguments.append(provider)
            }
            guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) else {
                return AIUsageTotals()
            }
            return AIUsageTotals(requests: row["requests"], usage: Self.usage(from: row))
        }
    }

    /// Totals for the calendar month containing `date` — what Settings shows.
    public func monthlyTotals(
        containing date: Date = Date(),
        calendar: Calendar = .current,
        provider: String? = "claude"
    ) throws -> AIUsageTotals {
        let (start, end) = Self.monthBounds(containing: date, calendar: calendar)
        return try totals(from: start, to: end, provider: provider)
    }

    /// Per-purpose split for the same month, so Settings can say how much of the
    /// bill is organizing versus searching.
    public func monthlyTotalsByPurpose(
        containing date: Date = Date(),
        calendar: Calendar = .current,
        provider: String? = "claude"
    ) throws -> [AIPurpose: AIUsageTotals] {
        let (start, end) = Self.monthBounds(containing: date, calendar: calendar)
        return try dbQueue.read { db in
            var sql = """
            SELECT purpose,
                   COUNT(*) AS requests,
                   COALESCE(SUM(input_tokens), 0) AS input_tokens,
                   COALESCE(SUM(output_tokens), 0) AS output_tokens,
                   COALESCE(SUM(cache_creation_input_tokens), 0) AS cache_creation_input_tokens,
                   COALESCE(SUM(cache_read_input_tokens), 0) AS cache_read_input_tokens
            FROM ai_usage WHERE timestamp >= ? AND timestamp < ?
            """
            var arguments: [DatabaseValueConvertible?] = [start.timeIntervalSince1970, end.timeIntervalSince1970]
            if let provider {
                sql += " AND provider = ?"
                arguments.append(provider)
            }
            sql += " GROUP BY purpose"
            var out: [AIPurpose: AIUsageTotals] = [:]
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)) {
                guard let purpose = AIPurpose(rawValue: row["purpose"]) else { continue }
                out[purpose] = AIUsageTotals(requests: row["requests"], usage: Self.usage(from: row))
            }
            return out
        }
    }

    /// Drops rows older than `date`. The ledger holds no note content, but it
    /// should not grow forever either.
    @discardableResult
    public func prune(before date: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ai_usage WHERE timestamp < ?", arguments: [date.timeIntervalSince1970])
            return db.changesCount
        }
    }

    // MARK: - By provider kind (P2-01)

    /// Totals for one backend. `nil` in the `String?` overloads means *every*
    /// provider, replayed and mocked traffic included; this overload is the
    /// typed way to ask for exactly one (`.ollama` costs nothing, but knowing
    /// how much work went local is the point of FR-6.5).
    public func totals(from start: Date, to end: Date, provider: AIProviderKind) throws -> AIUsageTotals {
        try totals(from: start, to: end, provider: provider.rawValue)
    }

    public func monthlyTotals(
        containing date: Date = Date(),
        calendar: Calendar = .current,
        provider: AIProviderKind
    ) throws -> AIUsageTotals {
        try monthlyTotals(containing: date, calendar: calendar, provider: provider.rawValue)
    }

    public func monthlyTotalsByPurpose(
        containing date: Date = Date(),
        calendar: Calendar = .current,
        provider: AIProviderKind
    ) throws -> [AIPurpose: AIUsageTotals] {
        try monthlyTotalsByPurpose(containing: date, calendar: calendar, provider: provider.rawValue)
    }

    // MARK: - Helpers

    static func monthBounds(containing date: Date, calendar: Calendar) -> (start: Date, end: Date) {
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return (start, end)
    }

    private static func usage(from row: Row) -> AIUsage {
        AIUsage(
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            cacheCreationInputTokens: row["cache_creation_input_tokens"],
            cacheReadInputTokens: row["cache_read_input_tokens"]
        )
    }

    private static func record(from row: Row) -> AIUsageRecord {
        AIUsageRecord(
            id: row["id"],
            timestamp: Date(timeIntervalSince1970: row["timestamp"]),
            model: row["model"],
            purpose: AIPurpose(rawValue: row["purpose"]) ?? .organize,
            usage: usage(from: row),
            requestID: row["request_id"],
            provider: row["provider"]
        )
    }
}
