import Foundation

/// Which AI backend a request goes to (FR-6.5, NFR-5, P2-01).
///
/// The kind is *not* the same thing as ``AIProvider/identifier``: `replay`,
/// `recording` and `mock` are providers too, but they are harness wrappers
/// around a kind rather than kinds themselves.
public enum AIProviderKind: String, Sendable, Codable, CaseIterable {
    /// Anthropic's Messages API — needs a key, costs money.
    case claude
    /// A local Ollama daemon — no key, no network, no bill.
    case ollama

    /// `FILAWAY_AI_PROVIDER`.
    public static let environmentVariable = "FILAWAY_AI_PROVIDER"

    /// Human-readable name for Settings.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .ollama: return "Ollama (local)"
        }
    }

    /// `true` when a credential must exist before the provider can be used —
    /// the whole point of the local option is that this is `false`.
    public var requiresAPIKey: Bool {
        switch self {
        case .claude: return true
        case .ollama: return false
        }
    }

    /// Wall-clock budget for one request.
    ///
    /// Claude keeps ``AIPurpose``'s numbers. Ollama gets its own: an 8B model on
    /// a laptop CPU/GPU is far slower than Haiku for a long plan (hence 180 s
    /// for organize, which is never on a user-visible path — the card appears
    /// when it appears), and a *cold* model load alone can cost seconds. Search
    /// keeps 8 s because the answer card is on the ⌘K path (NFR-1) and the
    /// local heuristic is behind it; validation gets 15 s, which is generous for
    /// `GET /api/tags`.
    public func timeout(for purpose: AIPurpose) -> TimeInterval {
        switch self {
        case .claude:
            return purpose.defaultTimeout
        case .ollama:
            switch purpose {
            case .organize: return 180
            case .search: return 8
            case .validate: return 15
            }
        }
    }

    /// The kind named by `FILAWAY_AI_PROVIDER`, or `nil` when it is unset or
    /// unrecognised — `nil` means "whatever the caller's default is", never a
    /// silent switch to the wrong backend.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIProviderKind? {
        guard let raw = environment[environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty
        else { return nil }
        return AIProviderKind(rawValue: raw)
    }
}

/// Where the local daemon is and what it runs (P2-01).
///
/// ``model`` is the *default* model for this installation; a request still
/// carries its own ``AIRequest/model``, exactly as with Claude, so Settings can
/// offer the `GET /api/tags` list as an override.
public struct OllamaConfiguration: Sendable, Hashable, Codable {
    /// Ollama's own default, `http://localhost:11434`.
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!
    /// The model P2 develops against.
    public static let defaultModel = AIModel.defaultOllama

    public var baseURL: URL
    public var model: AIModel

    public init(baseURL: URL = OllamaConfiguration.defaultBaseURL, model: AIModel = OllamaConfiguration.defaultModel) {
        self.baseURL = baseURL
        self.model = model
    }

    /// `true` when ``baseURL`` may be used.
    ///
    /// **`http` is allowed only for loopback.** The whole privacy argument for
    /// the local provider is that the prompt never leaves the machine (NFR-4);
    /// plaintext to some other host would quietly undo that, so a remote Ollama
    /// must be reached over `https`. ``OllamaProvider`` turns this into a
    /// `precondition`; this predicate is the non-crashing form Settings and the
    /// tests can ask.
    public static func isValidBaseURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return isLoopback(url.host)
        default: return false
        }
    }

    /// `true` when the host is this machine.
    public static func isLoopback(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// `true` when this configuration can be handed to ``OllamaProvider``.
    public func validate() -> Bool { Self.isValidBaseURL(baseURL) }
}

public extension AIModel {
    /// The local model P2-01 was developed and probed against.
    static let defaultOllama = AIModel("llama3.1:8b")
}
