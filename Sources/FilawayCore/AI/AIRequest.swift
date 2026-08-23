import Foundation

/// One turn of a conversation. Phase 1 sends text only — no images, no
/// documents, no tool-result round trips (the organizer forces a single tool
/// call and reads its input).
public struct AIMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> AIMessage { AIMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, text: text) }
}

/// A tool definition, in the strict-tool-use form.
///
/// `strict` is a **top-level** field of the tool (not of `tool_choice`), and the
/// schema must close itself with `additionalProperties: false` plus an explicit
/// `required` list — that is what makes `tool_use.input` guaranteed to validate.
public struct AITool: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var strict: Bool

    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }
}

/// How the model is allowed to pick a tool.
public enum AIToolChoice: Sendable, Hashable, Codable {
    /// The model decides.
    case auto
    /// The model must use one of the supplied tools.
    case any
    /// The model must use exactly this tool — how plans and answers are forced.
    case tool(name: String)
    /// The model must not use a tool.
    case none
}

/// Extended-thinking configuration.
///
/// `budget_tokens` is deliberately absent: it is rejected with a 400 on Sonnet 5
/// and Opus 5, and adaptive thinking replaces it. Requests to a model whose
/// ``AIModel/supportsAdaptiveThinking`` is `false` (Haiku 4.5) drop the field.
public enum AIThinking: Sendable, Hashable, Codable {
    case adaptive(display: Display? = nil)
    case disabled

    public enum Display: String, Sendable, Hashable, Codable {
        case summarized
        case omitted
    }
}

/// `output_config.effort` — how much depth the model spends.
public enum AIEffort: String, Sendable, Hashable, Codable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
}

/// A provider-independent request (NFR-5).
///
/// Only ``model``, ``system``, ``messages``, ``tools`` and ``toolChoice`` take
/// part in the fixture key: everything else (timeouts, token caps, thinking
/// depth, purpose) is an execution knob rather than part of "what was asked".
public struct AIRequest: Sendable, Hashable, Codable {
    public var model: AIModel
    public var system: String?
    public var messages: [AIMessage]
    public var tools: [AITool]
    public var toolChoice: AIToolChoice?
    public var maxTokens: Int
    public var thinking: AIThinking?
    public var effort: AIEffort?
    /// Wall-clock budget for the whole call, retries excluded.
    public var timeout: TimeInterval
    /// Why the request is being made — ledger bucket and fixture directory.
    public var purpose: AIPurpose

    public init(
        model: AIModel,
        purpose: AIPurpose,
        system: String? = nil,
        messages: [AIMessage],
        tools: [AITool] = [],
        toolChoice: AIToolChoice? = nil,
        maxTokens: Int? = nil,
        thinking: AIThinking? = nil,
        effort: AIEffort? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.model = model
        self.purpose = purpose
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens ?? purpose.defaultMaxTokens
        self.thinking = thinking
        self.effort = effort
        self.timeout = timeout ?? purpose.defaultTimeout
    }

    /// The subset of the request that identifies "what was asked", used for the
    /// replay fixture key.
    struct Canonical: Encodable {
        let model: String
        let system: String?
        let messages: [AIMessage]
        let tools: [AITool]
        let toolChoice: AIToolChoice?
    }

    var canonical: Canonical {
        Canonical(model: model.id, system: system, messages: messages, tools: tools, toolChoice: toolChoice)
    }

    /// Stable 16-hex digest of the canonicalised request — the fixture filename.
    ///
    /// Changing a prompt changes this, which is exactly the point: a prompt
    /// edit must not silently reuse a recording made for the old wording
    /// (plan §9 prompt versioning).
    public var fixtureKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(canonical)) ?? Data()
        return Hashing.shortKey(String(decoding: data, as: UTF8.self))
    }

    /// Bytes of prompt text in the request — safe to log (NFR-4), unlike the
    /// text itself.
    public var promptByteCount: Int {
        (system?.utf8.count ?? 0) + messages.reduce(0) { $0 + $1.text.utf8.count }
    }
}
