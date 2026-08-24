import Foundation

/// Merge-target ranking through the semantic index (M3-08, FR-4.6).
///
/// The organizer asks "which existing notes might already cover this?" and gets
/// back a handful of ids. ``TitleOverlapCandidateFinder`` answers that from
/// titles and folder names alone, which is all M2 had; this answers it from the
/// same hybrid retrieval ⌘K uses, so a scratch note full of `kubectl` finds
/// `Commands/Kubernetes` even though the word "kubernetes" is nowhere in its
/// title.
///
/// ```swift
/// let finder = HybridCandidateFinder(hybrid: hybrid)
/// let organizer = Organizer(…, candidateFinder: finder)
/// ```
///
/// **It degrades to the title finder rather than to nothing.** An empty index
/// (first launch, a rebuild in flight, semantic search never enabled) would
/// otherwise mean the organizer sees no candidates at all and starts creating
/// near-duplicates — the exact sprawl FR-4.6 is against. So a run that comes
/// back empty falls through to ``fallback``, and the organizer cannot tell.
///
/// FR-4.5 holds twice over: the context it is handed has already been through
/// ``ExclusionFilter``, excluded folders are never indexed, and the search is
/// filtered again with the context's own exclusions.
public struct HybridCandidateFinder: CandidateFinder {

    private let hybrid: HybridSearch
    /// Used when the index has nothing to say.
    public let fallback: any CandidateFinder
    /// How much session text is embedded. The model runs at a fixed 256-token
    /// sequence (ADR-012), so more than a couple of paragraphs is wasted — and
    /// the *start* of a session note is what it is about.
    public let queryCharacterLimit: Int
    /// Candidates below this fused score are noise; RRF at k=60 puts a chunk
    /// found by one retriever alone at ~0.016, so this keeps roughly the top of
    /// each list.
    public let minimumScore: Double

    public init(
        hybrid: HybridSearch,
        fallback: any CandidateFinder = TitleOverlapCandidateFinder(),
        queryCharacterLimit: Int = 1_200,
        minimumScore: Double = 0.008
    ) {
        self.hybrid = hybrid
        self.fallback = fallback
        self.queryCharacterLimit = max(1, queryCharacterLimit)
        self.minimumScore = minimumScore
    }

    public func candidates(
        for query: CandidateQuery, in context: OrganizeContext
    ) async throws -> [OrganizeCandidate] {
        let limit = max(0, query.limit)
        guard limit > 0 else { return [] }

        let text = Self.queryText(query, limit: queryCharacterLimit)
        guard !text.isEmpty else { return [] }

        // Ask for more notes than we need: the session's own notes are in the
        // index too and have to come out afterwards.
        let options = HybridSearch.Options(
            noteLimit: limit + query.excluding.count + 4,
            exclusions: context.exclusionFilter
        )
        // The session text is a passage, not a question: no temporal parse, no
        // recency bias. "Two days ago" inside someone's notes is not a filter.
        let results = await hybrid.semanticCandidates(
            text, options: withoutTemporalBias(options)
        )
        try Task.checkCancellation()

        var out: [OrganizeCandidate] = []
        for note in results.notes {
            guard !query.excluding.contains(note.id) else { continue }
            // Only notes the organizer can actually name: the context has been
            // filtered, and a note the index still remembers but the snapshot
            // does not would decode to `.unknownNote`.
            guard context.note(id: note.id) != nil else { continue }
            guard note.score >= minimumScore else { continue }
            out.append(OrganizeCandidate(noteID: note.id, score: note.score))
            if out.count == limit { break }
        }

        guard out.isEmpty else { return out }
        return try await fallback.candidates(for: query, in: context)
    }

    /// The session text, plus its titles, capped.
    static func queryText(_ query: CandidateQuery, limit: Int) -> String {
        var parts: [String] = []
        let titles = query.titles.filter { !$0.isEmpty && $0 != PathRules.untitled }
        if !titles.isEmpty { parts.append(titles.joined(separator: " ")) }
        parts.append(query.text)
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(joined.prefix(limit))
    }

    private func withoutTemporalBias(_ options: HybridSearch.Options) -> HybridSearch.Options {
        var options = options
        options.recencyPrior = .none
        return options
    }
}
