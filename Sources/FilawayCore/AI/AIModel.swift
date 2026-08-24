import Foundation

/// A Claude model identifier.
///
/// The model is a *parameter of every request* — no call site hard-codes one
/// inside the provider — so Settings can offer the live `/v1/models` list as an
/// advanced override (FR-6.2) without the provider knowing about it.
///
/// Current identifiers carry **no date suffix** (plan §1 amendment 5: Figure 4's
/// `claude-sonnet-4-6` string is stale relative to the product defaults below).
public struct AIModel: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let id: String

    public init(_ id: String) { self.id = id }
    public init(stringLiteral value: String) { self.init(value) }

    public init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    public var description: String { id }

    // MARK: - Known identifiers (2026-08)

    public static let opus5 = AIModel("claude-opus-5")
    public static let sonnet5 = AIModel("claude-sonnet-5")
    public static let haiku45 = AIModel("claude-haiku-4-5")
    public static let sonnet46 = AIModel("claude-sonnet-4-6")
    public static let opus46 = AIModel("claude-opus-4-6")

    /// The identifiers Settings offers before `/v1/models` has been reached.
    public static let known: [AIModel] = [opus5, sonnet5, haiku45, sonnet46, opus46]

    // MARK: - Product defaults (plan §1 "Default models")

    /// Organization plans: Sonnet 5 balances cost and quality (FR-6.2).
    public static let defaultOrganize = sonnet5
    /// Advanced override for organization.
    public static let advancedOrganize = opus5
    /// Search answer extraction: Haiku keeps the answer card under 5 s (NFR-1).
    public static let defaultSearch = haiku45

    /// `true` when the model accepts `thinking: {"type": "adaptive"}`.
    ///
    /// Haiku 4.5 does not — it is on the pre-4.6 `budget_tokens` contract, which
    /// Filaway never uses, so requests to it simply omit `thinking`.
    public var supportsAdaptiveThinking: Bool {
        switch id {
        case AIModel.opus5.id, AIModel.sonnet5.id, AIModel.sonnet46.id, AIModel.opus46.id: return true
        default: return false
        }
    }

    /// `true` when the model accepts `output_config: {"effort": …}`.
    public var supportsEffort: Bool { supportsAdaptiveThinking }
}

/// What a request is *for*. Drives the usage ledger (FR-6.6), the fixture
/// directory in the replay harness, and the default timeout.
public enum AIPurpose: String, Sendable, Hashable, Codable, CaseIterable {
    /// Producing an ``OrganizationPlan`` after a session (FR-4.1).
    case organize
    /// Answer extraction / reranking for semantic search (FR-5.2).
    case search
    /// The free `GET /v1/models` key check (FR-6.1, plan §1 amendment 4).
    case validate

    /// Request budget: plans get 60 s, search 8 s (NFR-1's 5 s answer card plus
    /// headroom), key validation 15 s.
    public var defaultTimeout: TimeInterval {
        switch self {
        case .organize: return 60
        case .search: return 8
        case .validate: return 15
        }
    }

    /// Default output cap for the purpose.
    public var defaultMaxTokens: Int {
        switch self {
        case .organize: return 4096
        case .search: return 1024
        case .validate: return 1024
        }
    }
}

/// One entry of `GET /v1/models`.
///
/// Everything past ``id`` and ``displayName`` is optional: the endpoint gained
/// `max_input_tokens`, `max_tokens` and `capabilities` in 2026 and older
/// deployments (or a stubbed test server) may not send them.
public struct AIModelInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var createdAt: Date?
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?
    /// `capabilities.thinking.types.adaptive.supported`, when reported.
    public var supportsAdaptiveThinking: Bool?

    public init(
        id: String,
        displayName: String,
        createdAt: Date? = nil,
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsAdaptiveThinking: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.supportsAdaptiveThinking = supportsAdaptiveThinking
    }

    public var model: AIModel { AIModel(id) }
}
