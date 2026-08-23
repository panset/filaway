import Foundation

/// The production ``OrganizeLibrarySource``: the notes folder itself (M2-12).
///
/// It reads **disk**, not the derived database, and that is the whole point.
/// The organizer's snapshot is where `plan.preconditions` come from, and a
/// precondition is a compare-and-swap against the bytes ``PlanApplier`` will
/// check moments later. `MetadataStore` is updated asynchronously after every
/// save, so a snapshot taken from it can carry a content hash that is one
/// autosave behind — which would turn a perfectly good plan into a spurious
/// ``OrganizerEvent/stale(_:noteIDs:)``.
///
/// A full scan is ~400 ms at 5,000 notes (`docs/core-api.md`), and it happens
/// once per finished writing session, off the main actor. Consecutive scans
/// reuse the previous summaries, so the second one only re-hashes what moved.
///
/// ```swift
/// let source = OrganizeLibrarySourceLive(store: store)
/// let organizer = Organizer(provider: provider, source: source, …)
/// ```
public actor OrganizeLibrarySourceLive: OrganizeLibrarySource {
    private let store: NoteStore
    private let settleWindow: TimeInterval
    /// The last snapshot, both as the reuse map for the next scan and as the
    /// id → path index ``body(of:)`` needs.
    private var cached: LibrarySnapshot?

    /// - Parameters:
    ///   - store: the library.
    ///   - settleWindow: passed through to ``NoteStore/scan(reusing:settleWindow:)``.
    ///     Zero, because the tracker has already run the autosave flush and a
    ///     just-written note must not be skipped (`docs/organize.md`, the
    ///     ordering contract).
    public init(store: NoteStore, settleWindow: TimeInterval = 0) {
        self.store = store
        self.settleWindow = settleWindow
    }

    public func snapshot() async throws -> LibrarySnapshot {
        let reusing = cached.map { snapshot in
            Dictionary(snapshot.notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        let snapshot = try await store.scan(reusing: reusing, settleWindow: settleWindow)
        cached = snapshot
        return snapshot
    }

    public func body(of noteID: NoteID) async throws -> String? {
        if let path = path(of: noteID), await store.exists(path) {
            return try await store.read(path).body
        }
        // The cache is cold, or the note moved since the last scan.
        _ = try await snapshot()
        guard let path = path(of: noteID), await store.exists(path) else { return nil }
        return try await store.read(path).body
    }

    private func path(of noteID: NoteID) -> String? {
        cached?.notes.first { $0.id == noteID }?.relativePath
    }
}

// MARK: - Candidates from keyword search (FR-4.6)

/// Merge-target ranking that asks the FTS index what the session is about
/// (M2-12), on top of ``TitleOverlapCandidateFinder``'s title/folder/tag
/// overlap.
///
/// Title overlap alone cannot find `Commands/curl.md` from a session that
/// spells the word only inside a fenced block; keyword search can, because the
/// body is indexed. The two are **added**, not swapped:
///
/// * the overlap score is the base, so a note whose *title* names the subject
///   still wins — that is FR-4.6's convergence preference;
/// * keyword hits contribute ``keywordWeight`` × their normalised bm25 score,
///   which is enough to pull a body-only match into the list and never enough
///   to displace a title match.
///
/// With an empty or still-building index the finder degrades to exactly
/// ``TitleOverlapCandidateFinder``, which is the behaviour every golden fixture
/// was recorded against. M3-08 replaces the whole thing with the hybrid
/// keyword + embedding ranker; the seam is ``CandidateFinder``, unchanged.
public struct KeywordCandidateFinder: CandidateFinder {
    private let search: SearchService
    /// The base ranker. Its score is the dominant term.
    public var overlap: TitleOverlapCandidateFinder
    /// How much a perfect keyword hit is worth, in overlap-score units.
    public var keywordWeight: Double
    /// How many salient terms of the session text to search for.
    public var maxTerms: Int

    public init(
        search: SearchService,
        overlap: TitleOverlapCandidateFinder = TitleOverlapCandidateFinder(),
        keywordWeight: Double = 0.25,
        maxTerms: Int = 6
    ) {
        self.search = search
        self.overlap = overlap
        self.keywordWeight = keywordWeight
        self.maxTerms = maxTerms
    }

    public func candidates(for query: CandidateQuery, in context: OrganizeContext) async throws -> [OrganizeCandidate] {
        var scores: [NoteID: Double] = [:]
        for candidate in try await overlap.candidates(for: query.widened, in: context) {
            scores[candidate.noteID] = candidate.score
        }
        for term in Self.terms(in: query, limit: maxTerms) {
            // Eligibility first, *then* normalisation: if the session's own
            // note topped the list, letting it set the divisor would change
            // every other note's contribution — and the session note is never a
            // candidate anyway. The prompt has to be a pure function of the
            // library, or the replayed fixture stops matching.
            let hits = await search.keyword(term, limit: max(query.limit * 3, 12))
                .filter { !query.excluding.contains($0.id) && context.note(id: $0.id) != nil }
            guard let best = hits.map(\.score).max(), best > 0 else { continue }
            for hit in hits {
                let contribution = keywordWeight * (hit.score / best) / Double(maxTerms)
                scores[hit.id, default: 0] += contribution
            }
        }

        // Deterministic order: score, then path. Two runs over the same library
        // must produce the same prompt, or the replayed fixture stops matching.
        let ranked = scores.compactMap { id, score -> (OrganizeCandidate, String)? in
            guard let note = context.note(id: id) else { return nil }
            return (OrganizeCandidate(noteID: id, score: score), note.relativePath)
        }
        .sorted { left, right in
            if left.0.score != right.0.score { return left.0.score > right.0.score }
            return left.1 < right.1
        }
        return ranked.prefix(max(0, query.limit)).map(\.0)
    }

    /// The words worth asking the index about: the longest distinct non-stop
    /// words of the session text and its titles, longest first so `staging`
    /// beats `the`.
    static func terms(in query: CandidateQuery, limit: Int) -> [String] {
        let words = TitleOverlapCandidateFinder.words(in: query.text + "\n" + query.titles.joined(separator: "\n"))
        return words
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left < right
            }
            .prefix(limit)
            .map { $0 }
    }
}

private extension CandidateQuery {
    /// The overlap ranker is asked for more than the caller wants, so that a
    /// keyword-only hit can still displace a weak overlap match.
    var widened: CandidateQuery {
        var copy = self
        copy.limit = max(limit * 3, 12)
        return copy
    }
}
