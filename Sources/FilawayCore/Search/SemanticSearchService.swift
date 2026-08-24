import Foundation

/// One semantic search, end to end (M3-05).
public struct SemanticSearchOutcome: Sendable, Equatable {
    /// The query as typed.
    public let query: String
    /// What was left after the time phrase came out (FR-5.3).
    public let strippedQuery: String
    /// The hard date filter that was applied, if any.
    public let dateRange: DateRange?
    /// Everything retrieval found, offline.
    public let results: SemanticResults
    /// The card and the ranking.
    public let answer: AnswerResult
    public let availability: SemanticAvailability
    /// Retrieval plus the answer step.
    public let latency: TimeInterval

    public init(
        query: String,
        strippedQuery: String,
        dateRange: DateRange?,
        results: SemanticResults,
        answer: AnswerResult,
        availability: SemanticAvailability,
        latency: TimeInterval
    ) {
        self.query = query
        self.strippedQuery = strippedQuery
        self.dateRange = dateRange
        self.results = results
        self.answer = answer
        self.availability = availability
        self.latency = latency
    }

    public var card: AnswerCard? { answer.card }
    public var notes: [RankedNote] { answer.rankedNotes }
    /// `true` when neither a card nor a note came back — the panel's
    /// "No good match".
    public var isEmpty: Bool { answer.card == nil && answer.rankedNotes.isEmpty }

    public static func empty(query: String, availability: SemanticAvailability = .online) -> SemanticSearchOutcome {
        SemanticSearchOutcome(
            query: query, strippedQuery: query, dateRange: nil,
            results: .empty(query: query), answer: .empty(),
            availability: availability, latency: 0
        )
    }
}

/// The one thing the ⌘K panel talks to for semantic search (M3-05/M3-06).
///
/// ```swift
/// let service = SemanticSearchService(hybrid: hybrid, extractor: extractor)
/// let outcome = await service.search("curl command to fetch documents")
/// outcome.card?.snippetText
/// ```
///
/// The pipeline is: temporal parse → ``HybridSearch/semanticCandidates(_:options:now:)``
/// → (if semantic search is enabled *and* a provider is ready) ``AnswerExtractor``
/// → otherwise the local heuristic. It never throws, always returns inside the
/// answer budget, and honours cancellation at both stages.
///
/// The panel wants the two halves separately — FR-5.2's list must be on screen
/// while Claude is still thinking — so ``candidates(_:now:)`` and
/// ``answer(for:results:now:)`` are public as well; ``search(_:now:)`` is the
/// two of them back to back for tests and for `filaway-bench`.
public actor SemanticSearchService {

    /// Whether the Claude step may run at all, evaluated per search so a
    /// Settings toggle or a key change takes effect without a restart.
    public struct Gate: Sendable {
        /// `CoreSettings.semanticSearchEnabled` (FR-8.1).
        public var isEnabled: @Sendable () -> Bool
        /// `AIStatus == .connected`, or whatever the harness says.
        public var isProviderReady: @Sendable () -> Bool

        public init(
            isEnabled: @escaping @Sendable () -> Bool = { true },
            isProviderReady: @escaping @Sendable () -> Bool = { true }
        ) {
            self.isEnabled = isEnabled
            self.isProviderReady = isProviderReady
        }

        public static let open = Gate()
    }

    private let hybrid: HybridSearch
    private let extractor: AnswerExtractor?
    private var options: HybridSearch.Options
    private var gate: Gate
    private var heuristic: AnswerHeuristic
    private let clock: any AIClock

    public init(
        hybrid: HybridSearch,
        extractor: AnswerExtractor?,
        options: HybridSearch.Options = HybridSearch.Options(),
        gate: Gate = .open,
        heuristic: AnswerHeuristic = AnswerHeuristic(),
        clock: any AIClock = SystemClock()
    ) {
        self.hybrid = hybrid
        self.extractor = extractor
        self.options = options
        self.gate = gate
        self.heuristic = heuristic
        self.clock = clock
    }

    /// FR-4.5: excluded folders are already absent from the index, but a folder
    /// excluded *after* it was indexed is purged asynchronously, so retrieval
    /// filters as well.
    public func setExclusions(_ filter: ExclusionFilter) { options.exclusions = filter }
    public func setOptions(_ options: HybridSearch.Options) { self.options = options }
    public func setGate(_ gate: Gate) { self.gate = gate }
    public var currentOptions: HybridSearch.Options { options }

    // MARK: - Stage one: retrieval (offline, always available)

    public func candidates(_ query: String, now: Date = Date()) async -> SemanticResults {
        await hybrid.semanticCandidates(query, options: options, now: now)
    }

    // MARK: - Stage two: the answer

    /// Runs the Claude step when it is allowed to run, the local heuristic
    /// otherwise. Reports which, and why.
    public func answer(
        for query: String,
        results: SemanticResults,
        now: Date = Date()
    ) async -> (answer: AnswerResult, availability: SemanticAvailability) {
        if let blocked = blockedReason() {
            let answer = AnswerExtractor.localAnswer(
                query: query, results: results, reason: blocked, heuristic: heuristic
            )
            return (answer, .offline(blocked))
        }
        guard let extractor else {
            let answer = AnswerExtractor.localAnswer(
                query: query, results: results, reason: .noProvider, heuristic: heuristic
            )
            return (answer, .offline(.noProvider))
        }
        let answer = await extractor.extract(query: query, results: results, now: now)
        if let reason = answer.unavailable { return (answer, .offline(reason)) }
        return (answer, .online)
    }

    // MARK: - Both, for tests and the bench

    public func search(_ query: String, now: Date = Date()) async -> SemanticSearchOutcome {
        let started = clock.now()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty(query: query, availability: blockedReason().map { .offline($0) } ?? .online)
        }
        let results = await candidates(query, now: now)
        guard !Task.isCancelled else { return .empty(query: query) }
        let (answer, availability) = await answer(for: query, results: results, now: now)
        return SemanticSearchOutcome(
            query: query,
            strippedQuery: results.strippedQuery,
            dateRange: results.dateRange,
            results: results,
            answer: answer,
            availability: availability,
            latency: clock.now().timeIntervalSince(started)
        )
    }

    private func blockedReason() -> SemanticUnavailable? {
        if !gate.isEnabled() { return .semanticSearchDisabled }
        if extractor == nil { return .noProvider }
        if !gate.isProviderReady() { return .notConfigured }
        return nil
    }
}
