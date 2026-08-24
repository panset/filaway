import Foundation

/// What the toolbar status pill shows (FR-6.4, Figure 1 / Figure 4).
///
/// FR-6.4 is emphatic that AI trouble must never block capture, browsing or
/// keyword search, and that the status must be "clear, non-nagging" — so this
/// is a *display* state, not an error to raise in front of the user.
public enum AIStatus: Sendable, Equatable {
    /// No key yet — onboarding was skipped (FR-6.5's gentle prompt).
    case notConfigured
    case connected
    case invalidKey
    /// No network, or the API is unreachable.
    case offline
    /// Rate limited until the given instant.
    case rateLimited(until: Date)
    /// Anything else, with a content-free message.
    case error(String)

    /// `true` when a request is worth attempting right now.
    public func isUsable(at now: Date = Date()) -> Bool {
        switch self {
        case .connected: return true
        case let .rateLimited(until): return until <= now
        case .notConfigured, .invalidKey, .offline, .error: return false
        }
    }

    /// `true` when work should queue rather than be dropped (FR-6.4).
    public var shouldQueue: Bool {
        switch self {
        case .offline, .rateLimited, .error: return true
        case .connected, .notConfigured, .invalidKey: return false
        }
    }

    /// Short label for the pill. Never contains note content.
    public var label: String {
        switch self {
        case .notConfigured: return "AI: not connected"
        case .connected: return "AI: connected"
        case .invalidKey: return "AI: key rejected"
        case .offline: return "AI: offline"
        case .rateLimited: return "AI: rate limited"
        case .error: return "AI: unavailable"
        }
    }
}

/// Derives ``AIStatus`` from the outcome of the last request.
///
/// Deliberately a value type with no I/O: the app layer owns one of these, feeds
/// it every provider result, and reads ``status(at:)`` for the pill. A rate
/// limit heals itself once its deadline passes.
public struct AIHealth: Sendable, Equatable {
    private var raw: AIStatus
    /// When the last outcome was recorded.
    public private(set) var updatedAt: Date?
    /// Consecutive retryable failures — the backoff input for M2-09's queue.
    public private(set) var consecutiveFailures: Int

    public init(status: AIStatus = .notConfigured, updatedAt: Date? = nil) {
        raw = status
        self.updatedAt = updatedAt
        consecutiveFailures = 0
    }

    /// The status now, with an expired rate limit resolved.
    public func status(at now: Date = Date()) -> AIStatus {
        if case let .rateLimited(until) = raw, until <= now { return .connected }
        return raw
    }

    public mutating func recordSuccess(at now: Date = Date()) {
        raw = .connected
        updatedAt = now
        consecutiveFailures = 0
    }

    /// Records a status the error taxonomy cannot express.
    ///
    /// One caller: the keyless provider, whose "the daemon is up but that model
    /// has not been pulled" is neither a bad key nor an outage, and whose remedy
    /// is a shell command rather than a retry (ADR-068). Not retryable by
    /// definition, so the failure streak resets.
    public mutating func record(status: AIStatus, at now: Date = Date()) {
        raw = status
        updatedAt = now
        consecutiveFailures = 0
    }

    /// Folds an error into the status.
    public mutating func recordFailure(_ error: AIError, at now: Date = Date()) {
        raw = AIHealth.status(for: error, at: now)
        updatedAt = now
        consecutiveFailures = error.isRetryable ? consecutiveFailures + 1 : 0
    }

    /// A response can be a failure too: a refusal or a truncated plan means the
    /// pipeline got nothing usable, without the connection being at fault.
    public mutating func recordResponse(_ response: AIResponse, at now: Date = Date()) {
        if response.isRefusal {
            let category = response.stopDetails?.category
            raw = .error(category.map { "The model declined this request (\($0))." }
                ?? "The model declined this request.")
            updatedAt = now
            consecutiveFailures = 0
        } else if response.isTruncated {
            raw = .error("The reply was cut off before it finished.")
            updatedAt = now
            consecutiveFailures = 0
        } else {
            recordSuccess(at: now)
        }
    }

    /// Maps the taxonomy onto the pill.
    public static func status(for error: AIError, at now: Date = Date()) -> AIStatus {
        switch error {
        case .notConfigured:
            return .notConfigured
        case .invalidKey:
            return .invalidKey
        case let .rateLimited(retryAfter, _):
            return .rateLimited(until: now.addingTimeInterval(retryAfter ?? 60))
        case .network, .timedOut:
            return .offline
        case let .serverOverloaded(status, _, _):
            return .error("The API is temporarily unavailable (HTTP \(status)).")
        case .cancelled:
            return .connected
        case let .badRequest(message):
            return .error("The request was rejected: \(message)")
        case let .modelNotFound(model, _):
            return .error("Model \(model) is not available to this key.")
        case .malformedResponse:
            return .error("The API returned something unreadable.")
        case .missingRecording:
            return .error("No recorded AI response for this request.")
        }
    }
}
