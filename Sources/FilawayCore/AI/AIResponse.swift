import Foundation

/// One content block of an assistant turn.
public enum AIContentBlock: Sendable, Hashable, Codable {
    case text(String)
    /// A `tool_use` block. ``input`` is parsed JSON — never string-matched,
    /// because current models vary their escaping inside `input`.
    case toolUse(id: String, name: String, input: JSONValue)
    /// A summarised thinking block (empty when `display` is `omitted`).
    case thinking(String)
    /// Anything the API adds later; kept so a response never decodes lossily.
    case other(type: String, payload: JSONValue)
}

/// Why the model stopped. `refusal` and `max_tokens` are as important to handle
/// as `end_turn`: a truncated plan must never be applied.
public enum AIStopReason: Sendable, Hashable, Codable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case pauseTurn
    case refusal
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "end_turn": self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "pause_turn": self = .pauseTurn
        case "refusal": self = .refusal
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .endTurn: return "end_turn"
        case .toolUse: return "tool_use"
        case .maxTokens: return "max_tokens"
        case .stopSequence: return "stop_sequence"
        case .pauseTurn: return "pause_turn"
        case .refusal: return "refusal"
        case let .other(value): return value
        }
    }

    /// `true` when the turn produced a complete, usable answer.
    public var isUsable: Bool {
        switch self {
        case .endTurn, .toolUse: return true
        default: return false
        }
    }
}

/// `stop_details`, populated only when ``AIStopReason/refusal`` fired.
public struct AIStopDetails: Sendable, Hashable, Codable {
    public var type: String
    /// Open set — `"cyber"`, `"bio"`, … — so never switch exhaustively on it.
    public var category: String?
    public var explanation: String?

    public init(type: String, category: String? = nil, explanation: String? = nil) {
        self.type = type
        self.category = category
        self.explanation = explanation
    }
}

/// Token counts, surfaced for the monthly usage indicator (FR-6.6).
public struct AIUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// Every input token billed this turn, cache writes and reads included.
    public var totalInputTokens: Int { inputTokens + cacheCreationInputTokens + cacheReadInputTokens }

    public static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }
}

/// A provider-independent response.
public struct AIResponse: Sendable, Hashable, Codable {
    /// The message id (`msg_…`).
    public var id: String
    /// The model that actually produced the message.
    public var model: String
    public var content: [AIContentBlock]
    public var stopReason: AIStopReason
    public var stopDetails: AIStopDetails?
    public var usage: AIUsage
    /// The `request-id` response header — quote it in bug reports.
    public var requestID: String?

    public init(
        id: String,
        model: String,
        content: [AIContentBlock],
        stopReason: AIStopReason,
        stopDetails: AIStopDetails? = nil,
        usage: AIUsage = AIUsage(),
        requestID: String? = nil
    ) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopDetails = stopDetails
        self.usage = usage
        self.requestID = requestID
    }

    /// Every text block, joined — the answer when no tool was forced.
    public var text: String {
        content.compactMap { if case let .text(value) = $0 { return value } else { return nil } }
            .joined(separator: "\n")
    }

    /// The first `tool_use` block, optionally filtered by name.
    public func toolUse(named name: String? = nil) -> (id: String, name: String, input: JSONValue)? {
        for block in content {
            if case let .toolUse(id, blockName, input) = block, name == nil || blockName == name {
                return (id, blockName, input)
            }
        }
        return nil
    }

    /// `true` when a safety classifier declined the request.
    public var isRefusal: Bool { stopReason == .refusal }

    /// `true` when the model ran into ``AIRequest/maxTokens`` — the content is
    /// truncated and must not be trusted as a complete plan.
    public var isTruncated: Bool { stopReason == .maxTokens }
}
