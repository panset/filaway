import Foundation

/// The exact JSON the Anthropic Messages API speaks, in both directions.
///
/// Kept separate from ``ClaudeProvider`` so the encoder and decoder are unit
/// testable without a network at all, and so the record/replay harness can
/// store *wire* bodies in its fixtures: a hand-authored fixture then exercises
/// the very same decoder a live response would.
///
/// API surface as of 2026-08:
///
/// * `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`,
///   `anthropic-version: 2023-06-01`, `content-type: application/json`.
/// * Structured output via **strict tool use**: `strict: true` on the tool,
///   `additionalProperties: false` + `required` in the schema, forced with
///   `tool_choice: {"type": "tool", "name": …}`. No assistant prefill — it is a
///   400 on current models.
/// * `thinking: {"type": "adaptive"}` and `output_config: {"effort": …}`;
///   `budget_tokens` is gone.
public enum ClaudeWire {
    public static let version = "2023-06-01"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    // MARK: - Request

    /// Builds the request body for the Messages API.
    ///
    /// `thinking` and `output_config` are dropped for models that do not accept
    /// them (Haiku 4.5), so a caller can set a house default without having to
    /// branch per model.
    public static func body(for request: AIRequest) -> JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(request.model.id),
            "max_tokens": .integer(request.maxTokens),
            "messages": .array(request.messages.map(messageValue)),
        ]

        if let system = request.system, !system.isEmpty {
            object["system"] = .string(system)
        }
        if !request.tools.isEmpty {
            object["tools"] = .array(request.tools.map(toolValue))
        }
        if let choice = request.toolChoice {
            object["tool_choice"] = toolChoiceValue(choice)
        }
        if let thinking = request.thinking, request.model.supportsAdaptiveThinking {
            object["thinking"] = thinkingValue(thinking)
        }
        if let effort = request.effort, request.model.supportsEffort {
            object["output_config"] = .object(["effort": .string(effort.rawValue)])
        }
        return .object(object)
    }

    static func messageValue(_ message: AIMessage) -> JSONValue {
        .object([
            "role": .string(message.role.rawValue),
            "content": .array([.object(["type": "text", "text": .string(message.text)])]),
        ])
    }

    static func toolValue(_ tool: AITool) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema,
        ]
        if tool.strict { object["strict"] = .bool(true) }
        return .object(object)
    }

    static func toolChoiceValue(_ choice: AIToolChoice) -> JSONValue {
        switch choice {
        case .auto: return .object(["type": "auto"])
        case .any: return .object(["type": "any"])
        case .none: return .object(["type": "none"])
        case let .tool(name): return .object(["type": "tool", "name": .string(name)])
        }
    }

    static func thinkingValue(_ thinking: AIThinking) -> JSONValue {
        switch thinking {
        case .disabled:
            return .object(["type": "disabled"])
        case let .adaptive(display):
            var object: [String: JSONValue] = ["type": "adaptive"]
            if let display { object["display"] = .string(display.rawValue) }
            return .object(object)
        }
    }

    // MARK: - Response

    /// Decodes a `message` object into the provider-independent response.
    ///
    /// - Throws: ``AIError/malformedResponse(_:)`` when a required field is
    ///   missing or has the wrong shape.
    public static func response(from value: JSONValue, requestID: String? = nil) throws -> AIResponse {
        guard let object = value.objectValue else {
            throw AIError.malformedResponse("response is \(value.typeName), expected an object")
        }
        if let type = object["type"]?.stringValue, type == "error" {
            let message = object["error"]?["message"]?.stringValue ?? "unknown error"
            throw AIError.badRequest(message: message)
        }
        guard let id = object["id"]?.stringValue else {
            throw AIError.malformedResponse("missing \"id\"")
        }
        guard let model = object["model"]?.stringValue else {
            throw AIError.malformedResponse("missing \"model\"")
        }
        guard let rawContent = object["content"]?.arrayValue else {
            throw AIError.malformedResponse("missing \"content\" array")
        }
        guard let stopReason = object["stop_reason"]?.stringValue else {
            throw AIError.malformedResponse("missing \"stop_reason\"")
        }

        let content = try rawContent.map(contentBlock(from:))

        var stopDetails: AIStopDetails?
        if let details = object["stop_details"]?.objectValue, let type = details["type"]?.stringValue {
            stopDetails = AIStopDetails(
                type: type,
                category: details["category"]?.stringValue,
                explanation: details["explanation"]?.stringValue
            )
        }

        var usage = AIUsage()
        if let raw = object["usage"]?.objectValue {
            usage = AIUsage(
                inputTokens: raw["input_tokens"]?.intValue ?? 0,
                outputTokens: raw["output_tokens"]?.intValue ?? 0,
                cacheCreationInputTokens: raw["cache_creation_input_tokens"]?.intValue ?? 0,
                cacheReadInputTokens: raw["cache_read_input_tokens"]?.intValue ?? 0
            )
        }

        return AIResponse(
            id: id,
            model: model,
            content: content,
            stopReason: AIStopReason(rawValue: stopReason),
            stopDetails: stopDetails,
            usage: usage,
            requestID: requestID
        )
    }

    static func contentBlock(from value: JSONValue) throws -> AIContentBlock {
        guard let object = value.objectValue, let type = object["type"]?.stringValue else {
            throw AIError.malformedResponse("content block without a \"type\"")
        }
        switch type {
        case "text":
            guard let text = object["text"]?.stringValue else {
                throw AIError.malformedResponse("text block without \"text\"")
            }
            return .text(text)
        case "tool_use":
            guard let id = object["id"]?.stringValue, let name = object["name"]?.stringValue else {
                throw AIError.malformedResponse("tool_use block without \"id\"/\"name\"")
            }
            return .toolUse(id: id, name: name, input: object["input"] ?? .object([:]))
        case "thinking":
            return .thinking(object["thinking"]?.stringValue ?? object["text"]?.stringValue ?? "")
        default:
            return .other(type: type, payload: value)
        }
    }

    /// Re-encodes a response into wire form.
    ///
    /// Used by ``RecordingProvider`` so a fixture holds the same JSON shape a
    /// live call would have produced, and by the round-trip tests.
    public static func value(for response: AIResponse) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(response.id),
            "type": "message",
            "role": "assistant",
            "model": .string(response.model),
            "content": .array(response.content.map(contentValue)),
            "stop_reason": .string(response.stopReason.rawValue),
            "usage": .object([
                "input_tokens": .integer(response.usage.inputTokens),
                "output_tokens": .integer(response.usage.outputTokens),
                "cache_creation_input_tokens": .integer(response.usage.cacheCreationInputTokens),
                "cache_read_input_tokens": .integer(response.usage.cacheReadInputTokens),
            ]),
        ]
        if let details = response.stopDetails {
            var value: [String: JSONValue] = ["type": .string(details.type)]
            if let category = details.category { value["category"] = .string(category) }
            if let explanation = details.explanation { value["explanation"] = .string(explanation) }
            object["stop_details"] = .object(value)
        }
        return .object(object)
    }

    static func contentValue(_ block: AIContentBlock) -> JSONValue {
        switch block {
        case let .text(text):
            return .object(["type": "text", "text": .string(text)])
        case let .toolUse(id, name, input):
            return .object(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
        case let .thinking(text):
            return .object(["type": "thinking", "thinking": .string(text)])
        case let .other(_, payload):
            return payload
        }
    }

    // MARK: - Models

    /// Decodes `GET /v1/models`.
    public static func models(from value: JSONValue) throws -> [AIModelInfo] {
        guard let data = value["data"]?.arrayValue else {
            throw AIError.malformedResponse("missing \"data\" array in the model list")
        }
        return data.compactMap { entry in
            guard let object = entry.objectValue, let id = object["id"]?.stringValue else { return nil }
            let adaptive = object["capabilities"]?["thinking"]?["types"]?["adaptive"]?["supported"]?.boolValue
            return AIModelInfo(
                id: id,
                displayName: object["display_name"]?.stringValue ?? id,
                createdAt: object["created_at"]?.stringValue.flatMap(ISO8601.date(from:)),
                maxInputTokens: object["max_input_tokens"]?.intValue,
                maxOutputTokens: object["max_tokens"]?.intValue,
                supportsAdaptiveThinking: adaptive
            )
        }
    }

    /// Pulls `error.message` out of an error envelope, if the body is one.
    public static func errorMessage(from data: Data) -> String? {
        guard let value = try? JSONValue.parse(data) else { return nil }
        return value["error"]?["message"]?.stringValue ?? value["message"]?.stringValue
    }

    /// Parses a `retry-after` header: delta-seconds, or an HTTP date.
    public static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return Swift.max(0, seconds) }
        if let date = httpDateFormatter.date(from: header) { return Swift.max(0, date.timeIntervalSince(now)) }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
