import Foundation

/// Every sentence Settings → AI and the status pill say about a connection
/// (FR-6.1, FR-6.3, FR-6.4, FR-6.5, FR-6.6), as pure functions of
/// `(provider kind, status, model)`.
///
/// It lives in Core rather than in `SettingsModel` for the usual reason: a
/// string that changes meaning with the provider is logic, and logic that only
/// exists inside a SwiftUI view cannot be tested by `swift test` (plan §8 — no
/// XCTest UI tests on this machine). The views read these; nothing here knows
/// what a `View` is.
///
/// The two provider stories it has to keep straight:
///
/// * **Claude** — a key, a bill, a network. "Connected" means the stored key
///   validated against `GET /v1/models`.
/// * **Ollama** — no key, no bill, no network. "Connected" means the daemon
///   answered `GET /api/tags` *and* the configured model was in the list
///   (ADR-068). The two ways that fails have their own remedies, and each one
///   names the exact shell command that fixes it.
public enum AIConnectionCopy {

    /// The `AIStatus.error` message the manager records when the daemon is up
    /// but the configured tag has not been pulled.
    ///
    /// A marker, not a sentence: ``statusLine(kind:status:model:)`` turns it
    /// into the `ollama pull …` line, which needs the model the message must
    /// not carry (a status string is shown in the toolbar and must stay short).
    public static let modelNotPulled = "Model not pulled"

    /// The `AIStatus.error` message for a base URL the loopback rule forbids.
    public static let invalidBaseURL = "Base URL not allowed"

    // MARK: - Names

    /// The provider's short name, as a connection card titles it. Not
    /// ``AIProviderKind/displayName``, which is the *chooser's* wording
    /// ("Ollama (local)") and reads badly followed by "· connected".
    public static func providerLabel(_ kind: AIProviderKind) -> String {
        switch kind {
        case .claude: return "Claude"
        case .ollama: return "Ollama"
        }
    }

    /// "Claude · connected", "Ollama · offline" — the connection card's title.
    public static func title(kind: AIProviderKind, status: AIStatus) -> String {
        let name = providerLabel(kind)
        switch status {
        case .connected: return "\(name) · connected"
        case .notConfigured: return "\(name) · not connected"
        case .invalidKey: return "\(name) · invalid key"
        case .offline: return "\(name) · offline"
        case .rateLimited: return "\(name) · rate limited"
        case .error: return "\(name) · unavailable"
        }
    }

    // MARK: - The status line

    /// The sentence under the title. `model` is the *effective* model — what a
    /// request would actually be sent to.
    public static func statusLine(kind: AIProviderKind, status: AIStatus, model: AIModel) -> String {
        switch kind {
        case .claude: return claudeStatusLine(status: status, model: model)
        case .ollama: return ollamaStatusLine(status: status, model: model)
        }
    }

    private static func claudeStatusLine(status: AIStatus, model: AIModel) -> String {
        switch status {
        case .connected: return model.id
        case .notConfigured: return "Capture and keyword search work without a key."
        case .invalidKey: return "The stored key was rejected. Enter a new one."
        case .offline: return "The API is unreachable — filing will resume when it is back."
        case .rateLimited: return "Rate limited; organization is queued."
        case let .error(message): return message
        }
    }

    private static func ollamaStatusLine(status: AIStatus, model: AIModel) -> String {
        switch status {
        case .connected:
            return "Connected · \(model.id) · fully private"
        case .offline:
            return "Ollama offline — is the daemon running? (ollama serve)"
        case .notConfigured:
            return "Not connected yet — Test connection checks the daemon. Nothing leaves this Mac."
        case .invalidKey:
            // Unreachable: the local provider never consults a credential. Said
            // plainly rather than left to a fallthrough that would read as a key
            // problem on a provider that has no keys.
            return "The local daemon does not use a key."
        case .rateLimited:
            return "The daemon is busy; organization is queued."
        case let .error(message):
            switch message {
            case modelNotPulled: return pullHint(model: model)
            case invalidBaseURL: return baseURLHint
            default: return message
            }
        }
    }

    /// "Model not pulled — run: ollama pull llama3.1:8b".
    public static func pullHint(model: AIModel) -> String {
        "Model not pulled — run: ollama pull \(model.id)"
    }

    /// Why a base URL was refused (NFR-4's loopback rule).
    public static let baseURLHint =
        "Plain http is allowed only to localhost — a daemon anywhere else must be https."

    // MARK: - Provider chooser (Figure 3 / Figure 4)

    /// The two cards' one-line pitches, so onboarding and Settings cannot drift.
    public static func chooserTitle(_ kind: AIProviderKind) -> String {
        switch kind {
        case .claude: return "Claude API"
        case .ollama: return "Local model (Ollama)"
        }
    }

    public static func chooserDetail(_ kind: AIProviderKind) -> String {
        switch kind {
        case .claude: return "Best quality · needs API key"
        case .ollama: return "Fully private · nothing leaves this Mac"
        }
    }

    // MARK: - The sentences that used to name Claude unconditionally

    /// FR-6.3's always-visible privacy statement (Figure 4), with the real
    /// notes folder in it. Under Ollama it promises something stronger, and can:
    /// nothing is uploaded at all.
    public static func privacyStatement(kind: AIProviderKind, notesPath: String) -> String {
        switch kind {
        case .claude:
            return "Notes are stored on disk at \(notesPath). Nothing is uploaded except text "
                + "sent to Claude during organization and search. Excluded folders are never sent."
        case .ollama:
            return "Notes are stored on disk at \(notesPath). Nothing is uploaded: organizing and "
                + "search run on the Ollama daemon on this Mac. Excluded folders are never sent to it."
        }
    }

    /// FR-4.5's row detail in Settings → AI.
    public static func exclusionDetail(kind: AIProviderKind) -> String {
        switch kind {
        case .claude: return "Nothing in an excluded folder is ever sent to Claude."
        case .ollama: return "Nothing in an excluded folder is ever sent to the AI, local or not."
        }
    }

    // MARK: - Usage (FR-6.6)

    /// "This month: ~12 requests · ~40,000 tokens", or its local variant —
    /// local work is counted, because "how much went local" is the point of
    /// FR-6.5, and priced at nothing, because it is.
    public static func usageSummary(kind: AIProviderKind, totals: AIUsageTotals?) -> String? {
        guard let totals else { return nil }
        let local = kind == .ollama
        guard totals.requests > 0 else {
            return local ? "This month: no local requests yet · $0" : "This month: no requests yet"
        }
        let requests = "~\(totals.requests.formatted()) \(local ? "local " : "")request"
            + (totals.requests == 1 ? "" : "s")
        let tokens = "~\(totals.totalTokens.formatted()) tokens"
        return "This month: \(requests) · \(tokens)" + (local ? " · $0" : "")
    }
}

public extension OllamaConfiguration {

    /// Is `model` among what the daemon reported from `GET /api/tags`?
    ///
    /// Ollama names a tagless pull `<model>:latest`, and a user who types
    /// `llama3.1` into Settings means exactly that image — so a bare name
    /// matches `<name>:latest` and vice versa. Comparison is case-insensitive;
    /// tags are lowercase by convention but nothing enforces it.
    static func isPulled(_ model: AIModel, in models: [AIModelInfo]) -> Bool {
        let wanted = normalizedTag(model.id)
        guard !wanted.isEmpty else { return false }
        return models.contains { normalizedTag($0.id) == wanted }
    }

    /// `true` when this configuration's own model is in `models`.
    func isPulled(in models: [AIModelInfo]) -> Bool { Self.isPulled(model, in: models) }

    /// `name` → `name:latest`, lowercased. An empty or whitespace-only id
    /// normalises to the empty string, which never matches.
    static func normalizedTag(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : trimmed + ":latest"
    }
}
