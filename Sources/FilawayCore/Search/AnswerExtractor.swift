import Foundation

/// Turns the retrieved chunks into Figure 2b's answer card (M3-05,
/// FR-5.2, NFR-1).
///
/// ```swift
/// let extractor = AnswerExtractor(provider: provider, ledger: ledger)
/// let answer = await extractor.extract(query: "curl command to fetch documents", results: results)
/// answer.card?.snippetText     // the command, verbatim
/// answer.source                // .model | .localHeuristic | .none
/// ```
///
/// Three properties hold no matter what happens:
///
/// * **It always returns, inside the budget.** `configuration.timeout` (5 s by
///   default) races the provider; a loss is a local answer, not an error.
/// * **It never invents a command.** A snippet the model reports is shown only
///   when it can be found verbatim in the chunk the model chose; otherwise the
///   chunk's own fenced body is shown instead.
/// * **It never leaves an excluded folder's text in a prompt.** That is
///   structural rather than checked here: excluded folders are not indexed at
///   all (FR-4.5), so nothing from one can reach `promptChunks`.
///
/// `extract` does not throw. Every failure — offline, rate limited, refused,
/// truncated, a hallucinated chunk number — lands on the same local fallback
/// and is reported through ``AnswerResult/unavailable``.
public actor AnswerExtractor {

    public struct Configuration: Sendable {
        /// `effectiveSearchModel`; the house default is Haiku 4.5 (plan §1).
        public var model: AIModel
        /// Which backend answers (FR-6.5, P2-03). It sets the *request's* own
        /// budget — ``timeout`` below is the race this actor runs regardless,
        /// and the local heuristic is what wins when the race is lost.
        public var providerKind: AIProviderKind
        public var promptVersion: PromptVersion
        /// A card is a few dozen tokens; 600 is room for a long snippet and a
        /// full ranking, and a hard stop on a model that decides to essay.
        public var maxTokens: Int
        /// NFR-1's answer budget. The provider's own timeout is a backstop;
        /// this one is enforced here so a replay or a mock cannot outrun it.
        public var timeout: TimeInterval
        /// Overrides the bundled prompt resources.
        public var promptsDirectory: URL?
        /// The offline arm.
        public var heuristic: AnswerHeuristic

        public init(
            model: AIModel = .defaultSearch,
            providerKind: AIProviderKind = .claude,
            promptVersion: PromptVersion = .answer,
            maxTokens: Int = 600,
            timeout: TimeInterval = 5,
            promptsDirectory: URL? = nil,
            heuristic: AnswerHeuristic = AnswerHeuristic()
        ) {
            self.model = model
            self.providerKind = providerKind
            self.promptVersion = promptVersion
            self.maxTokens = max(64, maxTokens)
            self.timeout = max(0.1, timeout)
            self.promptsDirectory = promptsDirectory
            self.heuristic = heuristic
        }
    }

    private let provider: any AIProvider
    private let ledger: AIUsageLedger?
    private var configuration: Configuration
    private let clock: any AIClock
    private let log = Log.make("search")

    public init(
        provider: any AIProvider,
        ledger: AIUsageLedger? = nil,
        configuration: Configuration = Configuration(),
        clock: any AIClock = SystemClock()
    ) {
        self.provider = provider
        self.ledger = ledger
        self.configuration = configuration
        self.clock = clock
    }

    /// Settings changed (`effectiveSearchModel`, FR-6.2).
    public func setModel(_ model: AIModel) { configuration.model = model }
    /// Settings changed provider (FR-6.5). Only the *budget* lives here; the
    /// provider object itself is `let`, so a kind change rebuilds the extractor.
    public func setProviderKind(_ kind: AIProviderKind) { configuration.providerKind = kind }
    public var providerKind: AIProviderKind { configuration.providerKind }
    public func setTimeout(_ timeout: TimeInterval) { configuration.timeout = max(0.1, timeout) }
    public var model: AIModel { configuration.model }
    public nonisolated var providerIdentifier: String { provider.identifier }

    // MARK: - The request

    /// The exact request `answer.v1` is asked with.
    ///
    /// Model, system, messages, tools and tool choice are the fixture key, so
    /// this is the whole surface a recording has to match.
    public func request(query: String, chunks: [RankedChunk]) throws -> AIRequest {
        try Self.request(query: query, chunks: chunks, configuration: configuration)
    }

    public static func request(
        query: String,
        chunks: [RankedChunk],
        configuration: Configuration = Configuration()
    ) throws -> AIRequest {
        let system = try PromptLibrary.text(configuration.promptVersion, in: configuration.promptsDirectory)
        let shown = Array(chunks.prefix(AnswerSelection.maxChunks))
        return AIRequest(
            model: configuration.model,
            purpose: .search,
            system: system,
            messages: [.user(AnswerPrompt.userMessage(query: query, chunks: shown))],
            tools: [AnswerSelection.tool],
            toolChoice: .tool(name: AnswerSelection.toolName),
            maxTokens: configuration.maxTokens,
            // Haiku 4.5 is on the pre-4.6 contract: no `thinking`, no
            // `output_config`. `ClaudeWire` drops them anyway; not sending them
            // keeps the recorded request body honest.
            thinking: configuration.model.supportsAdaptiveThinking ? .adaptive() : nil,
            effort: configuration.model.supportsEffort ? .low : nil,
            // The provider's own budget, not the race: ``complete`` enforces
            // ``Configuration/timeout`` here in the actor so a replay or a mock
            // cannot outrun NFR-1 either (ADR-069).
            timeout: configuration.providerKind.timeout(for: .search)
        )
    }

    // MARK: - Extraction

    /// The answer for a finished retrieval pass. Never throws.
    public func extract(
        query: String,
        results: SemanticResults,
        now: Date = Date()
    ) async -> AnswerResult {
        let chunks = results.promptChunks
        guard !chunks.isEmpty else {
            return AnswerResult(card: nil, rankedNotes: results.notes, source: .none)
        }

        let started = clock.now()
        let request: AIRequest
        do {
            request = try self.request(query: query, chunks: chunks)
        } catch {
            log.error("answer prompt unavailable: \(String(describing: error), privacy: .public)")
            return fallback(results: results, reason: .noProvider, since: started)
        }

        let response: AIResponse
        do {
            response = try await complete(request)
        } catch is CancellationError {
            return AnswerResult(card: nil, rankedNotes: results.notes, source: .none)
        } catch {
            let reason = Self.reason(for: error)
            if reason == nil { return AnswerResult(card: nil, rankedNotes: results.notes, source: .none) }
            log.info("answer step degraded to the local heuristic: \(reason?.rawValue ?? "?", privacy: .public)")
            return fallback(results: results, reason: reason ?? .providerError, since: started)
        }

        // The ledger is FR-6.6 and must not be able to fail a search.
        if let ledger {
            _ = try? await ledger.record(
                response: response, purpose: .search, provider: provider.identifier, at: now
            )
        }

        let decoded: AnswerSelection.Decoded
        do {
            decoded = try AnswerSelection.decode(response: response, chunkCount: chunks.count)
        } catch {
            log.error("answer_selection unusable: \(String(describing: error), privacy: .public)")
            return fallback(results: results, reason: .providerError, since: started)
        }

        return assemble(decoded, query: query, results: results, chunks: chunks, since: started)
    }

    /// The offline arm on its own — what the service calls when it knows the
    /// provider will not answer (semantic search off, no key, no provider).
    public nonisolated func localAnswer(
        query: String,
        results: SemanticResults,
        reason: SemanticUnavailable?,
        heuristic: AnswerHeuristic = AnswerHeuristic()
    ) -> AnswerResult {
        Self.localAnswer(query: query, results: results, reason: reason, heuristic: heuristic)
    }

    public static func localAnswer(
        query: String,
        results: SemanticResults,
        reason: SemanticUnavailable?,
        heuristic: AnswerHeuristic = AnswerHeuristic(),
        latency: TimeInterval = 0
    ) -> AnswerResult {
        let card = heuristic.card(query: query, chunks: results.promptChunks)
        return AnswerResult(
            card: card,
            rankedNotes: results.notes,
            source: card == nil ? .none : .localHeuristic,
            confidence: card == nil ? .low : .medium,
            latency: latency,
            unavailable: reason
        )
    }

    // MARK: - Internals

    private func fallback(
        results: SemanticResults,
        reason: SemanticUnavailable,
        since started: Date
    ) -> AnswerResult {
        Self.localAnswer(
            query: results.query,
            results: results,
            reason: reason,
            heuristic: configuration.heuristic,
            latency: clock.now().timeIntervalSince(started)
        )
    }

    /// Builds the card and the ranking out of a decoded tool call.
    private func assemble(
        _ decoded: AnswerSelection.Decoded,
        query: String,
        results: SemanticResults,
        chunks: [RankedChunk],
        since started: Date
    ) -> AnswerResult {
        let latency = clock.now().timeIntervalSince(started)
        var card: AnswerCard?
        if let index = decoded.bestChunk, chunks.indices.contains(index - 1) {
            let chunk = chunks[index - 1]
            card = AnswerHeuristic.card(
                for: chunk,
                snippet: snippet(reported: decoded.snippet, for: chunk)
            )
        }
        return AnswerResult(
            card: card,
            rankedNotes: Self.rank(results.notes, by: decoded.rankedChunks, chunks: chunks, card: card),
            source: card == nil ? .none : .model,
            confidence: card == nil ? .low : decoded.confidence,
            latency: latency,
            unavailable: nil,
            promptVersion: configuration.promptVersion,
            model: configuration.model
        )
    }

    /// "Never invent commands": a reported snippet is used only when it is
    /// really in the chunk. Anything else falls back to the chunk's own body.
    private func snippet(reported: String?, for chunk: RankedChunk) -> String {
        let derived = configuration.heuristic.snippet(for: chunk)
        guard let reported, !reported.isEmpty else { return derived }
        guard AnswerSnippet.isVerbatim(reported, in: chunk.text) else {
            log.error("answer snippet was not verbatim in its chunk; using the chunk body")
            return derived
        }
        return AnswerSnippet.limit(reported, lines: configuration.heuristic.maxSnippetLines)
    }

    /// Applies the model's ranking to the note list.
    ///
    /// The model ranks *chunks*; the panel lists *notes*. Notes are ordered by
    /// their best-ranked chunk, the card's note is dropped (it is already the
    /// card), and anything the model did not mention keeps its retrieval order
    /// at the end — a short ranking must not lose results.
    static func rank(
        _ notes: [RankedNote],
        by rankedChunks: [Int],
        chunks: [RankedChunk],
        card: AnswerCard?
    ) -> [RankedNote] {
        var order: [NoteID: Int] = [:]
        for (position, index) in rankedChunks.enumerated() {
            guard chunks.indices.contains(index - 1) else { continue }
            let noteID = chunks[index - 1].noteID
            if order[noteID] == nil { order[noteID] = position }
        }
        let remaining = card.map { card in notes.filter { $0.id != card.noteID } } ?? notes
        guard !order.isEmpty else { return remaining }
        return remaining.enumerated().sorted { left, right in
            let leftRank = order[left.element.id] ?? Int.max
            let rightRank = order[right.element.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Races the provider against the answer budget.
    private func complete(_ request: AIRequest) async throws -> AIResponse {
        let provider = self.provider
        let budget = configuration.timeout
        return try await withThrowingTaskGroup(of: AIResponse.self) { group in
            group.addTask { try await provider.complete(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                throw AIError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIError.timedOut }
            return first
        }
    }

    /// Maps a provider failure onto the notice the panel shows. `nil` means the
    /// search was cancelled and there is nothing to report.
    static func reason(for error: any Error) -> SemanticUnavailable? {
        guard let aiError = error as? AIError else { return .providerError }
        switch aiError {
        case .notConfigured, .invalidKey: return .notConfigured
        case .timedOut: return .timedOut
        case .rateLimited: return .rateLimited
        case .network: return .network
        case .cancelled: return nil
        case .missingRecording: return .noProvider
        case .badRequest, .modelNotFound, .serverOverloaded, .malformedResponse: return .providerError
        }
    }
}
