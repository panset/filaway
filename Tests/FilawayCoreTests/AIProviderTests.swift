import Foundation
import Testing

@testable import FilawayCore

@Suite("Claude request encoding")
struct ClaudeRequestEncodingTests {
    private func planRequest(model: AIModel = .defaultOrganize) -> AIRequest {
        AIRequest(
            model: model,
            purpose: .organize,
            system: "You file notes.",
            messages: [.user("Session text.")],
            tools: [AITool(
                name: "organization_plan",
                description: "Report the plan.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object(["summary": .object(["type": "string"])]),
                    "required": .array(["summary"]),
                    "additionalProperties": .bool(false),
                ])
            )],
            toolChoice: .tool(name: "organization_plan"),
            maxTokens: 4096,
            thinking: .adaptive(),
            effort: .medium
        )
    }

    @Test("the body has exactly the strict-tool-use shape")
    func exactShape() throws {
        let body = ClaudeWire.body(for: planRequest())
        let object = try #require(body.objectValue)

        #expect(object["model"] == .string("claude-sonnet-5"))
        #expect(object["max_tokens"] == .integer(4096))
        #expect(object["system"] == .string("You file notes."))
        #expect(object["messages"] == .array([
            .object(["role": "user", "content": .array([.object(["type": "text", "text": "Session text."])])]),
        ]))
        #expect(object["tool_choice"] == .object(["type": "tool", "name": "organization_plan"]))
        #expect(object["thinking"] == .object(["type": "adaptive"]))
        #expect(object["output_config"] == .object(["effort": "medium"]))

        let tool = try #require(object["tools"]?[0]?.objectValue)
        #expect(tool["strict"] == .bool(true))
        #expect(tool["input_schema"]?["additionalProperties"] == .bool(false))
        #expect(tool["input_schema"]?["required"] != nil)

        // No prefill and no budget_tokens: both are 400s on current models.
        #expect(object["messages"]?.arrayValue?.allSatisfy { $0["role"] != .string("assistant") } == true)
        #expect(object["thinking"]?["budget_tokens"] == nil)
        #expect(object["temperature"] == nil)
    }

    @Test("thinking and effort are dropped for models that reject them")
    func haikuDropsThinking() throws {
        var request = planRequest(model: .haiku45)
        request.thinking = .adaptive(display: .summarized)
        request.effort = .low
        let object = try #require(ClaudeWire.body(for: request).objectValue)
        #expect(object["thinking"] == nil)
        #expect(object["output_config"] == nil)
        #expect(object["model"] == .string("claude-haiku-4-5"))
    }

    @Test("thinking display rides along when asked for")
    func thinkingDisplay() throws {
        var request = planRequest()
        request.thinking = .adaptive(display: .summarized)
        let object = try #require(ClaudeWire.body(for: request).objectValue)
        #expect(object["thinking"] == .object(["type": "adaptive", "display": "summarized"]))
    }

    @Test("optional fields are omitted, not sent as null")
    func omitsEmpties() throws {
        let request = AIRequest(model: .haiku45, purpose: .search, messages: [.user("hi")])
        let object = try #require(ClaudeWire.body(for: request).objectValue)
        #expect(object["system"] == nil)
        #expect(object["tools"] == nil)
        #expect(object["tool_choice"] == nil)
        #expect(object.keys.sorted() == ["max_tokens", "messages", "model"])
    }

    @Test("every tool choice has its wire form")
    func toolChoices() {
        #expect(ClaudeWire.toolChoiceValue(.auto) == .object(["type": "auto"]))
        #expect(ClaudeWire.toolChoiceValue(.any) == .object(["type": "any"]))
        #expect(ClaudeWire.toolChoiceValue(.none) == .object(["type": "none"]))
        #expect(ClaudeWire.toolChoiceValue(.tool(name: "x")) == .object(["type": "tool", "name": "x"]))
    }

    @Test("the fixture key ignores execution knobs but not the prompt")
    func fixtureKeyStability() {
        var base = planRequest()
        let key = base.fixtureKey
        base.maxTokens = 99
        base.timeout = 1
        base.effort = .high
        base.thinking = .disabled
        #expect(base.fixtureKey == key, "token caps and thinking depth are not part of what was asked")

        base.system = "Different instructions."
        #expect(base.fixtureKey != key, "a prompt edit must not reuse an old recording")
    }
}

@Suite("Claude response decoding")
struct ClaudeResponseDecodingTests {
    @Test("text answer")
    func text() throws {
        let value = try JSONValue.parse("""
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5",
         "content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn",
         "usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":7}}
        """)
        let response = try ClaudeWire.response(from: value, requestID: "req_9")
        #expect(response.id == "msg_1")
        #expect(response.text == "hello")
        #expect(response.stopReason == .endTurn)
        #expect(response.usage.inputTokens == 12)
        #expect(response.usage.outputTokens == 3)
        #expect(response.usage.cacheReadInputTokens == 7)
        #expect(response.usage.totalInputTokens == 19)
        #expect(response.requestID == "req_9")
        #expect(response.isRefusal == false)
    }

    @Test("tool_use input is parsed JSON, never a string")
    func toolUse() throws {
        let value = try JSONValue.parse("""
        {"id":"msg_2","type":"message","model":"claude-sonnet-5",
         "content":[{"type":"thinking","thinking":"…"},
                    {"type":"tool_use","id":"toolu_1","name":"organization_plan",
                     "input":{"summary":"file it","actions":[]}}],
         "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":2}}
        """)
        let response = try ClaudeWire.response(from: value)
        let call = try #require(response.toolUse(named: "organization_plan"))
        #expect(call.id == "toolu_1")
        #expect(call.input["summary"] == .string("file it"))
        #expect(call.input["actions"] == .array([]))
        #expect(response.content.count == 2)
        #expect(response.toolUse(named: "other") == nil)
    }

    @Test("refusal carries stop_details")
    func refusal() throws {
        let value = try JSONValue.parse("""
        {"id":"msg_3","type":"message","model":"claude-sonnet-5","content":[],
         "stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"declined"},
         "usage":{"input_tokens":5,"output_tokens":0}}
        """)
        let response = try ClaudeWire.response(from: value)
        #expect(response.isRefusal)
        #expect(response.stopDetails?.category == "cyber")
        #expect(response.stopReason.isUsable == false)
    }

    @Test("max_tokens is surfaced as truncation")
    func truncated() throws {
        let value = try JSONValue.parse("""
        {"id":"msg_4","type":"message","model":"claude-sonnet-5",
         "content":[{"type":"text","text":"half a pl"}],"stop_reason":"max_tokens",
         "usage":{"input_tokens":5,"output_tokens":4096}}
        """)
        let response = try ClaudeWire.response(from: value)
        #expect(response.isTruncated)
        #expect(response.stopReason.isUsable == false)
    }

    @Test("an unknown stop reason and block type decode without loss")
    func unknownShapes() throws {
        let value = try JSONValue.parse("""
        {"id":"msg_5","type":"message","model":"m","content":[{"type":"future_block","x":1}],
         "stop_reason":"something_new","usage":{"input_tokens":0,"output_tokens":0}}
        """)
        let response = try ClaudeWire.response(from: value)
        #expect(response.stopReason == .other("something_new"))
        #expect(response.stopReason.rawValue == "something_new")
        if case let .other(type, _) = response.content[0] {
            #expect(type == "future_block")
        } else {
            Issue.record("expected an .other block")
        }
    }

    @Test("missing required fields are malformedResponse, not crashes")
    func malformed() throws {
        for body in [
            #"{"type":"message","model":"m","content":[],"stop_reason":"end_turn"}"#,
            #"{"id":"x","type":"message","content":[],"stop_reason":"end_turn"}"#,
            #"{"id":"x","type":"message","model":"m","stop_reason":"end_turn"}"#,
            #"{"id":"x","type":"message","model":"m","content":[],"usage":{}}"#,
            #"{"id":"x","type":"message","model":"m","content":[{"type":"text"}],"stop_reason":"end_turn"}"#,
            "[]",
        ] {
            let value = try JSONValue.parse(body)
            #expect(throws: AIError.self) { try ClaudeWire.response(from: value) }
        }
    }

    @Test("response round-trips through wire form")
    func roundTrip() throws {
        let original = AIResponse(
            id: "msg_6",
            model: "claude-sonnet-5",
            content: [.text("a"), .toolUse(id: "t", name: "n", input: .object(["k": "v"])), .thinking("t")],
            stopReason: .toolUse,
            stopDetails: AIStopDetails(type: "refusal", category: "cyber", explanation: "e"),
            usage: AIUsage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
        )
        let decoded = try ClaudeWire.response(from: ClaudeWire.value(for: original))
        #expect(decoded == original)
    }

    @Test("the model list decodes, with and without the newer fields")
    func modelList() throws {
        let value = try JSONValue.parse("""
        {"data":[
          {"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5","created_at":"2026-02-01T00:00:00Z",
           "max_input_tokens":1000000,"max_tokens":128000,
           "capabilities":{"thinking":{"types":{"adaptive":{"supported":true}}}}},
          {"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5"}],
         "has_more":false}
        """)
        let models = try ClaudeWire.models(from: value)
        #expect(models.count == 2)
        #expect(models[0].id == "claude-opus-5")
        #expect(models[0].maxInputTokens == 1_000_000)
        #expect(models[0].supportsAdaptiveThinking == true)
        #expect(models[0].createdAt == ISO8601.date(from: "2026-02-01T00:00:00Z"))
        #expect(models[1].maxInputTokens == nil)
        #expect(models[1].model == .haiku45)
        #expect(throws: AIError.self) { try ClaudeWire.models(from: .object(["nope": 1])) }
    }

    @Test("retry-after parses seconds and HTTP dates")
    func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        #expect(ClaudeWire.retryAfter("30", now: now) == 30)
        #expect(ClaudeWire.retryAfter(" 5 ", now: now) == 5)
        #expect(ClaudeWire.retryAfter(nil, now: now) == nil)
        #expect(ClaudeWire.retryAfter("not-a-number", now: now) == nil)
        let future = Date(timeIntervalSince1970: 1_756_000_060)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = ClaudeWire.retryAfter(formatter.string(from: future), now: now)
        #expect(parsed == 60)
    }
}

@Suite("ClaudeProvider over a stubbed transport", .serialized)
struct ClaudeProviderTransportTests {
    private func provider(
        clock: TestClock = TestClock(),
        retry: RetryPolicy = .none,
        key: String? = "sk-ant-test"
    ) -> ClaudeProvider {
        ClaudeProvider(
            keySource: .fixed(key),
            configuration: StubURLProtocol.configuration(),
            retryPolicy: retry,
            clock: clock
        )
    }

    private var okMessage: JSONValue {
        .object([
            "id": "msg_ok",
            "type": "message",
            "model": "claude-sonnet-5",
            "content": .array([.object(["type": "text", "text": "ok"])]),
            "stop_reason": "end_turn",
            "usage": .object(["input_tokens": 10, "output_tokens": 20]),
        ])
    }

    private var request: AIRequest {
        AIRequest(model: .defaultOrganize, purpose: .organize, system: "sys", messages: [.user("hello")])
    }

    @Test("a successful call sends the documented headers and body")
    func headersAndBody() async throws {
        StubURLProtocol.always(.reply(.json(okMessage, headers: ["request-id": "req_42"])))
        defer { StubURLProtocol.reset() }

        let response = try await provider().complete(request)
        #expect(response.text == "ok")
        #expect(response.requestID == "req_42")

        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.method == "POST")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.headers["anthropic-version"] == "2023-06-01")
        #expect(sent.headers["content-type"] == "application/json")
        #expect(sent.json?["model"] == .string("claude-sonnet-5"))
        #expect(sent.json?["system"] == .string("sys"))
    }

    @Test("no key at all is notConfigured, and nothing is sent")
    func notConfigured() async throws {
        StubURLProtocol.always(.reply(.json(okMessage)))
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIError.notConfigured) {
            try await provider(key: nil).complete(request)
        }
        await #expect(throws: AIError.notConfigured) {
            try await provider(key: "   ").complete(request)
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test("401 maps to invalidKey and is never retried")
    func unauthorized() async throws {
        StubURLProtocol.always(.reply(.json(
            .object(["type": "error", "error": .object(["type": "authentication_error", "message": "bad key"])]),
            status: 401
        )))
        defer { StubURLProtocol.reset() }

        let clock = TestClock()
        await #expect(throws: AIError.invalidKey(message: "bad key")) {
            try await provider(clock: clock, retry: RetryPolicy(maxAttempts: 3)).complete(request)
        }
        #expect(StubURLProtocol.requests.count == 1, "a 4xx must not be retried")
        #expect(clock.recordedSleeps.isEmpty)
    }

    @Test("404 maps to modelNotFound and names the model")
    func notFound() async throws {
        StubURLProtocol.always(.reply(.json(
            .object(["type": "error", "error": .object(["message": "model: nope"])]), status: 404
        )))
        defer { StubURLProtocol.reset() }
        var bad = request
        bad.model = AIModel("claude-nope")
        await #expect(throws: AIError.modelNotFound(model: "claude-nope", message: "model: nope")) {
            try await provider().complete(bad)
        }
    }

    @Test("400 maps to badRequest")
    func badRequest() async throws {
        StubURLProtocol.always(.reply(.json(
            .object(["type": "error", "error": .object(["message": "messages: too long"])]), status: 400
        )))
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIError.badRequest(message: "messages: too long")) {
            try await provider().complete(request)
        }
    }

    @Test("429 waits for retry-after, then succeeds")
    func rateLimited() async throws {
        StubURLProtocol.sequence([
            .reply(.json(
                .object(["type": "error", "error": .object(["message": "slow down"])]),
                status: 429,
                headers: ["retry-after": "7"]
            )),
            .reply(.json(okMessage)),
        ])
        defer { StubURLProtocol.reset() }

        let clock = TestClock()
        let response = try await provider(clock: clock, retry: RetryPolicy(maxAttempts: 3)).complete(request)
        #expect(response.text == "ok")
        #expect(clock.recordedSleeps == [7], "the server's retry-after wins over the exponential schedule")
        #expect(StubURLProtocol.requests.count == 2)
    }

    @Test("429 that never clears gives up after maxAttempts")
    func rateLimitedExhausted() async throws {
        StubURLProtocol.always(.reply(.json(
            .object(["error": .object(["message": "nope"])]), status: 429, headers: ["retry-after": "2"]
        )))
        defer { StubURLProtocol.reset() }

        let clock = TestClock()
        await #expect(throws: AIError.rateLimited(retryAfter: 2, message: "nope")) {
            try await provider(clock: clock, retry: RetryPolicy(maxAttempts: 3)).complete(request)
        }
        #expect(StubURLProtocol.requests.count == 3)
        #expect(clock.recordedSleeps == [2, 2])
    }

    @Test("529 backs off exponentially with jitter")
    func overloaded() async throws {
        StubURLProtocol.sequence([
            .reply(.json(.object(["error": .object(["message": "overloaded"])]), status: 529)),
            .reply(.json(.object(["error": .object(["message": "overloaded"])]), status: 529)),
            .reply(.json(okMessage)),
        ])
        defer { StubURLProtocol.reset() }

        let clock = TestClock(randomFraction: 1)  // full jitter -> the un-jittered delay
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, multiplier: 2, jitter: 0.5)
        let response = try await provider(clock: clock, retry: policy).complete(request)
        #expect(response.text == "ok")
        #expect(clock.recordedSleeps == [0.5, 1.0])
    }

    @Test("a URLError becomes .network and is retried")
    func networkFailure() async throws {
        StubURLProtocol.sequence([
            .failure(URLError(.notConnectedToInternet)),
            .reply(.json(okMessage)),
        ])
        defer { StubURLProtocol.reset() }

        let clock = TestClock()
        let response = try await provider(clock: clock, retry: RetryPolicy(maxAttempts: 2)).complete(request)
        #expect(response.text == "ok")
        #expect(clock.recordedSleeps.count == 1)
    }

    @Test("a timeout is its own case")
    func timeout() async throws {
        StubURLProtocol.always(.failure(URLError(.timedOut)))
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIError.timedOut) { try await provider().complete(request) }
    }

    @Test("a body that is not JSON is malformedResponse")
    func malformedBody() async throws {
        StubURLProtocol.always(.reply(.init(status: 200, body: Data("<html>nope</html>".utf8))))
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIError.self) { try await provider().complete(request) }
        #expect(StubURLProtocol.requests.count == 1, "a decode failure is not retryable")
    }

    @Test("validateKey hits GET /v1/models")
    func validateKey() async throws {
        StubURLProtocol.always(.reply(.json(.object([
            "data": .array([.object(["type": "model", "id": "claude-sonnet-5", "display_name": "Claude Sonnet 5"])]),
            "has_more": .bool(false),
        ]))))
        defer { StubURLProtocol.reset() }

        let models = try await provider().validateKey()
        #expect(models.map(\.id) == ["claude-sonnet-5"])
        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.method == "GET")
        #expect(sent.url?.path == "/v1/models")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.body?.isEmpty ?? true, "key validation must not bill a message")
    }

    @Test("validateKey on a bad key is invalidKey")
    func validateBadKey() async throws {
        StubURLProtocol.always(.reply(.json(
            .object(["error": .object(["message": "invalid x-api-key"])]), status: 401
        )))
        defer { StubURLProtocol.reset() }
        await #expect(throws: AIError.invalidKey(message: "invalid x-api-key")) {
            try await provider().validateKey()
        }
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("only retryable errors are retried")
    func retryability() {
        let policy = RetryPolicy(maxAttempts: 3)
        #expect(policy.shouldRetry(.rateLimited(), attempt: 1))
        #expect(policy.shouldRetry(.serverOverloaded(status: 500), attempt: 2))
        #expect(policy.shouldRetry(.network(code: -1009, description: "offline"), attempt: 1))
        #expect(policy.shouldRetry(.timedOut, attempt: 1))
        #expect(!policy.shouldRetry(.invalidKey(), attempt: 1))
        #expect(!policy.shouldRetry(.badRequest(message: "x"), attempt: 1))
        #expect(!policy.shouldRetry(.modelNotFound(model: "m"), attempt: 1))
        #expect(!policy.shouldRetry(.malformedResponse("x"), attempt: 1))
        #expect(!policy.shouldRetry(.notConfigured, attempt: 1))
        #expect(!policy.shouldRetry(.rateLimited(), attempt: 3), "attempt 3 of 3 is the last one")
    }

    @Test("delays grow, stay jittered, and respect the cap")
    func delays() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, multiplier: 2, maxDelay: 10, jitter: 0.5)
        #expect(policy.delay(afterAttempt: 1, retryAfter: nil, randomFraction: 1) == 1)
        #expect(policy.delay(afterAttempt: 1, retryAfter: nil, randomFraction: 0) == 0.5)
        #expect(policy.delay(afterAttempt: 2, retryAfter: nil, randomFraction: 1) == 2)
        #expect(policy.delay(afterAttempt: 3, retryAfter: nil, randomFraction: 1) == 4)
        #expect(policy.delay(afterAttempt: 9, retryAfter: nil, randomFraction: 1) == 10, "capped")
        #expect(policy.delay(afterAttempt: 1, retryAfter: 3, randomFraction: 1) == 3, "retry-after wins")
        #expect(policy.delay(afterAttempt: 1, retryAfter: 900, randomFraction: 1) == 10, "…but is still capped")
        #expect(policy.delay(afterAttempt: 1, retryAfter: -5, randomFraction: 1) == 0)
    }

    @Test("the error taxonomy maps from HTTP exactly once")
    func mapping() {
        #expect(AIError.from(status: 401, message: "m", retryAfter: nil, model: "x") == .invalidKey(message: "m"))
        #expect(AIError.from(status: 403, message: nil, retryAfter: nil, model: "x") == .invalidKey(message: nil))
        #expect(AIError.from(status: 404, message: nil, retryAfter: nil, model: "x") == .modelNotFound(model: "x"))
        #expect(AIError.from(status: 429, message: nil, retryAfter: 3, model: "x") == .rateLimited(retryAfter: 3))
        #expect(AIError.from(status: 500, message: nil, retryAfter: nil, model: "x") == .serverOverloaded(status: 500))
        #expect(AIError.from(status: 529, message: nil, retryAfter: nil, model: "x") == .serverOverloaded(status: 529))
        #expect(AIError.from(status: 400, message: "bad", retryAfter: nil, model: "x") == .badRequest(message: "bad"))
        #expect(AIError.from(status: 413, message: nil, retryAfter: nil, model: "x") == .badRequest(message: "HTTP 413"))
        #expect(AIError.from(urlError: URLError(.timedOut)) == .timedOut)
        #expect(AIError.from(urlError: URLError(.cancelled)) == .cancelled)
        if case .network = AIError.from(urlError: URLError(.dnsLookupFailed)) {} else {
            Issue.record("a DNS failure should be .network")
        }
    }
}
