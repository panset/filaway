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
    public func validateKey() async throws -> [AIModelInfo] {
        if let recording = try store.load(purpose: .validate, key: ReplayProvider.validateKeyFixtureKey),
           let value = try? JSONValue.parse(recording.responseBody.canonicalData()),
           let models = try? ClaudeWire.models(from: value) {
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
        let recording = AIRecording(request: request, response: response, recordedAt: clock.now())
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
        let body = JSONValue.object([
            "data": .array(models.map { model in
                var object: [String: JSONValue] = [
                    "type": "model",
                    "id": .string(model.id),
                    "display_name": .string(model.displayName),
                ]
                if let created = model.createdAt { object["created_at"] = .string(ISO8601.string(from: created)) }
                if let tokens = model.maxInputTokens { object["max_input_tokens"] = .integer(tokens) }
                if let tokens = model.maxOutputTokens { object["max_tokens"] = .integer(tokens) }
                return .object(object)
            }),
            "has_more": .bool(false),
        ])
        try store.save(AIRecording(
            purpose: .validate,
            key: ReplayProvider.validateKeyFixtureKey,
            model: "",
            recordedAt: clock.now(),
            note: "GET /v1/models",
            request: request,
            requestBody: .object(["method": "GET", "path": "/v1/models?limit=100"]),
            responseBody: body
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
    ///   - keySource: credential for `record` and `live`.
    public static func make(
        mode: AIMode,
        store: AIRecordingStore?,
        keySource: APIKeySource,
        configuration: URLSessionConfiguration = ClaudeProvider.defaultConfiguration(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: any AIClock = SystemClock()
    ) throws -> any AIProvider {
        switch mode {
        case .replay:
            guard let store else { throw AIError.malformedResponse("replay mode needs a fixture directory") }
            return ReplayProvider(store: store)
        case .live:
            return ClaudeProvider(
                keySource: keySource, configuration: configuration, retryPolicy: retryPolicy, clock: clock
            )
        case .record:
            guard let store else { throw AIError.malformedResponse("record mode needs a fixture directory") }
            let upstream = ClaudeProvider(
                keySource: keySource, configuration: configuration, retryPolicy: retryPolicy, clock: clock
            )
            return RecordingProvider(upstream: upstream, store: store, clock: clock)
        }
    }
}
