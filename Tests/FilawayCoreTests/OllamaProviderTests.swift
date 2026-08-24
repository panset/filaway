import Foundation
import Testing

@testable import FilawayCore

// MARK: - Shared request shapes

/// Every stub in this file is installed for the daemon's host only, so this
/// suite and the Claude transport suite can run in parallel without seeing each
/// other's requests.
private let localhost = "localhost"

private enum OllamaSamples {
    static let schema = JSONValue.object([
        "type": "object",
        "properties": .object([
            "chunk_index": .object(["type": .array(["integer", "null"])]),
            "snippet": .object(["type": "string"]),
        ]),
        "required": .array(["chunk_index", "snippet"]),
        "additionalProperties": .bool(false),
    ])

    static let tool = AITool(
        name: "answer_selection",
        description: "Report the chunk that answers the question.",
        inputSchema: schema
    )

    static func forcedRequest(
        model: AIModel = .defaultOllama,
        system: String? = "You pick the best chunk.",
        purpose: AIPurpose = .search
    ) -> AIRequest {
        AIRequest(
            model: model,
            purpose: purpose,
            system: system,
            messages: [.user("Where is the curl token header?")],
            tools: [tool],
            toolChoice: .tool(name: tool.name),
            maxTokens: 1024,
            thinking: .adaptive(),
            effort: .medium,
            timeout: AIProviderKind.ollama.timeout(for: purpose)
        )
    }

    /// What the daemon answers a forced-tool request with.
    static func chatReply(
        content: String = #"{"chunk_index": 1, "snippet": "curl -H \"Auth: Bearer $TOK\""}"#,
        doneReason: String = "stop",
        model: String = "llama3.1:8b"
    ) -> JSONValue {
        .object([
            "model": .string(model),
            "created_at": "2026-08-24T02:18:37.883424Z",
            "message": .object(["role": "assistant", "content": .string(content)]),
            "done": .bool(true),
            "done_reason": .string(doneReason),
            "total_duration": .integer(1_500_000_000),
            "prompt_eval_count": .integer(62),
            "eval_count": .integer(19),
        ])
    }
}

// MARK: - Request encoding

@Suite("Ollama request encoding")
struct OllamaRequestEncodingTests {
    @Test("a forced tool becomes the format schema, and nothing Anthropic goes out")
    func forcedToolShape() throws {
        let request = OllamaSamples.forcedRequest()
        let object = try #require(OllamaWire.body(for: request).objectValue)

        #expect(object["model"] == .string("llama3.1:8b"))
        #expect(object["stream"] == .bool(false))
        #expect(object["format"] == OllamaSamples.schema, "the forced tool's schema *is* the grammar")
        #expect(object["options"] == .object(["temperature": .integer(0), "num_predict": .integer(1024)]))
        #expect(object["keep_alive"] == .string("30m"))

        // The system message carries the request's own prompt plus the tool's
        // description — appended at wire time only.
        let messages = try #require(object["messages"]?.arrayValue)
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == .string("system"))
        let system = try #require(messages[0]["content"]?.stringValue)
        #expect(system.hasPrefix("You pick the best chunk."))
        #expect(system.contains("answer_selection"))
        #expect(system.contains("Report the chunk that answers the question."))
        #expect(system.contains("No prose"))
        #expect(messages[1] == .object(["role": "user", "content": "Where is the curl token header?"]))

        // Ollama has none of these, and sending them is a 400 waiting to happen.
        #expect(object["tool_choice"] == nil)
        #expect(object["tools"] == nil, "a forced tool is a format schema, not a tool")
        #expect(object["thinking"] == nil)
        #expect(object["output_config"] == nil)
        #expect(object["max_tokens"] == nil)
        #expect(object.keys.sorted() == ["format", "keep_alive", "messages", "model", "options", "stream"])
    }

    @Test("no system text and no tool means no system message")
    func noSystem() throws {
        let request = AIRequest(model: .defaultOllama, purpose: .search, messages: [.user("hi")])
        let object = try #require(OllamaWire.body(for: request).objectValue)
        let messages = try #require(object["messages"]?.arrayValue)
        #expect(messages == [.object(["role": "user", "content": "hi"])])
        #expect(object["format"] == nil)
        #expect(object["tools"] == nil)
    }

    @Test("a forced tool with no system prompt still gets its instructions")
    func toolInstructionsWithoutSystem() throws {
        let request = OllamaSamples.forcedRequest(system: nil)
        let object = try #require(OllamaWire.body(for: request).objectValue)
        let messages = try #require(object["messages"]?.arrayValue)
        #expect(messages[0]["role"] == .string("system"))
        #expect(messages[0]["content"] == .string(OllamaWire.instructions(for: OllamaSamples.tool)))
    }

    @Test("unforced tools go out in Ollama's own function shape, with no format")
    func unforcedTools() throws {
        var request = OllamaSamples.forcedRequest()
        request.toolChoice = .auto
        let object = try #require(OllamaWire.body(for: request).objectValue)
        #expect(object["format"] == nil)
        #expect(object["tool_choice"] == nil)
        #expect(object["tools"] == .array([.object([
            "type": "function",
            "function": .object([
                "name": "answer_selection",
                "description": "Report the chunk that answers the question.",
                "parameters": OllamaSamples.schema,
            ]),
        ])]))
        // …and the system message is then the request's own text alone.
        #expect(object["messages"]?[0]?["content"] == .string("You pick the best chunk."))
    }

    @Test("the fixture key is the same request whichever provider serves it")
    func fixtureKeyIsProviderIndependent() {
        let request = OllamaSamples.forcedRequest()
        let key = request.fixtureKey
        _ = OllamaWire.body(for: request)
        _ = ClaudeWire.body(for: request)
        #expect(request.fixtureKey == key, "wire-time additions must not touch what was asked")

        var claude = request
        claude.model = .haiku45
        #expect(claude.fixtureKey != key, "…but the model still is part of it")
    }

    @Test("forcedTool finds the tool the choice names, and only then")
    func forcedTool() {
        let request = OllamaSamples.forcedRequest()
        #expect(request.forcedToolName == "answer_selection")
        #expect(request.forcedTool?.name == "answer_selection")

        var auto = request
        auto.toolChoice = .auto
        #expect(auto.forcedToolName == nil)
        #expect(auto.forcedTool == nil)

        var missing = request
        missing.tools = []
        #expect(missing.forcedToolName == "answer_selection")
        #expect(missing.forcedTool == nil, "a name with no definition cannot become a schema")
    }
}

// MARK: - Response decoding

@Suite("Ollama response decoding")
struct OllamaResponseDecodingTests {
    @Test("the format content becomes the tool-use block the callers already read")
    func synthesisedToolUse() throws {
        let request = OllamaSamples.forcedRequest()
        let response = try OllamaWire.response(from: OllamaSamples.chatReply(), for: request, requestID: nil)

        #expect(response.stopReason == .toolUse)
        #expect(response.model == "llama3.1:8b")
        #expect(response.id == "ollama-2026-08-24T02:18:37.883424Z")
        #expect(response.usage.inputTokens == 62)
        #expect(response.usage.outputTokens == 19)
        #expect(response.usage.cacheReadInputTokens == 0)
        #expect(response.usage.cacheCreationInputTokens == 0)

        let call = try #require(response.toolUse(named: "answer_selection"))
        #expect(call.id == "ollama-1")
        #expect(call.input["chunk_index"] == .integer(1))
        #expect(call.input["snippet"] == .string(#"curl -H "Auth: Bearer $TOK""#))
        #expect(response.content.count == 1)
    }

    @Test("done_reason length is a truncation, and is never parsed as a plan")
    func truncated() throws {
        let request = OllamaSamples.forcedRequest()
        let reply = OllamaSamples.chatReply(content: #"{"chunk_index": 1, "snip"#, doneReason: "length")
        let response = try OllamaWire.response(from: reply, for: request)
        #expect(response.stopReason == .maxTokens)
        #expect(response.isTruncated)
        #expect(response.toolUse() == nil, "half a JSON object is not a tool call")
    }

    @Test("content that is not JSON, with a schema forced, is malformedResponse")
    func malformedForcedContent() throws {
        let request = OllamaSamples.forcedRequest()
        for content in ["Sure! Here is the answer.", "```json\n{\"a\":1}\n```", "", "[1,2,3]"] {
            #expect(throws: AIError.self) {
                try OllamaWire.response(from: OllamaSamples.chatReply(content: content), for: request)
            }
        }
    }

    @Test("with no tool forced the content is text")
    func plainText() throws {
        let request = AIRequest(model: .defaultOllama, purpose: .search, messages: [.user("hi")])
        let response = try OllamaWire.response(from: OllamaSamples.chatReply(content: "hello"), for: request)
        #expect(response.text == "hello")
        #expect(response.stopReason == .endTurn)
        #expect(response.stopReason.isUsable)
    }

    @Test("Ollama-native tool_calls decode into tool-use blocks")
    func nativeToolCalls() throws {
        var request = OllamaSamples.forcedRequest()
        request.toolChoice = .auto
        let reply = JSONValue.object([
            "model": "llama3.1:8b",
            "message": .object([
                "role": "assistant",
                "content": "",
                "tool_calls": .array([.object([
                    "function": .object([
                        "name": "answer_selection",
                        "arguments": .object(["chunk_index": .integer(2), "snippet": "x"]),
                    ]),
                ])]),
            ]),
            "done": .bool(true),
            "done_reason": "stop",
            "prompt_eval_count": .integer(5),
            "eval_count": .integer(6),
        ])
        let response = try OllamaWire.response(from: reply, for: request)
        #expect(response.stopReason == .toolUse)
        let call = try #require(response.toolUse(named: "answer_selection"))
        #expect(call.id == "ollama-1")
        #expect(call.input["chunk_index"] == .integer(2))
    }

    @Test("the error envelope is an AIError, not a decode crash")
    func errorEnvelope() throws {
        let value = JSONValue.object(["error": "model \"nope\" not found, try pulling it first"])
        #expect(throws: AIError.badRequest(message: "model \"nope\" not found, try pulling it first")) {
            try OllamaWire.response(from: value, forcedToolName: nil)
        }
        #expect(OllamaWire.errorMessage(from: Data(#"{"error":"boom"}"#.utf8)) == "boom")
        #expect(OllamaWire.errorMessage(from: Data(#"{"error":{"message":"proxied"}}"#.utf8)) == "proxied")
        #expect(OllamaWire.errorMessage(from: Data("not json".utf8)) == nil)
    }

    @Test("missing required fields are malformedResponse")
    func malformedShapes() throws {
        for body in [
            #"{"message":{"role":"assistant","content":"hi"},"done":true}"#,  // no model
            #"{"model":"m","done":true}"#,                                     // no message
            "[]",
        ] {
            let value = try JSONValue.parse(body)
            #expect(throws: AIError.self) { try OllamaWire.response(from: value) }
        }
    }

    @Test("a response round-trips through the wire form")
    func roundTrip() throws {
        let request = OllamaSamples.forcedRequest()
        let original = try OllamaWire.response(from: OllamaSamples.chatReply(), for: request)
        let decoded = try OllamaWire.response(from: OllamaWire.value(for: original), for: request)
        #expect(decoded == original, "a recorded exchange must replay byte for byte")

        let text = AIResponse.text("plain", model: .defaultOllama)
        let plainRequest = AIRequest(model: .defaultOllama, purpose: .search, messages: [.user("hi")])
        let decodedText = try OllamaWire.response(from: OllamaWire.value(for: text), for: plainRequest)
        #expect(decodedText.text == "plain")
        #expect(decodedText.stopReason == .endTurn)
    }

    @Test("the tag list decodes into models")
    func tagList() throws {
        let value = try JSONValue.parse("""
        {"models":[{"name":"llama3.1:8b","model":"llama3.1:8b",
                    "modified_at":"2026-08-23T15:15:52.795641378-07:00","size":4920753328,
                    "details":{"family":"llama","parameter_size":"8.0B"}},
                   {"name":"qwen3:4b","model":"qwen3:4b"}]}
        """)
        let models = try OllamaWire.models(from: value)
        #expect(models.map(\.id) == ["llama3.1:8b", "qwen3:4b"])
        #expect(models[0].displayName == "llama3.1:8b")
        #expect(models[0].supportsAdaptiveThinking == false)
        #expect(models[0].createdAt == ISO8601.date(from: "2026-08-23T22:15:52Z"))
        #expect(models[1].createdAt == nil)
        #expect(throws: AIError.self) { try OllamaWire.models(from: .object(["data": .array([])])) }
    }
}

// MARK: - Configuration and kind

@Suite("Ollama configuration and provider kind")
struct OllamaConfigurationTests {
    @Test("http is loopback-only; anything else must be TLS")
    func loopbackRule() throws {
        for allowed in [
            "http://localhost:11434",
            "http://127.0.0.1:11434",
            "http://[::1]:11434",
            "http://LOCALHOST:11434",
            "https://ollama.example.test",
        ] {
            #expect(OllamaConfiguration.isValidBaseURL(URL(string: allowed)!), "\(allowed) should be allowed")
        }
        for rejected in [
            "http://ollama.example.test",
            "http://192.168.1.10:11434",
            "http://notlocalhost",
            "ftp://localhost",
            "file:///tmp",
        ] {
            #expect(!OllamaConfiguration.isValidBaseURL(URL(string: rejected)!), "\(rejected) should be rejected")
        }

        #expect(OllamaConfiguration().validate())
        #expect(OllamaConfiguration(baseURL: URL(string: "http://elsewhere.test")!).validate() == false)
        #expect(OllamaConfiguration().baseURL == URL(string: "http://localhost:11434")!)
        #expect(OllamaConfiguration().model == AIModel("llama3.1:8b"))
        #expect(AIModel.defaultOllama == OllamaConfiguration.defaultModel)
    }

    @Test("FILAWAY_AI_PROVIDER is read case-insensitively, and never guesses")
    func environment() {
        #expect(AIProviderKind.fromEnvironment([:]) == nil)
        #expect(AIProviderKind.fromEnvironment(["FILAWAY_AI_PROVIDER": "ollama"]) == .ollama)
        #expect(AIProviderKind.fromEnvironment(["FILAWAY_AI_PROVIDER": "OLLAMA"]) == .ollama)
        #expect(AIProviderKind.fromEnvironment(["FILAWAY_AI_PROVIDER": " Claude "]) == .claude)
        #expect(AIProviderKind.fromEnvironment(["FILAWAY_AI_PROVIDER": "gpt"]) == nil)
        #expect(AIProviderKind.fromEnvironment(["FILAWAY_AI_PROVIDER": ""]) == nil)
    }

    @Test("each kind carries its own budgets and credential rule")
    func kindProperties() {
        #expect(AIProviderKind.allCases == [.claude, .ollama])
        #expect(AIProviderKind.claude.requiresAPIKey)
        #expect(AIProviderKind.ollama.requiresAPIKey == false)
        #expect(AIProviderKind.claude.displayName == "Claude")
        #expect(AIProviderKind.ollama.displayName.contains("Ollama"))

        for purpose in AIPurpose.allCases {
            #expect(AIProviderKind.claude.timeout(for: purpose) == purpose.defaultTimeout)
        }
        #expect(AIProviderKind.ollama.timeout(for: .organize) == 180)
        #expect(AIProviderKind.ollama.timeout(for: .search) == 8)
        #expect(AIProviderKind.ollama.timeout(for: .validate) == 15)
    }
}

// MARK: - Transport

@Suite("OllamaProvider over a stubbed transport", .serialized)
struct OllamaProviderTransportTests {
    private func provider(clock: TestClock = TestClock(), retry: RetryPolicy = .none) -> OllamaProvider {
        OllamaProvider(
            configuration: OllamaConfiguration(),
            sessionConfiguration: StubURLProtocol.configuration(),
            retryPolicy: retry,
            clock: clock
        )
    }

    @Test("a successful call POSTs /api/chat with no credential at all")
    func chat() async throws {
        StubURLProtocol.always(host: localhost, .reply(.json(OllamaSamples.chatReply())))
        defer { StubURLProtocol.reset(host: localhost) }

        let response = try await provider().complete(OllamaSamples.forcedRequest())
        #expect(response.toolUse(named: "answer_selection") != nil)

        let sent = try #require(StubURLProtocol.requests(host: localhost).last)
        #expect(sent.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(sent.method == "POST")
        #expect(sent.headers["content-type"] == "application/json")
        #expect(sent.headers["x-api-key"] == nil, "a local model needs no key")
        #expect(sent.headers["authorization"] == nil)
        #expect(sent.json?["format"] == OllamaSamples.schema)
        #expect(sent.json?["stream"] == .bool(false))
    }

    @Test("the provider identifier is the kind's raw value")
    func identifier() {
        #expect(provider().identifier == "ollama")
        #expect(provider().identifier == AIProviderKind.ollama.rawValue)
        #expect(provider().baseURL == OllamaConfiguration.defaultBaseURL)
    }

    @Test("404 from a model that was never pulled is modelNotFound")
    func modelNotFound() async throws {
        StubURLProtocol.always(host: localhost, .reply(.json(
            .object(["error": "model \"nope\" not found, try pulling it first"]), status: 404
        )))
        defer { StubURLProtocol.reset(host: localhost) }

        var request = OllamaSamples.forcedRequest()
        request.model = AIModel("nope")
        await #expect(throws: AIError.modelNotFound(
            model: "nope", message: "model \"nope\" not found, try pulling it first"
        )) {
            try await provider().complete(request)
        }
        #expect(StubURLProtocol.requests(host: localhost).count == 1, "a 4xx must not be retried")
    }

    @Test("400 carries the daemon's message")
    func badRequest() async throws {
        StubURLProtocol.always(host: localhost, .reply(.json(.object(["error": "invalid format schema"]), status: 400)))
        defer { StubURLProtocol.reset(host: localhost) }
        await #expect(throws: AIError.badRequest(message: "invalid format schema")) {
            try await provider().complete(OllamaSamples.forcedRequest())
        }
    }

    @Test("a daemon that is not running is .network, and is retried")
    func connectionRefused() async throws {
        StubURLProtocol.sequence(host: localhost, [
            .failure(URLError(.cannotConnectToHost)),
            .reply(.json(OllamaSamples.chatReply())),
        ])
        defer { StubURLProtocol.reset(host: localhost) }

        let clock = TestClock(randomFraction: 1)
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, multiplier: 2, jitter: 0.5)
        let response = try await provider(clock: clock, retry: policy).complete(OllamaSamples.forcedRequest())
        #expect(response.stopReason == .toolUse)
        #expect(clock.recordedSleeps == [0.5])
        #expect(StubURLProtocol.requests(host: localhost).count == 2)
    }

    @Test("a daemon that stays down exhausts the policy and surfaces .network")
    func connectionRefusedExhausted() async throws {
        StubURLProtocol.always(host: localhost, .failure(URLError(.cannotConnectToHost)))
        defer { StubURLProtocol.reset(host: localhost) }

        let clock = TestClock(randomFraction: 1)
        do {
            _ = try await provider(clock: clock, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0.5))
                .complete(OllamaSamples.forcedRequest())
            Issue.record("expected a network failure")
        } catch let error as AIError {
            guard case .network = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(error.isRetryable)
        }
        #expect(StubURLProtocol.requests(host: localhost).count == 3)
        #expect(clock.recordedSleeps == [0.5, 1.0])
    }

    @Test("a slow model that overruns the budget is .timedOut")
    func timeout() async throws {
        StubURLProtocol.always(host: localhost, .failure(URLError(.timedOut)))
        defer { StubURLProtocol.reset(host: localhost) }
        await #expect(throws: AIError.timedOut) {
            try await provider().complete(OllamaSamples.forcedRequest())
        }
    }

    @Test("a body that is not JSON is malformedResponse")
    func malformedBody() async throws {
        StubURLProtocol.always(host: localhost, .reply(.init(status: 200, body: Data("<html>ollama</html>".utf8))))
        defer { StubURLProtocol.reset(host: localhost) }
        await #expect(throws: AIError.self) { try await provider().complete(OllamaSamples.forcedRequest()) }
        #expect(StubURLProtocol.requests(host: localhost).count == 1, "a decode failure is not retryable")
    }

    @Test("validateKey lists what has been pulled, over GET /api/tags")
    func validateKey() async throws {
        StubURLProtocol.always(host: localhost, .reply(.json(.object([
            "models": .array([.object([
                "name": "llama3.1:8b",
                "model": "llama3.1:8b",
                "modified_at": "2026-08-23T22:15:52Z",
            ])]),
        ]))))
        defer { StubURLProtocol.reset(host: localhost) }

        let models = try await provider().validateKey()
        #expect(models.map(\.id) == ["llama3.1:8b"])
        #expect(models[0].supportsAdaptiveThinking == false)

        let sent = try #require(StubURLProtocol.requests(host: localhost).last)
        #expect(sent.method == "GET")
        #expect(sent.url?.path == "/api/tags")
        #expect(sent.body?.isEmpty ?? true)
    }

    @Test("validateKey against a dead daemon is a network error, not an invalid key")
    func validateKeyOffline() async throws {
        StubURLProtocol.always(host: localhost, .failure(URLError(.cannotConnectToHost)))
        defer { StubURLProtocol.reset(host: localhost) }
        do {
            _ = try await provider().validateKey()
            Issue.record("expected a network failure")
        } catch let error as AIError {
            guard case .network = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }
}

// MARK: - Harness

@Suite("Ollama in the record/replay harness")
struct OllamaHarnessTests {
    private func temporaryStore() throws -> (AIRecordingStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("filaway-ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AIRecordingStore(directory: directory), directory)
    }

    @Test("the factory builds an OllamaProvider for live and record")
    func factory() throws {
        let store = AITestPaths.recordingStore
        let live = try AIProviderFactory.make(
            mode: .live,
            store: nil,
            keySource: .none,
            kind: .ollama,
            configuration: StubURLProtocol.configuration()
        )
        #expect(live.identifier == "ollama")

        let record = try AIProviderFactory.make(
            mode: .record,
            store: store,
            keySource: .none,
            kind: .ollama,
            configuration: StubURLProtocol.configuration()
        )
        #expect(record.identifier == "recording")
        #expect((record as? RecordingProvider)?.upstream.identifier == "ollama")

        // Replay is provider-agnostic: the fixture says which wire it is in.
        let replay = try AIProviderFactory.make(
            mode: .replay, store: store, keySource: .none, kind: .ollama
        )
        #expect(replay.identifier == "replay")

        // …and the default is still Claude, with no key needed to build it.
        let claude = try AIProviderFactory.make(
            mode: .live, store: nil, keySource: .fixed("k"), configuration: StubURLProtocol.configuration()
        )
        #expect(claude.identifier == "claude")
    }

    @Test("a v1 recording with no provider field loads as Claude")
    func v1RecordingIsClaude() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = AIFixtures.organizeRequest("A v1 fixture.")
        let response = AIResponse.text("from v1", model: request.model)
        let json = """
        {
          "version": 1,
          "purpose": "organize",
          "key": "\(request.fixtureKey)",
          "model": "\(request.model.id)",
          "request": \(String(decoding: try JSONEncoder().encode(request), as: UTF8.self)),
          "requestBody": \(String(decoding: try ClaudeWire.body(for: request).canonicalData(), as: UTF8.self)),
          "responseBody": \(String(decoding: try ClaudeWire.value(for: response).canonicalData(), as: UTF8.self))
        }
        """
        let url = store.url(for: request)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let loaded = try #require(try store.load(for: request))
        #expect(loaded.version == 1)
        #expect(loaded.provider == "claude", "the default is what every committed fixture is")
        #expect(try loaded.response().text == "from v1")

        // …and it replays through the Claude decoder, not Ollama's.
        let replayed = try await ReplayProvider(store: store).complete(request)
        #expect(replayed.text == "from v1")
    }

    @Test("an Ollama exchange records as v2 and replays through OllamaWire")
    func recordReplayThroughOllamaWire() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = OllamaSamples.forcedRequest()
        // A mock wearing the Ollama identifier: what is under test here is the
        // harness's dispatch by provider, not the transport (which has its own
        // suite, and which must not race this one over the global URL stub).
        let upstream = MockProvider(identifier: "ollama") { request in
            try OllamaWire.response(from: OllamaSamples.chatReply(), for: request)
        }
        let recorder = RecordingProvider(upstream: upstream, store: store, clock: TestClock())
        let live = try await recorder.complete(request)

        let recording = try #require(try store.load(for: request))
        #expect(recording.version == 2)
        #expect(recording.provider == "ollama")
        #expect(recording.key == request.fixtureKey)
        #expect(recording.requestBody == OllamaWire.body(for: request), "the stored body is Ollama's, not Claude's")
        #expect(recording.requestBody["format"] == OllamaSamples.schema)

        let replayed = try await ReplayProvider(store: store).complete(request)
        #expect(replayed.content == live.content)
        #expect(replayed.stopReason == live.stopReason)
        #expect(replayed.usage == live.usage)
        #expect(replayed.id == live.id)
        #expect(replayed.toolUse(named: "answer_selection")?.input["chunk_index"] == .integer(1))
    }

    @Test("recorded key validation replays the tag list, not an Anthropic model list")
    func recordValidateKey() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let upstream = MockProvider(
            identifier: "ollama",
            models: [AIModelInfo(
                id: "llama3.1:8b",
                displayName: "llama3.1:8b",
                createdAt: ISO8601.date(from: "2026-08-23T22:15:52Z"),
                supportsAdaptiveThinking: false
            )],
            handler: { _ in .text("unused") }
        )
        _ = try await RecordingProvider(upstream: upstream, store: store, clock: TestClock()).validateKey()

        let recording = try #require(try store.load(purpose: .validate, key: ReplayProvider.validateKeyFixtureKey))
        #expect(recording.provider == "ollama")
        #expect(recording.responseBody["models"] != nil)

        let replayed = try await ReplayProvider(store: store).validateKey()
        #expect(replayed.map(\.id) == ["llama3.1:8b"])
    }

    @Test("the committed Claude validate fixture still replays")
    func committedValidateFixtureStillWorks() async throws {
        let models = try await ReplayProvider(store: AITestPaths.recordingStore).validateKey()
        #expect(models.map(\.id).contains("claude-sonnet-5"))
    }

    @Test("the usage ledger can be asked for one kind or for everything")
    func ledgerByProvider() async throws {
        let ledger = try AIUsageLedger()
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let response = AIResponse(
            id: "x", model: "llama3.1:8b", content: [], stopReason: .endTurn,
            usage: AIUsage(inputTokens: 10, outputTokens: 5)
        )
        try await ledger.record(response: response, purpose: .search, provider: "ollama", at: now)
        try await ledger.record(
            response: AIResponse(
                id: "y", model: "claude-haiku-4-5", content: [], stopReason: .endTurn,
                usage: AIUsage(inputTokens: 100, outputTokens: 50)
            ),
            purpose: .search, provider: "claude", at: now
        )

        #expect(try await ledger.monthlyTotals(containing: now, provider: .ollama).inputTokens == 10)
        #expect(try await ledger.monthlyTotals(containing: now, provider: .claude).inputTokens == 100)
        #expect(try await ledger.monthlyTotals(containing: now, provider: nil).requests == 2)
        #expect(try await ledger.totals(from: .distantPast, to: .distantFuture, provider: .ollama).requests == 1)
        let split = try await ledger.monthlyTotalsByPurpose(containing: now, provider: .ollama)
        #expect(split[.search]?.outputTokens == 5)
    }

    @Test("notConfigured and missingRecording both name the keyless path")
    func copy() {
        #expect(AIError.notConfigured.description.contains("FILAWAY_AI_PROVIDER=ollama"))
        let missing = AIError.missingRecording(purpose: .search, key: "abc", path: "/tmp/abc.json")
        #expect(missing.description.contains("FILAWAY_AI_MODE=record"))
        #expect(missing.description.contains("FILAWAY_AI_PROVIDER=ollama"))
    }
}

// MARK: - Live probe

/// The one suite that talks to the real daemon.
///
/// Off unless `FILAWAY_TEST_OLLAMA=1`, exactly like `FILAWAY_TEST_KEYCHAIN`:
/// CI has no Ollama, and a test that silently needs a background service is a
/// flake. Run it with a daemon up and `llama3.1:8b` pulled:
///
/// ```bash
/// FILAWAY_TEST_OLLAMA=1 swift test --filter Ollama
/// ```
@Suite(
    "Ollama live probe",
    .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_TEST_OLLAMA"] == "1"),
    .serialized
)
struct OllamaLiveProbeTests {
    @Test("the daemon answers /api/tags")
    func tags() async throws {
        let models = try await OllamaProvider().validateKey()
        #expect(!models.isEmpty, "nothing has been pulled — `ollama pull llama3.1:8b`")
        print("[ollama] tags: \(models.map(\.id).joined(separator: ", "))")
    }

    @Test("a forced answer_selection request comes back as a usable tool block")
    func forcedToolCall() async throws {
        var request = OllamaSamples.forcedRequest()
        request.messages = [.user("""
        Question: what header carries the token in the curl command?

        [0] Docker cheats — handy container commands.
        [1] Staging docs — curl -H "Auth: Bearer $TOK" https://staging.example.test/docs
        """)]
        request.timeout = 60

        let started = Date()
        let response = try await OllamaProvider(retryPolicy: .none).complete(request)
        let elapsed = Date().timeIntervalSince(started)

        let call = try #require(response.toolUse(named: "answer_selection"))
        #expect(response.stopReason == .toolUse)
        #expect(call.input.objectValue?.keys.sorted() == ["chunk_index", "snippet"])
        #expect(call.input["snippet"]?.stringValue?.isEmpty == false)
        #expect(response.usage.inputTokens > 0)
        #expect(response.usage.outputTokens > 0)
        print("""
        [ollama] \(response.model) in \(String(format: "%.2f", elapsed))s, \
        chunk_index=\(call.input["chunk_index"].map(String.init(describing:)) ?? "nil"), \
        tokens \(response.usage.inputTokens)/\(response.usage.outputTokens)
        """)
    }
}
