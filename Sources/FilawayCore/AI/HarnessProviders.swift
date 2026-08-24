import Foundation

/// Serves recorded responses and never touches the network (M2-02).
///
/// A miss is a hard, *actionable* failure: the thrown
/// ``AIError/missingRecording(purpose:key:path:)`` names the exact file to
/// record, because the alternative — silently falling through to a live call —
/// would make CI depend on a key.
public struct ReplayProvider: AIProvider {
    public let identifier = "replay"
    public let store: AIRecordingStore
    /// Model list returned by ``validateKey()``; defaults to the known ids.
    public let models: [AIModelInfo]

    public init(store: AIRecordingStore, models: [AIModelInfo]? = nil) {
        self.store = store
        self.models = models ?? AIModel.known.map { AIModelInfo(id: $0.id, displayName: $0.id) }
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        guard let recording = try store.load(for: request) else {
            throw AIError.missingRecording(
                purpose: request.purpose,
                key: request.fixtureKey,
                path: store.url(for: request).path
            )
        }
        return try recording.response()
    }

    /// Replays the recorded key-validation fixture when one exists, else the
    /// static model list — so Settings and onboarding work offline.
    ///
    /// The fixture decodes through *its own* provider's model-list codec
    /// (ADR-067): an Anthropic `data` array and an Ollama `models` array are
    /// different shapes, and a v1 fixture is Claude by definition.
    public func validateKey() async throws -> [AIModelInfo] {
        if let recording = try store.load(purpose: .validate, key: ReplayProvider.validateKeyFixtureKey),
           let models = try? recording.models() {
            return models
        }
        return models
    }

    /// Fixture name for `GET /v1/models`, which has no request body to hash.
    public static let validateKeyFixtureKey = "models-list"
}

/// Wraps a real provider, writes every exchange to the fixture directory.
///
/// `FILAWAY_AI_MODE=record` is a manual job: it needs `ANTHROPIC_API_KEY` and it
/// costs money. The point is that the *shape* of what the tests replay is
/// produced by the real API, not by hand — hand-authored fixtures exist only
/// for the paths a key cannot conveniently produce (a refusal, an invalid plan).
public struct RecordingProvider: AIProvider {
    public let identifier = "recording"
    public let upstream: any AIProvider
    public let store: AIRecordingStore
    private let clock: any AIClock

    public init(upstream: any AIProvider, store: AIRecordingStore, clock: any AIClock = SystemClock()) {
        self.upstream = upstream
        self.store = store
        self.clock = clock
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let response = try await upstream.complete(request)
        let recording = AIRecording(
            request: request, response: response, provider: upstream.identifier, recordedAt: clock.now()
        )
        try store.save(recording)
        return response
    }

    public func validateKey() async throws -> [AIModelInfo] {
        let models = try await upstream.validateKey()
        let request = AIRequest(
            model: AIModel(""),
            purpose: .validate,
            messages: [],
            timeout: AIPurpose.validate.defaultTimeout
        )
        let wire = ProviderWire.named(upstream.identifier)
        try store.save(AIRecording(
            purpose: .validate,
            key: ReplayProvider.validateKeyFixtureKey,
            model: "",
            provider: upstream.identifier,
            recordedAt: clock.now(),
            note: "key validation — the provider's model list",
            request: request,
            requestBody: wire.validateRequestBody,
            responseBody: wire.modelsValue(for: models)
        ))
        return models
    }
}

/// A closure-backed provider for unit tests and UI previews.
///
/// ```swift
/// let provider = MockProvider { request in .text("nothing to do", model: request.model) }
/// ```
public struct MockProvider: AIProvider {
    public let identifier: String
    private let handler: @Sendable (AIRequest) async throws -> AIResponse
    private let validator: @Sendable () async throws -> [AIModelInfo]

    public init(
        identifier: String = "mock",
        models: [AIModelInfo]? = nil,
        handler: @escaping @Sendable (AIRequest) async throws -> AIResponse
    ) {
        self.identifier = identifier
        self.handler = handler
        let resolved = models ?? AIModel.known.map { AIModelInfo(id: $0.id, displayName: $0.id) }
        validator = { resolved }
    }

    public init(
        identifier: String = "mock",
        validator: @escaping @Sendable () async throws -> [AIModelInfo],
        handler: @escaping @Sendable (AIRequest) async throws -> AIResponse
    ) {
        self.identifier = identifier
        self.handler = handler
        self.validator = validator
    }

    /// Always fails with the same error — drives the FR-6.4 degradation paths.
    public static func failing(_ error: AIError) -> MockProvider {
        MockProvider(validator: { throw error }, handler: { _ in throw error })
    }

    /// Always answers with one text block.
    public static func echoing(_ text: String) -> MockProvider {
        MockProvider { request in .text(text, model: request.model) }
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        try await handler(request)
    }

    public func validateKey() async throws -> [AIModelInfo] {
        try await validator()
    }
}

public extension AIResponse {
    /// Convenience for mocks and hand-authored fixtures: a plain text answer.
    static func text(
        _ text: String,
        model: AIModel = .defaultOrganize,
        stopReason: AIStopReason = .endTurn,
        usage: AIUsage = AIUsage(inputTokens: 0, outputTokens: 0)
    ) -> AIResponse {
        AIResponse(
            id: "msg_mock",
            model: model.id,
            content: [.text(text)],
            stopReason: stopReason,
            usage: usage
        )
    }

    /// Convenience for mocks: a forced tool call.
    static func toolUse(
        name: String,
        input: JSONValue,
        model: AIModel = .defaultOrganize,
        usage: AIUsage = AIUsage(inputTokens: 0, outputTokens: 0)
    ) -> AIResponse {
        AIResponse(
            id: "msg_mock",
            model: model.id,
            content: [.toolUse(id: "toolu_mock", name: name, input: input)],
            stopReason: .toolUse,
            usage: usage
        )
    }
}

/// Builds the provider `FILAWAY_AI_MODE` asks for.
public enum AIProviderFactory {
    /// - Parameters:
    ///   - mode: usually ``AIMode/current(environment:)``.
    ///   - store: fixture directory; required for `replay` and `record`.
    ///   - keySource: credential for `record` and `live`; unused by `.ollama`.
    ///   - kind: which backend `live`/`record` talk to (FR-6.5). `replay` is
    ///     provider-agnostic — a fixture says which wire format it is in.
    ///   - ollama: where the local daemon is, when `kind` is `.ollama`.
    public static func make(
        mode: AIMode,
        store: AIRecordingStore?,
        keySource: APIKeySource,
        kind: AIProviderKind = .claude,
        ollama: OllamaConfiguration = OllamaConfiguration(),
        configuration: URLSessionConfiguration = ClaudeProvider.defaultConfiguration(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: any AIClock = SystemClock()
    ) throws -> any AIProvider {
        func upstream() -> any AIProvider {
            switch kind {
            case .claude:
                return ClaudeProvider(
                    keySource: keySource, configuration: configuration, retryPolicy: retryPolicy, clock: clock
                )
            case .ollama:
                return OllamaProvider(
                    configuration: ollama,
                    sessionConfiguration: configuration,
                    retryPolicy: retryPolicy,
                    clock: clock
                )
            }
        }

        switch mode {
        case .replay:
            guard let store else { throw AIError.malformedResponse("replay mode needs a fixture directory") }
            return ReplayProvider(store: store)
        case .live:
            return upstream()
        case .record:
            guard let store else { throw AIError.malformedResponse("record mode needs a fixture directory") }
            return RecordingProvider(upstream: upstream(), store: store, clock: clock)
        }
    }
}
