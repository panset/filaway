import Foundation
import GRDB

/// One chunk in a semantic result list (FR-5.1, FR-5.2).
///
/// ``range`` is where the chunk sits in the note body, so opening the result
/// scrolls straight to it; ``text`` is the chunk as it was embedded, which is
/// exactly what M3-05 hands to `answer.v1`.
public struct RankedChunk: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let noteID: NoteID
    public let title: String
    public let relativePath: String
    public let modified: Date
    public let kind: ChunkKind
    public let headingPath: [String]
    public let range: MatchRange
    public let language: String?
    public let text: String
    /// Fused score: RRF over the two candidate lists, times the recency prior.
    public let score: Double
    /// 1-based position in the vector candidate list, or `nil` if it only came
    /// from FTS5.
    public let vectorRank: Int?
    /// Raw cosine, when the chunk came from the vector list.
    public let vectorScore: Float?
    /// 1-based position in the BM25 candidate list, or `nil`.
    public let keywordRank: Int?

    public var headingBreadcrumb: String { headingPath.joined(separator: " › ") }
    /// `true` when both retrievers found it — the strongest signal there is.
    public var isConsensus: Bool { vectorRank != nil && keywordRank != nil }
}

/// A note in a semantic result list, with the chunk that put it there.
public struct RankedNote: Sendable, Equatable, Identifiable {
    public let id: NoteID
    public let title: String
    public let relativePath: String
    public let modified: Date
    public let score: Double
    /// The strongest chunk of this note — what the result row previews and
    /// where FR-5.2's "open scrolled to the match" goes.
    public let bestChunk: RankedChunk
    /// How many of this note's chunks made the fused list.
    public let matchingChunks: Int
}

/// What ``HybridSearch/semanticCandidates(_:options:now:)`` returns.
///
/// Everything here is **offline** (plan §3 M3-03): no Claude, no network. M3-05
/// takes ``promptChunks`` and asks Haiku for the answer snippet; FR-5.5's
/// offline path renders ``notes`` and ``chunks`` as they stand.
public struct SemanticResults: Sendable, Equatable {
    /// The query as typed.
    public let query: String
    /// The query with any time phrase removed — what was actually embedded.
    public let strippedQuery: String
    /// The hard date filter that was applied, if any (FR-5.3).
    public let dateRange: DateRange?
    /// Best chunks, best first.
    public let chunks: [RankedChunk]
    /// Best notes, best first, one entry per note.
    public let notes: [RankedNote]
    /// `false` when the vector arm was unavailable (no model, or it failed):
    /// the results are then BM25-only and the UI must say so (FR-5.5, FR-6.4).
    public let usedVectors: Bool
    /// `false` when the query had nothing a word tokenizer could match.
    public let usedKeywords: Bool

    /// How many chunks the answer step is shown.
    ///
    /// Plan §3 M3-05 says eight. M3-07 measured what eight actually contains:
    /// on the development corpus the chunk holding the answer was inside the
    /// top eight only **65%** of the time, and inside the top twenty **94%**.
    /// The reason is structural — a short note splits into a prose chunk
    /// (written in the language of the *question*, so it ranks first) and a
    /// code chunk (which carries the command and shares almost no vocabulary
    /// with the question, so it ranks tenth) — and no amount of reranking
    /// inside eight chunks can recover a chunk that was never in them. Twenty
    /// chunks of ~150 tokens is still a small prompt (ADR-047).
    public static let promptChunkLimit = 20

    /// The chunks M3-05 feeds to `answer.v1` (plan §3 M3-05).
    public var promptChunks: [RankedChunk] { Array(chunks.prefix(Self.promptChunkLimit)) }

    public var isEmpty: Bool { chunks.isEmpty }

    public static func empty(query: String) -> SemanticResults {
        SemanticResults(
            query: query, strippedQuery: query, dateRange: nil,
            chunks: [], notes: [], usedVectors: false, usedKeywords: false
        )
    }
}

/// Offline hybrid retrieval: vectors ∪ BM25, fused with RRF, filtered or
/// biased by time, aggregated to notes (M3-03, FR-5.1/5.3).
///
/// ```swift
/// let hybrid = HybridSearch(metadata: metadata, embedder: embedder, vectorStore: vectors)
/// let results = await hybrid.semanticCandidates("the curl command from two days ago")
/// results.notes.first?.bestChunk.range     // scroll here
/// results.promptChunks                     // M3-05's prompt input
/// ```
///
/// **Why RRF rather than a weighted score sum.** A cosine in [-1, 1] and a
/// BM25 score in (-∞, 0] are not on the same scale and their distributions
/// change with every query; any fixed weighting is tuned to one corpus and
/// wrong on the next. Reciprocal rank fusion only reads the *positions*, so it
/// needs no normalisation and no per-corpus tuning, and a document both
/// retrievers rank highly beats one that either ranks first alone — which is
/// exactly the behaviour a hybrid index is for.
///
/// This type never touches Claude and never touches the network.
public actor HybridSearch {
    public struct Options: Sendable, Equatable {
        /// Chunks each retriever contributes before fusion (plan §3 M3-03: 50).
        public var candidateLimit: Int
        /// Chunks returned.
        public var chunkLimit: Int
        /// Notes returned.
        public var noteLimit: Int
        /// RRF's smoothing constant.
        ///
        /// The paper's 60 was tuned for TREC runs with thousands of documents
        /// per list; here each arm contributes fifty. At k = 60 the whole list
        /// spans `1/61 … 1/110` — under a 2× spread — so fusion degenerates
        /// into "how many arms found it" and rank barely matters. At k = 20 it
        /// spans `1/21 … 1/70`, and being first is worth something again.
        /// M3-07 measured the difference on the development corpus: note top-1
        /// 90% → 91%, answer-chunk top-1 84% → 90% (ADR-047).
        public var rrfK: Double
        /// Applied when no hard date range was parsed.
        public var recencyPrior: RecencyPrior
        /// FR-4.5: excluded folders never appear in results, so they can never
        /// be fed to a prompt by M3-05 either.
        public var exclusions: ExclusionFilter
        /// Restrict to one folder and its descendants.
        public var folderPath: String?
        /// Overrides whatever the temporal parser found.
        public var dateRange: DateRange?

        public init(
            candidateLimit: Int = 50,
            chunkLimit: Int = 20,
            noteLimit: Int = 10,
            rrfK: Double = 20,
            recencyPrior: RecencyPrior = .default,
            exclusions: ExclusionFilter = .none,
            folderPath: String? = nil,
            dateRange: DateRange? = nil
        ) {
            self.candidateLimit = max(1, candidateLimit)
            self.chunkLimit = max(1, chunkLimit)
            self.noteLimit = max(1, noteLimit)
            self.rrfK = max(1, rrfK)
            self.recencyPrior = recencyPrior
            self.exclusions = exclusions
            self.folderPath = folderPath
            self.dateRange = dateRange
        }
    }

    private let reader: any DatabaseReader
    private let embedder: (any Embedder)?
    private let vectors: VectorStore?
    private let parser: TemporalQueryParser
    private let log = Log.index

    /// Note identity, cached against `notes_generation` the way
    /// ``SearchService`` caches titles: the vector arm has to filter by
    /// modification date *before* the top-k cut, which means it needs every
    /// note's mtime in memory, not one query per candidate.
    private var noteMeta: [NoteID: NoteMeta] = [:]
    private var metaToken: String?

    public init(
        reader: any DatabaseReader,
        embedder: (any Embedder)?,
        vectorStore: VectorStore?,
        parser: TemporalQueryParser = TemporalQueryParser()
    ) {
        self.reader = reader
        self.embedder = embedder
        vectors = vectorStore
        self.parser = parser
    }

    public init(
        metadata: MetadataStore,
        embedder: (any Embedder)?,
        vectorStore: VectorStore?,
        parser: TemporalQueryParser = TemporalQueryParser()
    ) {
        self.init(
            reader: metadata.reader, embedder: embedder, vectorStore: vectorStore, parser: parser
        )
    }

    /// `true` when the vector arm can run at all (FR-5.5's banner).
    public nonisolated var supportsVectors: Bool { embedder != nil && vectors != nil }

    // MARK: - Search

    /// Ranked chunks and notes for a natural-language query.
    ///
    /// Never throws: a search that fails is an empty result and a log line, not
    /// an error sheet. Cancellation is honoured at every stage.
    public func semanticCandidates(
        _ query: String,
        options: Options = Options(),
        now: Date = Date()
    ) async -> SemanticResults {
        let temporal = parser.parse(query, now: now)
        let range = options.dateRange ?? temporal.range
        let text = temporal.strippedQuery.isEmpty ? query : temporal.strippedQuery
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty(query: query)
        }

        do {
            try await refreshNoteMetaIfNeeded()
            if Task.isCancelled { return .empty(query: query) }

            let gate = admissionFilter(options: options, range: range)

            // 1. Vector arm.
            var vectorHits: [VectorNeighbor] = []
            var usedVectors = false
            if let embedder, let vectors {
                do {
                    let vector = try await embedder.embedQuery(text)
                    vectorHits = try await vectors.topK(vector, k: options.candidateLimit, allow: gate)
                    usedVectors = true
                } catch is CancellationError {
                    return .empty(query: query)
                } catch {
                    // FR-5.5/FR-6.4: degrade to keyword-only rather than fail.
                    log.error("vector arm failed: \(String(describing: error), privacy: .public)")
                }
            }
            if Task.isCancelled { return .empty(query: query) }

            // 2. Keyword arm (FTS5 BM25 over the existing M1-06 tables).
            let keywordNotes = try await keywordCandidates(text, limit: options.candidateLimit, gate: gate)
            if Task.isCancelled { return .empty(query: query) }

            // 3. Hydrate both arms' chunks in one read.
            let vectorIDs = vectorHits.map(\.chunkID)
            let (byID, byNote) = try await reader.read { db in
                (
                    try ChunkRow.fetch(db, ids: vectorIDs),
                    try ChunkRow.fetch(db, noteIDs: keywordNotes.map(\.id))
                )
            }
            if Task.isCancelled { return .empty(query: query) }

            // A keyword hit is a *note*; the chunk it stands for is the one
            // that actually contains the query's words.
            let terms = SearchQuery(text).terms
            var keywordChunks: [IndexedChunk] = []
            for note in keywordNotes {
                guard let chunks = byNote[note.id], !chunks.isEmpty else { continue }
                keywordChunks.append(bestChunk(of: chunks, for: terms))
            }

            // 4. Fuse.
            let prior = range == nil ? priorFor(temporal, options: options) : .none
            let fused = fuse(
                vector: vectorHits,
                vectorChunks: byID,
                keyword: keywordChunks,
                options: options,
                prior: prior,
                now: now
            )

            let chunks = Array(fused.prefix(options.chunkLimit))
            return SemanticResults(
                query: query,
                strippedQuery: text,
                dateRange: range,
                chunks: chunks,
                notes: aggregate(fused, limit: options.noteLimit),
                usedVectors: usedVectors,
                usedKeywords: Self.orExpression(for: text) != nil
            )
        } catch is CancellationError {
            return .empty(query: query)
        } catch {
            log.error("semantic search failed: \(String(describing: error), privacy: .public)")
            return .empty(query: query)
        }
    }

    /// The soft prior: "recently" sharpens it, everything else gets the default.
    private func priorFor(_ temporal: TemporalQuery, options: Options) -> RecencyPrior {
        guard let window = temporal.boostWindow else { return options.recencyPrior }
        return .window(window)
    }

    // MARK: - Admission

    /// Whether a note may appear at all: exclusions, folder scope, and FR-5.3's
    /// hard date range. Applied *inside* the vector top-k so a date-restricted
    /// search cannot come back empty because newer chunks filled the list.
    ///
    /// The decision is made **once per note**, not once per chunk. The vector
    /// scan calls this for every resident row — 340,000 of them on a 20,000-note
    /// library — so anything that touches a string in here is a query-latency
    /// disaster: doing the path work per row cost 500 ms of a 580 ms query,
    /// against 80 ms for the same query without a date filter. Resolving the
    /// admitted set up front turns the hot path into one set lookup.
    private func admissionFilter(
        options: Options, range: DateRange?
    ) -> (@Sendable (NoteID) -> Bool)? {
        guard !options.exclusions.isEmpty || options.folderPath != nil || range != nil else {
            return nil
        }
        let exclusions = options.exclusions
        let folder = options.folderPath.map(PathRules.normalize)
        var admitted = Set<NoteID>(minimumCapacity: noteMeta.count)
        for (id, note) in noteMeta {
            if let range, !range.contains(note.modified) { continue }
            // A note lives *inside* a folder, so only the prefix form applies.
            if let folder, !folder.isEmpty, !note.relativePath.hasPrefix(folder + "/") { continue }
            if !exclusions.isEmpty, exclusions.isExcluded(path: note.relativePath) { continue }
            admitted.insert(id)
        }
        let resolved = admitted
        return { resolved.contains($0) }
    }

    // MARK: - Keyword arm

    private struct KeywordHitRow: Sendable {
        let id: NoteID
        let rank: Double
    }

    /// BM25 over `notes_fts`, the same index ⌘K uses (M1-06, ADR-018).
    ///
    /// The expression is an **OR** of the query's terms, not the `AND` that
    /// as-you-type keyword search builds: a natural-language question shares
    /// only a few words with the note that answers it, and requiring all of
    /// them would return nothing for every interesting query.
    private func keywordCandidates(
        _ text: String,
        limit: Int,
        gate: (@Sendable (NoteID) -> Bool)?
    ) async throws -> [KeywordHitRow] {
        guard let expression = Self.orExpression(for: text) else { return [] }
        // Over-fetch, because the gate rejects rows after ranking.
        let fetchLimit = gate == nil ? limit : limit * 4
        let rows: [KeywordHitRow] = try await reader.read { db in
            do {
                return try Row.fetchAll(db, sql: """
                    SELECT t.note_id AS note_id, top.rank AS rank
                    FROM (
                        SELECT rowid AS rid, rank FROM notes_fts
                        WHERE notes_fts MATCH ? ORDER BY rank LIMIT ?
                    ) top
                    JOIN note_text t ON t.rowid = top.rid
                    ORDER BY top.rank
                    """, arguments: [expression, fetchLimit])
                    .compactMap { row in
                        guard let id = NoteID(row["note_id"] as String) else { return nil }
                        return KeywordHitRow(id: id, rank: row["rank"] ?? 0)
                    }
            } catch {
                // A malformed MATCH is a query that finds nothing, never a
                // crash — same rule as ``SearchService``.
                return []
            }
        }
        guard let gate else { return Array(rows.prefix(limit)) }
        return Array(rows.filter { gate($0.id) }.prefix(limit))
    }

    /// `"curl" OR "documents" OR "fetch"` — stopwords dropped, terms capped.
    static func orExpression(for text: String) -> String? {
        var terms = SearchQuery(text).terms.filter { !stopwords.contains($0) && $0.count > 1 }
        if terms.isEmpty { terms = SearchQuery(text).terms }
        guard !terms.isEmpty else { return nil }
        // Longest first: the rarest words carry the most BM25 weight, and the
        // cap should keep them rather than the first ones typed.
        let kept = Array(Set(terms)).sorted { $0.count > $1.count }.prefix(12)
        return kept.map { SearchQuery.quote($0) }.joined(separator: " OR ")
    }

    /// Deliberately tiny. FTS5's BM25 already discounts common words; this list
    /// exists to stop the 12-term cap being spent on "the" and "a".
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "did", "do", "does", "for",
        "from", "had", "has", "have", "how", "i", "in", "into", "is", "it", "its", "me", "my",
        "of", "on", "or", "that", "the", "their", "then", "there", "this", "to", "was", "we",
        "what", "when", "where", "which", "who", "why", "will", "with", "you", "your",
    ]

    /// The chunk of a note that best explains a keyword hit.
    private func bestChunk(of chunks: [IndexedChunk], for terms: [String]) -> IndexedChunk {
        guard !terms.isEmpty else { return chunks[0] }
        var best = chunks[0]
        var bestScore = -1.0
        for chunk in chunks {
            let folded = SearchQuery.fold(chunk.text)
            var score = 0.0
            for term in terms where folded.contains(term) { score += 1 }
            // A tie goes to the earlier chunk, which is the note's opening.
            if score > bestScore {
                bestScore = score
                best = chunk
            }
        }
        return best
    }

    // MARK: - Fusion

    private func fuse(
        vector: [VectorNeighbor],
        vectorChunks: [Int64: IndexedChunk],
        keyword: [IndexedChunk],
        options: Options,
        prior: RecencyPrior,
        now: Date
    ) -> [RankedChunk] {
        struct Accumulator {
            var chunk: IndexedChunk
            var score = 0.0
            var vectorRank: Int?
            var vectorScore: Float?
            var keywordRank: Int?
        }

        var accumulators: [Int64: Accumulator] = [:]
        let k = options.rrfK

        for (index, hit) in vector.enumerated() {
            guard let chunk = vectorChunks[hit.chunkID] else { continue }
            var accumulator = accumulators[chunk.id] ?? Accumulator(chunk: chunk)
            accumulator.score += 1 / (k + Double(index + 1))
            accumulator.vectorRank = index + 1
            accumulator.vectorScore = hit.score
            accumulators[chunk.id] = accumulator
        }

        for (index, chunk) in keyword.enumerated() {
            var accumulator = accumulators[chunk.id] ?? Accumulator(chunk: chunk)
            accumulator.score += 1 / (k + Double(index + 1))
            accumulator.keywordRank = index + 1
            accumulators[chunk.id] = accumulator
        }

        return accumulators.values.compactMap { accumulator -> RankedChunk? in
            guard let note = noteMeta[accumulator.chunk.noteID] else { return nil }
            return RankedChunk(
                id: accumulator.chunk.id,
                noteID: accumulator.chunk.noteID,
                title: note.title,
                relativePath: note.relativePath,
                modified: note.modified,
                kind: accumulator.chunk.kind,
                headingPath: accumulator.chunk.headingPath,
                range: accumulator.chunk.range,
                language: accumulator.chunk.language,
                text: accumulator.chunk.text,
                score: accumulator.score * prior.multiplier(for: note.modified, now: now),
                vectorRank: accumulator.vectorRank,
                vectorScore: accumulator.vectorScore,
                keywordRank: accumulator.keywordRank
            )
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.modified != right.modified { return left.modified > right.modified }
            return left.id < right.id
        }
    }

    /// Best chunk per note, with a small bonus for a note several of whose
    /// chunks survived fusion — three matching sections is better evidence than
    /// one, but never enough to overturn a clearly better single answer.
    private func aggregate(_ chunks: [RankedChunk], limit: Int) -> [RankedNote] {
        var best: [NoteID: (chunk: RankedChunk, count: Int, total: Double)] = [:]
        for chunk in chunks {
            if var existing = best[chunk.noteID] {
                existing.count += 1
                existing.total += chunk.score
                if chunk.score > existing.chunk.score { existing.chunk = chunk }
                best[chunk.noteID] = existing
            } else {
                best[chunk.noteID] = (chunk, 1, chunk.score)
            }
        }
        return best.values
            .map { entry in
                RankedNote(
                    id: entry.chunk.noteID,
                    title: entry.chunk.title,
                    relativePath: entry.chunk.relativePath,
                    modified: entry.chunk.modified,
                    score: entry.chunk.score * (1 + 0.08 * Double(min(3, entry.count - 1))),
                    bestChunk: entry.chunk,
                    matchingChunks: entry.count
                )
            }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.modified != right.modified { return left.modified > right.modified }
                return left.relativePath < right.relativePath
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Note cache

    struct NoteMeta: Sendable, Equatable {
        let title: String
        let relativePath: String
        let modified: Date
    }

    /// Drops the note cache. The next search rebuilds it.
    public func invalidate() {
        noteMeta = [:]
        metaToken = nil
    }

    private func refreshNoteMetaIfNeeded() async throws {
        let token: String = try await reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'notes_generation'") ?? "0"
        }
        guard token != metaToken else { return }
        noteMeta = try await reader.read { db in
            var out: [NoteID: NoteMeta] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, relpath, title, mtime FROM notes") {
                guard let id = NoteID(row["id"] as String) else { continue }
                out[id] = NoteMeta(
                    title: row["title"],
                    relativePath: row["relpath"],
                    modified: Date(timeIntervalSince1970: row["mtime"])
                )
            }
            return out
        }
        metaToken = token
    }
}
