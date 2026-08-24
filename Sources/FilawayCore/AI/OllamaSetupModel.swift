import Foundation

/// The "is the local daemon there, and has it got the model?" state machine
/// (FR-6.5, FR-7.1, P2-03).
///
/// It lives in Core, not next to the AppKit card it draws, for one reason: the
/// app target has no test target (plan §8 — no Xcode, no XCTest), so anything
/// only reachable from `OnboardingWindowController` is only reachable from a
/// smoke phase. Everything here is a `swift test` away instead, with
/// ``OllamaValidating`` standing in for the daemon.
///
/// ```swift
/// let setup = OllamaSetupModel(validator: StubValidator(models: ["llama3.1:8b"]))
/// await setup.test()
/// setup.isConnected            // true
/// setup.configuration          // OllamaConfiguration(baseURL:model:) to store
/// ```
///
/// It is `@MainActor` because the two things that drive it — the onboarding
/// window and the Settings pane — are, and because a state machine whose whole
/// job is to move labels has no business being reentrant.
@MainActor
public final class OllamaSetupModel {

    // MARK: - State

    /// Where the field's text is in its life cycle.
    public enum Phase: Equatable, Sendable {
        case idle
        case testing
        /// The daemon answered and the selected tag is one it has.
        case connected(model: String)
        case failed(Failure)
    }

    /// Why a test did not connect. Content-free by construction (NFR-4): a
    /// model tag and a URL are configuration, never note text.
    public enum Failure: Equatable, Sendable {
        /// Plaintext `http` to something that is not this machine, or not a URL.
        case badURL
        /// Nothing is listening — almost always "the daemon is not running".
        case daemonUnreachable
        /// The daemon is up but has never pulled this tag.
        case modelNotPulled(String)
        case other(String)

        /// The sentence the card shows, with the command that fixes it.
        public var message: String {
            switch self {
            case .badURL:
                return "That address will not work. Use http://localhost:11434, "
                    + "or https:// for a daemon on another machine."
            case .daemonUnreachable:
                return "Ollama isn’t running. Start it with `ollama serve`."
            case let .modelNotPulled(tag):
                return "\(tag) isn’t pulled yet. Run `ollama pull \(tag)`."
            case let .other(message):
                return message
            }
        }
    }

    /// Ollama's own default, pre-filled into the field.
    public static let defaultBaseURLText = OllamaConfiguration.defaultBaseURL.absoluteString

    public private(set) var phase: Phase = .idle
    /// Tags `GET /api/tags` reported, in the order the daemon listed them.
    public private(set) var availableModels: [String] = []
    /// What the field holds. Editing it drops back to ``Phase/idle``.
    public private(set) var baseURLText: String
    /// The tag the popup is showing.
    public private(set) var selectedModel: String

    private let validator: any OllamaValidating

    /// Called whenever anything above moved, so an AppKit card can redraw.
    public var onChange: (() -> Void)?

    public init(
        baseURL: URL = OllamaConfiguration.defaultBaseURL,
        model: AIModel = OllamaConfiguration.defaultModel,
        validator: any OllamaValidating = LiveOllamaValidator()
    ) {
        baseURLText = baseURL.absoluteString
        selectedModel = model.id
        self.validator = validator
    }

    // MARK: - Derived

    /// The typed address, when it is one Filaway will talk to.
    ///
    /// `nil` covers both "not a URL" and NFR-4's loopback rule: plaintext to
    /// another machine would quietly undo the privacy argument for running
    /// locally, so it is not offered as a choice at all.
    public var baseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil,
              OllamaConfiguration.isValidBaseURL(url)
        else { return nil }
        return url
    }

    public var canTest: Bool { phase != .testing && baseURL != nil }

    public var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// What to store when the flow finishes. `nil` until it has connected —
    /// writing an unverified daemon address would make the AI pane lie.
    public var configuration: OllamaConfiguration? {
        guard case let .connected(model) = phase, let baseURL else { return nil }
        return OllamaConfiguration(baseURL: baseURL, model: AIModel(model))
    }

    /// The status line under the Test button.
    public var statusMessage: String {
        switch phase {
        case .idle: return ""
        case .testing: return "Looking for Ollama…"
        case let .connected(model): return "Connected · \(model)"
        case let .failed(failure): return failure.message
        }
    }

    // MARK: - Inputs

    /// The base-URL field changed. A rejection never argues with what is now in
    /// the field, so any phase but `testing` falls back to `idle`.
    public func urlEdited(_ text: String) {
        baseURLText = text
        guard phase != .testing else { return }
        phase = .idle
        availableModels = []
        changed()
    }

    /// The model popup changed. A different tag is a different question, so the
    /// last answer stops applying.
    public func selectModel(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedModel else { return }
        selectedModel = trimmed
        if phase != .testing { phase = .idle }
        changed()
    }

    /// Refresh: ask the daemon what it has, without judging the selection.
    ///
    /// Kept separate from ``test()`` because the popup has to be fillable
    /// *before* the user has chosen anything worth testing.
    @discardableResult
    public func refreshModels() async -> [String] {
        guard let baseURL else {
            phase = .failed(.badURL)
            changed()
            return []
        }
        phase = .testing
        changed()
        do {
            let models = try await validator.models(at: baseURL)
            availableModels = models.map(\.id)
            // A daemon with exactly one model is the common case on a machine
            // set up for this; adopting it saves a menu interaction.
            if !availableModels.contains(selectedModel), let first = availableModels.first {
                selectedModel = first
            }
            phase = .idle
            changed()
            return availableModels
        } catch {
            phase = .failed(Self.failure(for: error))
            availableModels = []
            changed()
            return []
        }
    }

    /// Test connection: the daemon answers *and* it has the selected tag.
    public func test() async {
        guard let baseURL else {
            phase = .failed(.badURL)
            changed()
            return
        }
        phase = .testing
        changed()
        do {
            let models = try await validator.models(at: baseURL)
            availableModels = models.map(\.id)
            if !availableModels.contains(selectedModel) {
                // An empty daemon and a daemon missing *this* tag are the same
                // fix — pull it — so they say the same thing.
                phase = .failed(.modelNotPulled(selectedModel))
            } else {
                phase = .connected(model: selectedModel)
            }
        } catch {
            phase = .failed(Self.failure(for: error))
            availableModels = []
        }
        changed()
    }

    /// Maps a provider failure onto the sentence with the command in it.
    static func failure(for error: any Error) -> Failure {
        guard let aiError = error as? AIError else {
            return .other("Could not reach Ollama.")
        }
        switch aiError {
        case .network, .timedOut:
            return .daemonUnreachable
        case let .modelNotFound(model, _):
            return .modelNotPulled(model)
        default:
            return .other(aiError.description)
        }
    }

    private func changed() { onChange?() }
}

/// "What has this daemon got?", behind a protocol so the onboarding flow can be
/// driven with no network (the `onboarding-ollama` smoke phase, and every test).
public protocol OllamaValidating: Sendable {
    func models(at baseURL: URL) async throws -> [AIModelInfo]
}

/// The real one: `GET /api/tags` through ``OllamaProvider``.
public struct LiveOllamaValidator: OllamaValidating {
    public init() {}

    public func models(at baseURL: URL) async throws -> [AIModelInfo] {
        // `OllamaProvider.init` makes the loopback rule a precondition; the
        // caller has already filtered, but a crash here would be a poor way to
        // report a typo, so it is checked rather than assumed.
        guard OllamaConfiguration.isValidBaseURL(baseURL) else {
            throw AIError.badRequest(message: "plaintext http is allowed only to loopback")
        }
        let provider = OllamaProvider(configuration: OllamaConfiguration(baseURL: baseURL))
        return try await provider.validateKey()
    }
}

/// A scripted daemon, for tests and the smoke phase.
public struct StubOllamaValidator: OllamaValidating {
    public let models: [AIModelInfo]
    public let failure: AIError?

    public init(models: [String] = [AIModel.defaultOllama.id], failure: AIError? = nil) {
        self.models = models.map { AIModelInfo(id: $0, displayName: $0) }
        self.failure = failure
    }

    public func models(at baseURL: URL) async throws -> [AIModelInfo] {
        if let failure { throw failure }
        return models
    }
}
