import Foundation

/// The typed error taxonomy every provider maps onto (FR-6.4, NFR-5).
///
/// The mapping from HTTP is fixed:
///
/// | HTTP | Case |
/// |---|---|
/// | 401, 403 | ``invalidKey(message:)`` |
/// | 429 | ``rateLimited(retryAfter:message:)`` |
/// | 400, 413 | ``badRequest(message:)`` |
/// | 404 | ``modelNotFound(model:message:)`` |
/// | 5xx, 529 | ``serverOverloaded(status:retryAfter:message:)`` |
/// | `URLError` | ``network(code:description:)`` |
/// | undecodable body | ``malformedResponse(_:)`` |
///
/// Only ``isRetryable`` cases are retried, and never a 4xx.
public enum AIError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No credential for a provider that needs one — the Keychain and the
    /// environment are both empty. Unreachable for a local provider, which is
    /// the keyless path (FR-6.5).
    case notConfigured
    case invalidKey(message: String? = nil)
    case rateLimited(retryAfter: TimeInterval? = nil, message: String? = nil)
    case badRequest(message: String)
    case modelNotFound(model: String, message: String? = nil)
    case serverOverloaded(status: Int, retryAfter: TimeInterval? = nil, message: String? = nil)
    case network(code: Int, description: String)
    case malformedResponse(String)
    case timedOut
    case cancelled
    /// Replay mode could not find a fixture — a test-harness failure, never a
    /// production one.
    case missingRecording(purpose: AIPurpose, key: String, path: String)

    /// Whether a retry with backoff can help.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverOverloaded, .network, .timedOut:
            return true
        case .notConfigured, .invalidKey, .badRequest, .modelNotFound, .malformedResponse, .cancelled,
             .missingRecording:
            return false
        }
    }

    /// A `retry-after` value the server asked us to honour, if any.
    public var retryAfter: TimeInterval? {
        switch self {
        case let .rateLimited(retryAfter, _): return retryAfter
        case let .serverOverloaded(_, retryAfter, _): return retryAfter
        default: return nil
        }
    }

    /// Non-nagging, content-free text for the status pill (FR-6.4).
    public var description: String {
        switch self {
        case .notConfigured:
            return "No AI provider configured: add a Claude API key, or run a local model (FILAWAY_AI_PROVIDER=ollama)."
        case let .invalidKey(message):
            return message.map { "The API key was rejected: \($0)" } ?? "The API key was rejected."
        case let .rateLimited(retryAfter, _):
            guard let retryAfter else { return "Rate limited by the API." }
            return "Rate limited by the API; retry in \(Int(retryAfter.rounded())) s."
        case let .badRequest(message):
            return "The request was rejected: \(message)"
        case let .modelNotFound(model, _):
            return "Model \(model) is not available to this key."
        case let .serverOverloaded(status, _, _):
            return "The API is temporarily unavailable (HTTP \(status))."
        case let .network(_, description):
            return "Network error: \(description)"
        case let .malformedResponse(detail):
            return "The API returned something unreadable: \(detail)"
        case .timedOut:
            return "The request timed out."
        case .cancelled:
            return "The request was cancelled."
        case let .missingRecording(purpose, key, path):
            return """
            No AI recording for \(purpose.rawValue)/\(key).json.
            Record it with FILAWAY_AI_MODE=record (needs ANTHROPIC_API_KEY, or \
            FILAWAY_AI_PROVIDER=ollama and a local daemon), or hand-author \(path).
            """
        }
    }

    /// Maps a `URLError` onto the taxonomy.
    public static func from(urlError error: URLError) -> AIError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        default:
            return .network(code: error.errorCode, description: error.localizedDescription)
        }
    }

    /// Maps an HTTP status onto the taxonomy.
    ///
    /// - Parameters:
    ///   - status: the response status code.
    ///   - message: `error.message` from the API's JSON error envelope.
    ///   - retryAfter: the parsed `retry-after` header, in seconds.
    ///   - model: the model the request named, for the 404 case.
    public static func from(
        status: Int,
        message: String?,
        retryAfter: TimeInterval?,
        model: String
    ) -> AIError {
        switch status {
        case 401, 403:
            return .invalidKey(message: message)
        case 404:
            return .modelNotFound(model: model, message: message)
        case 429:
            return .rateLimited(retryAfter: retryAfter, message: message)
        case 500...:
            return .serverOverloaded(status: status, retryAfter: retryAfter, message: message)
        default:
            return .badRequest(message: message ?? "HTTP \(status)")
        }
    }
}
