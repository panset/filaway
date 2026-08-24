import Foundation

/// Which wire format a recorded exchange is written in (P2-01, ADR-067).
///
/// The record/replay harness used to be hard-wired to ``ClaudeWire``. It is not
/// the harness's business which vendor produced a fixture — it stores *wire*
/// bodies precisely so a hand-authored fixture runs the same decoder a live call
/// does — so the choice of codec now travels with the recording, as
/// ``AIRecording/provider``.
///
/// Anything that is not a known kind (`mock`, a future wrapper) falls back to
/// Claude, which is what every fixture committed before this existed is.
enum ProviderWire: Sendable {
    case claude
    case ollama

    /// The codec for a provider identifier — ``AIProvider/identifier``, or
    /// ``AIRecording/provider``.
    static func named(_ identifier: String) -> ProviderWire {
        AIProviderKind(rawValue: identifier) == .ollama ? .ollama : .claude
    }

    /// The identifier a recording stores.
    var identifier: String {
        switch self {
        case .claude: return AIProviderKind.claude.rawValue
        case .ollama: return AIProviderKind.ollama.rawValue
        }
    }

    func requestBody(for request: AIRequest) -> JSONValue {
        switch self {
        case .claude: return ClaudeWire.body(for: request)
        case .ollama: return OllamaWire.body(for: request)
        }
    }

    func responseValue(for response: AIResponse) -> JSONValue {
        switch self {
        case .claude: return ClaudeWire.value(for: response)
        case .ollama: return OllamaWire.value(for: response)
        }
    }

    /// Decodes a stored response body. `request` is what tells the Ollama
    /// decoder which tool the `format` schema stood in for.
    func response(from value: JSONValue, for request: AIRequest) throws -> AIResponse {
        switch self {
        case .claude: return try ClaudeWire.response(from: value)
        case .ollama: return try OllamaWire.response(from: value, for: request)
        }
    }

    func models(from value: JSONValue) throws -> [AIModelInfo] {
        switch self {
        case .claude: return try ClaudeWire.models(from: value)
        case .ollama: return try OllamaWire.models(from: value)
        }
    }

    func modelsValue(for models: [AIModelInfo]) -> JSONValue {
        switch self {
        case .claude:
            return .object([
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
        case .ollama:
            return OllamaWire.modelsValue(for: models)
        }
    }

    /// The request the key-validation fixture records — there is no body to
    /// hash, so the path is the whole of it.
    var validateRequestBody: JSONValue {
        switch self {
        case .claude: return .object(["method": "GET", "path": "/v1/models?limit=100"])
        case .ollama: return .object(["method": "GET", "path": .string(OllamaWire.tagsPath)])
        }
    }
}
