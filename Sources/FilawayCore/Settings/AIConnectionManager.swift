import Foundation

/// Owns the Claude connection as Settings and onboarding see it (FR-6.1, FR-6.2,
/// FR-6.4, FR-6.6): the secret store, the provider, the health state and the
/// model list.
///
/// An actor because three call sites race for it — the Settings sheet, the
/// onboarding step and whatever pipeline just got a rate-limit back — and all
/// three mutate the same health state.
///
/// The key is **only** written after `validateKey()` succeeds: a rejected key
/// never reaches the Keychain, so the stored credential is always one that
/// worked at least once (FR-6.1). Validation is `GET /v1/models`, which is free
/// (plan §1 amendment 4).
///
/// ```swift
/// let manager = AIConnectionManager(library: library)
/// await manager.refresh()                      // status from the stored key
/// switch await manager.connect(apiKey: typed) {
/// case let .success(models): …                 // key stored, status .connected
/// case let .failure(error):  …                 // nothing stored
/// }
/// ```
public actor AIConnectionManager {

    /// Builds the provider used for one credential. Injected so tests and the
    /// smoke driver can hand in a ``MockProvider`` without a network or a key.
    public typealias ProviderFactory = @Sendable (APIKeySource) throws -> any AIProvider

    private let secrets: any SecretStore
    private let makeProvider: ProviderFactory
    private let ledger: AIUsageLedger?

    private var health: AIHealth
    private var cachedModels: [AIModelInfo] = []
    private var continuations: [UUID: AsyncStream<AIStatus>.Continuation] = [:]

    // MARK: - Construction

    /// - Parameters:
    ///   - secrets: where the key lives. ``KeychainStore`` in the app,
    ///     ``InMemorySecretStore`` in tests and smoke runs.
    ///   - ledger: monthly usage for FR-6.6's line. `nil` hides the line.
    ///   - providerFactory: defaults to ``AIProviderFactory`` under the current
    ///     `FILAWAY_AI_MODE`.
    public init(
        secrets: any SecretStore = KeychainStore(),
        ledger: AIUsageLedger? = nil,
        providerFactory: ProviderFactory? = nil
    ) {
        self.secrets = secrets
        self.ledger = ledger
        makeProvider = providerFactory ?? AIConnectionManager.defaultProviderFactory()
        health = AIHealth(status: .notConfigured)
    }

    /// Convenience for the app: the library's usage ledger, opened if it can be.
    public init(library: Library, secrets: any SecretStore = KeychainStore()) {
        self.init(secrets: secrets, ledger: try? AIUsageLedger(library: library))
    }

    /// The provider builder the app uses: whatever `FILAWAY_AI_MODE` asks for.
    ///
    /// In `replay` with no fixture directory — which is every normal launch of
    /// the shipped app under a test harness — a ``MockProvider`` stands in, so
    /// Settings and onboarding stay exercisable offline instead of throwing.
    public static func defaultProviderFactory(
        mode: AIMode = AIMode.current(),
        store: AIRecordingStore? = AIRecordingStore.fromEnvironment()
    ) -> ProviderFactory {
        { keySource in
            // `validateKey()` answers with the known model ids; an actual
            // completion still fails loudly rather than pretending to work.
            if mode == .replay, store == nil {
                return MockProvider { _ in throw AIError.notConfigured }
            }
            return try AIProviderFactory.make(mode: mode, store: store, keySource: keySource)
        }
    }

    // MARK: - State

    /// The status the pill shows, with an expired rate limit already resolved.
    public var status: AIStatus { health.status() }

    /// Models the last successful validation reported (FR-6.2's advanced
    /// override list). Empty until a key validates; the UI falls back to
    /// ``AIModel/known``.
    public var models: [AIModelInfo] { cachedModels }

    /// `true` when a credential is on file. Does not prove it still works.
    public var hasStoredKey: Bool { (try? secrets.apiKey())?.isEmpty == false }

    /// Every subsequent status change. One stream per subscriber.
    public func statusChanges() -> AsyncStream<AIStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AIStatus>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(health.status())
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func publish() {
        let current = health.status()
        for continuation in continuations.values { continuation.yield(current) }
    }

    // MARK: - Connecting

    /// Validates `apiKey` and, only on success, stores it in the Keychain.
    ///
    /// A blank key never reaches the network. On failure nothing is written and
    /// any previously stored key is left alone — a typo in the Change… sheet
    /// must not disconnect a working install.
    @discardableResult
    public func connect(apiKey: String) async -> Result<[AIModelInfo], AIError> {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            health.recordFailure(.invalidKey())
            publish()
            return .failure(.invalidKey())
        }
        return await validate(using: .fixed(trimmed), persisting: trimmed)
    }

    /// Re-checks the stored key — called when Settings opens and after a
    /// failure, so the pill is never stale.
    @discardableResult
    public func refresh() async -> Result<[AIModelInfo], AIError> {
        guard let stored = try? secrets.apiKey(), !stored.isEmpty else {
            cachedModels = []
            health = AIHealth(status: .notConfigured, updatedAt: Date())
            publish()
            return .failure(.notConfigured)
        }
        return await validate(using: .fixed(stored), persisting: nil)
    }

    private func validate(
        using keySource: APIKeySource,
        persisting key: String?
    ) async -> Result<[AIModelInfo], AIError> {
        let provider: any AIProvider
        do {
            provider = try makeProvider(keySource)
        } catch let error as AIError {
            health.recordFailure(error)
            publish()
            return .failure(error)
        } catch {
            let wrapped = AIError.malformedResponse(error.localizedDescription)
            health.recordFailure(wrapped)
            publish()
            return .failure(wrapped)
        }

        do {
            let models = try await provider.validateKey()
            if let key {
                do {
                    try secrets.setAPIKey(key)
                } catch {
                    let wrapped = AIError.malformedResponse("The key could not be saved to the Keychain.")
                    health.recordFailure(wrapped)
                    publish()
                    return .failure(wrapped)
                }
            }
            cachedModels = models.sorted { $0.id < $1.id }
            health.recordSuccess()
            publish()
            Log.ai.info("AI connection validated: \(models.count, privacy: .public) models")
            return .success(cachedModels)
        } catch let error as AIError {
            health.recordFailure(error)
            publish()
            Log.ai.notice("AI connection failed: \(error.logLabel, privacy: .public)")
            return .failure(error)
        } catch {
            let wrapped = AIError.malformedResponse(error.localizedDescription)
            health.recordFailure(wrapped)
            publish()
            return .failure(wrapped)
        }
    }

    /// Removes the stored key. Idempotent; the status drops to
    /// ``AIStatus/notConfigured`` and everything AI-powered degrades per FR-6.4
    /// rather than failing.
    public func disconnect() {
        try? secrets.deleteAPIKey()
        cachedModels = []
        health = AIHealth(status: .notConfigured, updatedAt: Date())
        publish()
    }

    // MARK: - Health feedback from the rest of the app

    /// Folds a pipeline failure into the status the pill shows (FR-6.4).
    public func recordFailure(_ error: AIError) {
        health.recordFailure(error)
        publish()
    }

    /// Folds a successful request into the status.
    public func recordSuccess() {
        health.recordSuccess()
        publish()
    }

    /// Consecutive retryable failures — the backoff input for the organize queue.
    public var consecutiveFailures: Int { health.consecutiveFailures }

    // MARK: - Usage (FR-6.6)

    /// This calendar month's billed requests and tokens, or `nil` when no ledger
    /// is attached.
    public func monthlyUsage(now: Date = Date()) async -> AIUsageTotals? {
        guard let ledger else { return nil }
        return try? await ledger.monthlyTotals(containing: now)
    }

    /// The same numbers split by purpose, for the Settings detail line.
    public func monthlyUsageByPurpose(now: Date = Date()) async -> [AIPurpose: AIUsageTotals]? {
        guard let ledger else { return nil }
        return try? await ledger.monthlyTotalsByPurpose(containing: now)
    }
}

extension AIError {
    /// The case name and nothing else — safe to log at `.public` (NFR-4). The
    /// `description` may quote an API message, so it never reaches `Logger`.
    var logLabel: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .invalidKey: return "invalidKey"
        case .rateLimited: return "rateLimited"
        case .badRequest: return "badRequest"
        case .modelNotFound: return "modelNotFound"
        case .serverOverloaded: return "serverOverloaded"
        case .network: return "network"
        case .malformedResponse: return "malformedResponse"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .missingRecording: return "missingRecording"
        }
    }
}
