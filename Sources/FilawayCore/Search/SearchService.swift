import Foundation
import GRDB

/// Why a note is in the result list, best first (FR-5.1).
public enum MatchSource: String, Sendable, Equatable, CaseIterable {
    /// The title is the query.
    case titleExact
    /// The title starts with the query.
    case titlePrefix
    /// A word of the title starts with the query.
    case titleWord
    /// The query appears somewhere in the title.
    case titleSubstring
    /// The title is within an edit or two of the query.
    case titleFuzzy
    /// A word (or word prefix) of the body matches.
    case body
    /// The query appears in the body as a raw substring — inside a command, a
    /// path, an identifier.
    case bodySubstring
    /// No query: the note is simply recent.
    case recent

    var isTitle: Bool {
        switch self {
        case .titleExact, .titlePrefix, .titleWord, .titleSubstring, .titleFuzzy: true
        case .body, .bodySubstring, .recent: false
        }
    }
}

/// One keyword search result.
///
/// Everything the results list needs, plus ``matchRange`` — where in the note's
/// body the match sits, in UTF-16 units, so opening the result can scroll
/// straight to it (FR-5.2).
public struct KeywordHit: Sendable, Equatable, Identifiable {
    public let id: NoteID
    public let title: String
    public let relativePath: String
    public let modified: Date
    /// One line of context around the match, whitespace collapsed.
    public let snippet: String
    /// The best match in the note **body**, or `nil` when only the title
    /// matched (or the query was empty).
    public let matchRange: MatchRange?
    /// The same match, located inside ``snippet`` — for highlighting the row.
    public let snippetRange: MatchRange?
    public let source: MatchSource
    /// Higher is better. Ordering is title kinds first, then body relevance,
    /// then recency; the number exists for tests and for the app's own merging.
    public let score: Double

    public init(
        id: NoteID,
        title: String,
        relativePath: String,
        modified: Date,
        snippet: String,
        matchRange: MatchRange?,
        snippetRange: MatchRange?,
        source: MatchSource,
        score: Double
    ) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.modified = modified
        self.snippet = snippet
        self.matchRange = matchRange
        self.snippetRange = snippetRange
        self.source = source
        self.score = score
    }
}

/// As-you-type keyword search over titles and bodies (FR-5.1, NFR-1).
///
/// Offline, no AI, and no state of its own beyond a cache of titles. It reads
/// the derived database through ``MetadataStore/reader``, off the store's
/// actor, so a query in flight never queues behind an autosave.
///
/// ```swift
/// let search = SearchService(metadata: metadata)
/// let hits = await search.keyword("docker comp", limit: 20)
/// // hits[0].matchRange -> scroll the editor there
/// ```
///
/// Each keystroke is a fresh call; the caller cancels the previous `Task` and
/// starts another. Every stage checks `Task.isCancelled`, and a cancelled
/// search returns an empty array rather than a stale one.
public actor SearchService {
    private let reader: any DatabaseReader
    private let log = Log.index

    /// How many rows each FTS pass may contribute before merging.
    private let candidateLimit = 100

    /// The title cache: identity in `titles`, folded UTF-8 in one flat
    /// `titleBytes` buffer, and a trivial `spans[i]` describing row `i`.
    private var titles: [TitleEntry] = []
    private var titleBytes: [UInt8] = []
    private var spans: [TitleSpan] = []
    private var titlesToken: String?

    public init(metadata: MetadataStore) {
        reader = metadata.reader
    }

    /// For tests and `filaway-bench`, which already hold a reader.
    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    // MARK: - Keyword search

    /// Ranked matches for `query`.
    ///
    /// An empty query yields the most recently touched notes, which is what the
    /// ⌘K palette shows before anything is typed.
    public func keyword(_ query: String, limit: Int = 25) async -> [KeywordHit] {
        let parsed = SearchQuery(query)
        guard !parsed.isEmpty else { return await recent(limit: limit) }

        do {
            var candidates: [NoteID: Candidate] = [:]
            var trace = Trace()
            try await refreshTitlesIfNeeded()
            trace.lap("cache")
            if Task.isCancelled { return [] }

            for candidate in matchTitles(parsed) { merge(candidate, into: &candidates) }
            trace.lap("titles")
            if Task.isCancelled { return [] }

            for candidate in try await matchBodies(parsed, limit: limit) { merge(candidate, into: &candidates) }
            trace.lap("bodies")
            if Task.isCancelled { return [] }

            let ranked = candidates.values
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                    return lhs.relativePath < rhs.relativePath
                }
                .prefix(max(0, limit))

            let results = try await hits(for: Array(ranked), query: parsed)
            trace.lap("hydrate")
            trace.finish(candidates: candidates.count, results: results.count)
            return results
        } catch is CancellationError {
            return []
        } catch {
            log.error("keyword search failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The most recently edited or opened notes — the empty-query result.
    public func recent(limit: Int = 25) async -> [KeywordHit] {
        do {
            let rows: [RecentRow] = try await reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, relpath, title, mtime FROM notes
                    ORDER BY MAX(COALESCE(last_opened, 0), mtime) DESC, relpath ASC
                    LIMIT ?
                    """, arguments: [max(0, limit)])
                    .map { RecentRow(id: $0["id"], relpath: $0["relpath"], title: $0["title"], mtime: $0["mtime"]) }
            }
            let bodies = try await self.bodies(for: rows.map(\.id))
            return rows.map { row in
                KeywordHit(
                    id: NoteID(row.id) ?? NoteID(),
                    title: row.title,
                    relativePath: row.relpath,
                    modified: Date(timeIntervalSince1970: row.mtime),
                    snippet: bodies[row.id].map(SnippetBuilder.head(of:)) ?? "",
                    matchRange: nil,
                    snippetRange: nil,
                    source: .recent,
                    score: 0
                )
            }
        } catch {
            log.error("recents failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Drops the cached titles. The store's write paths do not notify anyone,
    /// so the cache is normally revalidated by a cheap digest query; call this
    /// after a rebuild if you want the next search to start clean.
    public func invalidate() {
        titles = []
        titleBytes = []
        spans = []
        titlesToken = nil
    }

    // MARK: - Title pass

    /// Titles are matched in Swift, not SQL: the whole set is a few hundred
    /// kilobytes, exact/prefix/substring/fuzzy all want the same folded bytes,
    /// and SQLite's `LIKE` is only case-insensitive for ASCII.
    ///
    /// The scan runs over one flat byte buffer and one array of trivial spans,
    /// so 20,000 titles cost no retains, no bounds checks and no allocations —
    /// which is the difference between a comfortable keystroke and a visible
    /// one on a debug build.
    private func matchTitles(_ query: SearchQuery) -> [Candidate] {
        let needleBytes = Array(query.folded.utf8)
        guard !needleBytes.isEmpty, !spans.isEmpty else { return [] }
        let tolerance = Fuzzy.tolerance(forLength: query.folded.count)
        let fuzzyWords = query.terms.count == 1
        let needleSignature = Fuzzy.signature(needleBytes)

        var found: [(index: Int, source: MatchSource, score: Double)] = []
        titleBytes.withUnsafeBufferPointer { buffer in
            needleBytes.withUnsafeBufferPointer { needle in
                guard let base = buffer.baseAddress, let needleBase = needle.baseAddress else { return }
                let needleCount = needle.count
                for index in spans.indices {
                    let span = spans[index]
                    let text = base + span.start
                    let count = span.count
                    var source: MatchSource?
                    var score = 0.0

                    if ByteMatch.equal(text, count, needleBase, needleCount) {
                        source = .titleExact
                        score = 1_000
                    } else if ByteMatch.hasPrefix(text, count, needleBase, needleCount) {
                        source = .titlePrefix
                        // A short title that is nearly the query beats a long one.
                        score = 900 - min(50, Double(count - needleCount)) / 10
                    } else if ByteMatch.startsWord(text, count, needleBase, needleCount) {
                        source = .titleWord
                        score = 850
                    } else if ByteMatch.contains(text, count, needleBase, needleCount) {
                        source = .titleSubstring
                        score = 800
                    } else if tolerance > 0,
                              (needleSignature & ~span.signature).nonzeroBitCount <= tolerance {
                        var distance: Int?
                        if abs(count - needleCount) <= tolerance,
                           (span.signature & ~needleSignature).nonzeroBitCount <= tolerance {
                            distance = Fuzzy.distance(
                                text, count, needleBase, needleCount, maxDistance: tolerance
                            )
                        }
                        if distance == nil, fuzzyWords {
                            // A word-level hit is a weaker signal than a
                            // whole-title one, so it costs an extra edit.
                            distance = Fuzzy.wordDistance(
                                text, count, needleBase, needleCount, maxDistance: tolerance
                            ).map { $0 + 1 }
                        }
                        if let distance {
                            source = .titleFuzzy
                            score = 700 - Double(distance) * 40
                        }
                    }

                    if let source { found.append((index, source, score)) }
                }
            }
        }

        return found.map { match in
            let entry = titles[match.index]
            return Candidate(
                id: entry.id,
                title: entry.title,
                relativePath: entry.relativePath,
                modified: entry.modified,
                source: match.source,
                score: match.score
            )
        }
    }

    // MARK: - Body pass

    private func matchBodies(_ query: SearchQuery, limit: Int) async throws -> [Candidate] {
        var out: [Candidate] = []
        if let expression = query.unicode61Expression {
            out += try await ftsCandidates(
                table: "notes_fts",
                expression: expression,
                source: .body,
                base: 500,
                ranked: true
            )
        }
        if Task.isCancelled { return out }
        // Trigram is what finds `pplication/json` inside a curl command, or an
        // emoji, or a fragment of a path — anything a word tokenizer cannot
        // see. It is by far the more expensive index (its posting lists cover
        // every three-character window of the library), so it is a *fallback*:
        // it runs when the word pass could not express the query at all, or
        // when it came back with less than a screenful.
        let sparse = out.count < max(limit, 10)
        if sparse || query.unicode61Expression == nil, let expression = query.trigramExpression {
            out += try await ftsCandidates(
                table: "notes_trigram",
                expression: expression,
                source: .bodySubstring,
                base: 450,
                ranked: false
            )
        }
        return out
    }

    /// - Parameter ranked: order by bm25. FTS5 can only do that by scoring every
    ///   document that matches, which is the right price for the word index and
    ///   the wrong one for the trigram fallback — there, an unordered `LIMIT`
    ///   lets SQLite stop as soon as it has enough rows, and the merge below
    ///   orders what comes back by recency anyway.
    private func ftsCandidates(
        table: String,
        expression: String,
        source: MatchSource,
        base: Double,
        ranked: Bool
    ) async throws -> [Candidate] {
        let limit = candidateLimit
        let order = ranked ? "ORDER BY rank" : ""
        let rows: [FTSRow] = try await reader.read { db in
            do {
                // The ranking happens in the subquery, so the joins run for the
                // handful of rows that survive the LIMIT rather than for every
                // document that contains the word.
                return try Row.fetchAll(db, sql: """
                    SELECT t.note_id AS note_id, t.relpath AS relpath, t.title AS title,
                           n.mtime AS mtime, top.rank AS rank
                    FROM (
                        SELECT rowid AS rid, \(ranked ? "rank" : "0") AS rank FROM \(table)
                        WHERE \(table) MATCH ? \(order) LIMIT ?
                    ) top
                    JOIN note_text t ON t.rowid = top.rid
                    JOIN notes n ON n.id = t.note_id
                    ORDER BY top.rank
                    """, arguments: [expression, limit])
                    .map {
                        FTSRow(
                            id: $0["note_id"], relpath: $0["relpath"], title: $0["title"],
                            mtime: $0["mtime"], rank: $0["rank"] ?? 0
                        )
                    }
            } catch {
                // A `MATCH` can still be rejected — an unsupported query for the
                // trigram tokenizer, say. Never let that reach the UI as a
                // crash or an error sheet; a keystroke simply finds nothing.
                return []
            }
        }
        return rows.map { row in
            // bm25 is negative, best first; keep it bounded so the band a hit
            // belongs to (title vs body vs substring) always dominates.
            let relevance = min(80, max(0, -row.rank * 4))
            return Candidate(
                id: NoteID(row.id) ?? NoteID(),
                title: row.title,
                relativePath: row.relpath,
                modified: Date(timeIntervalSince1970: row.mtime),
                source: source,
                score: base + relevance
            )
        }
    }

    // MARK: - Hydration

    /// Turns the winners into hits, reading only their bodies — at most `limit`
    /// notes, not the whole candidate set.
    private func hits(for candidates: [Candidate], query: SearchQuery) async throws -> [KeywordHit] {
        guard !candidates.isEmpty else { return [] }
        let bodies = try await self.bodies(for: candidates.map(\.id.uuidString))
        return candidates.map { candidate in
            let body = bodies[candidate.id.uuidString] ?? ""
            let match = SnippetBuilder.bestMatch(of: query, in: body)
            let snippet = SnippetBuilder.snippet(of: body, around: match)
            return KeywordHit(
                id: candidate.id,
                title: candidate.title,
                relativePath: candidate.relativePath,
                modified: candidate.modified,
                snippet: snippet.text,
                matchRange: match.flatMap { MatchRange($0, in: body) },
                snippetRange: snippet.range,
                source: candidate.source,
                score: candidate.score
            )
        }
    }

    private func bodies(for ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try await reader.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT note_id, body FROM note_text WHERE note_id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            ) {
                out[row["note_id"]] = row["body"]
            }
            return out
        }
    }

    // MARK: - Title cache

    /// Revalidates the title cache against ``MetadataStore``'s generation
    /// counter — one indexed lookup, bumped by every write that touches
    /// `notes`, so the cache refreshes exactly when the library changed and
    /// never on a keystroke that changed nothing.
    private func refreshTitlesIfNeeded() async throws {
        let token: String = try await reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'notes_generation'") ?? "0"
        }
        guard token != titlesToken else { return }
        let rows: [RecentRow] = try await reader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, relpath, title, mtime FROM notes")
                .map { RecentRow(id: $0["id"], relpath: $0["relpath"], title: $0["title"], mtime: $0["mtime"]) }
        }
        titles = rows.map {
            TitleEntry(
                id: NoteID($0.id) ?? NoteID(),
                title: $0.title,
                relativePath: $0.relpath,
                modified: Date(timeIntervalSince1970: $0.mtime)
            )
        }
        titleBytes = []
        titleBytes.reserveCapacity(rows.count * 24)
        spans = []
        spans.reserveCapacity(rows.count)
        for row in rows {
            let bytes = Array(SearchQuery.fold(row.title).utf8)
            spans.append(TitleSpan(
                start: titleBytes.count,
                count: bytes.count,
                signature: Fuzzy.signature(bytes)
            ))
            titleBytes.append(contentsOf: bytes)
        }
        titlesToken = token
    }

    private func merge(_ candidate: Candidate, into candidates: inout [NoteID: Candidate]) {
        if let existing = candidates[candidate.id], existing.score >= candidate.score { return }
        candidates[candidate.id] = candidate
    }

    // MARK: - Row shapes

    private struct Candidate: Sendable {
        let id: NoteID
        let title: String
        let relativePath: String
        let modified: Date
        let source: MatchSource
        let score: Double
    }

    /// Stage timings, printed when `FILAWAY_SEARCH_TRACE=1`. Off by default and
    /// free when off: the environment is read once per process.
    private struct Trace {
        static let isEnabled = ProcessInfo.processInfo.environment["FILAWAY_SEARCH_TRACE"] == "1"
        private var mark = Date()
        private var laps: [String] = []

        mutating func lap(_ name: String) {
            guard Self.isEnabled else { return }
            let now = Date()
            laps.append("\(name) \(String(format: "%.1f", now.timeIntervalSince(mark) * 1000))")
            mark = now
        }

        func finish(candidates: Int, results: Int) {
            guard Self.isEnabled else { return }
            FileHandle.standardError.write(
                Data("[search] \(laps.joined(separator: " ms, ")) ms — \(candidates) candidates, \(results) results\n".utf8)
            )
        }
    }

    private struct RecentRow: Sendable {
        let id: String
        let relpath: String
        let title: String
        let mtime: Double
    }

    private struct FTSRow: Sendable {
        let id: String
        let relpath: String
        let title: String
        let mtime: Double
        let rank: Double
    }

    /// A cached title's identity. Only rows that matched are ever touched, so
    /// this never appears in the scan's hot loop.
    private struct TitleEntry: Sendable {
        let id: NoteID
        let title: String
        let relativePath: String
        let modified: Date
    }

    /// Where one folded title sits in ``titleBytes``, plus its byte-class
    /// signature. Trivial, so the scan is pure arithmetic.
    private struct TitleSpan: Sendable {
        let start: Int
        let count: Int
        let signature: UInt64
    }
}
