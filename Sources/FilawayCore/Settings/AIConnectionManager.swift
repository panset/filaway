import Foundation

/// Owns the AI connection as Settings and onboarding see it (FR-6.1, FR-6.2,
/// FR-6.4, FR-6.5, FR-6.6): the secret store, the provider, the health state and
/// the model list — for **either** backend.
///
/// An actor because three call sites race for it — the Settings sheet, the
/// onboarding step and whatever pipeline just got a rate-limit back — and all
/// three mutate the same health state.
///
/// ### Two kinds of "connected" (P2-02, ADR-068)
///
/// * **Claude** — a credential. The key is **only** written after
///   `validateKey()` succeeds, so the stored credential is always one that
///   worked at least once (FR-6.1). Validation is `GET /v1/models`, which is
///   free (plan §1 amendment 4).
/// * **Ollama** — no credential at all. Validation is `GET /api/tags`: the
///   daemon answering is necessary but not sufficient, because a daemon with
///   nothing pulled cannot serve the configured model. So *connected* means
///   **the daemon answered and the model is in the list**; a reachable daemon
///   missing the model is `.error(AIConnectionCopy.modelNotPulled)`, whose
///   remedy is `ollama pull <model>`, and an unreachable one is `.offline`.
///
/// **The Keychain is never touched by the local path.** Switching to Ollama
/// leaves the stored key alone and switching back re-validates it, so a user can
/// try the local model without losing their key.
///
/// ```swift
/// let manager = AIConnectionManager(library: library)
/// await manager.refresh()                      // whichever provider is selected
/// switch await manager.connect(apiKey: typed) {
/// case let .success(models): …                 // key stored, status .connected
/// case let .failure(error):  …                 // nothing stored
/// }
/// _ = manager.setProvider(.ollama, ollama: settings.ollamaConfiguration)
/// await manager.connectLocal()                 // GET /api/tags + model presence
/// ```
public actor AIConnectionManager {

    /// What a provider has to be built from: the credential source (Claude) and
    /// where the daemon is (Ollama).
    public struct ProviderContext: Sendable {
        public var keySource: APIKeySource
        public var kind: AIProviderKind
        public var ollama: OllamaConfiguration

        public init(
            keySource: APIKeySource,
            kind: AIProviderKind = .claude,
            ollama: OllamaConfiguration = OllamaConfiguration()
        ) {
            self.keySource = keySource
            self.kind = kind
            self.ollama = ollama
        }
    }

    /// Builds the provider used for one validation. Injected so tests and the
    /// smoke driver can hand in a ``MockProvider`` without a network, a key or a
    /// daemon.
    public typealias ProviderFactory = @Sendable (ProviderContext) throws -> any AIProvider

    private let secrets: any SecretStore
    private let makeProvider: ProviderFactory
    private let ledger: AIUsageLedger?

    private var kind: AIProviderKind
    private var ollama: OllamaConfiguration
    /// The local model that was last seen in `GET /api/tags`. The keyless
    /// equivalent of ``hasStoredKey``: it says the configuration has been
    /// checked once, not that the daemon is up right now.
    private var validatedLocalModel: AIModel?

    private var health: AIHealth
    private var cachedModels: [AIModelInfo] = []
    private var continuations: [UUID: AsyncStream<AIStatus>.Continuation] = [:]

    // MARK: - Construction

    /// - Parameters:
    ///   - secrets: where the key lives. ``KeychainStore`` in the app,
    ///     ``InMemorySecretStore`` in tests and smoke runs.
    ///   - ledger: monthly usage for FR-6.6's line. `nil` hides the line.
    ///   - kind: which backend is selected (`AppSettings.aiProvider`).
    ///   - ollama: where the local daemon is (`AppSettings.ollamaConfiguration`).
    ///   - providerFactory: defaults to ``AIProviderFactory`` under the current
    ///     `FILAWAY_AI_MODE`.
    public init(
        secrets: any SecretStore = KeychainStore(),
        ledger: AIUsageLedger? = nil,
        kind: AIProviderKind = .claude,
        ollama: OllamaConfiguration = OllamaConfiguration(),
        providerFactory: ProviderFactory? = nil
    ) {
        self.secrets = secrets
        self.ledger = ledger
        self.kind = kind
        self.ollama = ollama
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
        { context in
            // `validateKey()` answers with the known model ids; an actual
            // completion still fails loudly rather than pretending to work.
            if mode == .replay, store == nil {
                return MockProvider { _ in throw AIError.notConfigured }
            }
            return try AIProviderFactory.make(
                mode: mode,
                store: store,
                keySource: context.keySource,
                kind: context.kind,
                ollama: context.ollama
            )
        }
    }

    // MARK: - State

    /// The status the pill shows, with an expired rate limit already resolved.
    public var status: AIStatus { health.status() }

    /// Which backend `refresh()` checks and the rest of the app talks to.
    public var providerKind: AIProviderKind { kind }

    /// Where the local daemon is, and which model it is asked for.
    public var ollamaConfiguration: OllamaConfiguration { ollama }

    /// Models the last successful validation reported — `/v1/models` for Claude
    /// (FR-6.2's advanced override list), `/api/tags` for Ollama (the model
    /// picker). Empty until a validation succeeds.
    public var models: [AIModelInfo] { cachedModels }

    /// `true` when a Claude credential is on file. Does not prove it still
    /// works, and is **unaffected by the provider selection** — the local path
    /// never reads, writes or deletes it.
    public var hasStoredKey: Bool { (try? secrets.apiKey())?.isEmpty == false }

    /// `true` when the *selected* provider has everything it needs: a key for
    /// Claude, a model that has been seen in `/api/tags` for Ollama.
    ///
    /// Like ``hasStoredKey``, this is about configuration, not reachability — a
    /// daemon that is currently down is still configured.
    public var isConfigured: Bool {
        switch kind {
        case .claude: return hasStoredKey
        case .ollama: return validatedLocalModel.map { OllamaConfiguration.normalizedTag($0.id) }
            == OllamaConfiguration.normalizedTag(ollama.model.id)
        }
    }

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

    // MARK: - Choosing a provider (FR-6.5)

    /// Points the manager at a backend, or moves the local daemon.
    ///
    /// Deliberately synchronous and deliberately *not* a validation: it drops
    /// what the old provider cached and resets the status, and the caller
    /// follows with ``refresh()`` (Settings does this on every
    /// `aiProvider` / `ollamaBaseURL` / `ollamaModel` change). Nothing is
    /// re-checked when the selection has not actually moved, so a settings
    /// observer can call it on every notification without generating traffic.
    ///
    /// - Returns: `true` when something changed and a ``refresh()`` is owed.
    @discardableResult
    public func setProvider(
        _ newKind: AIProviderKind,
        ollama newOllama: OllamaConfiguration = OllamaConfiguration()
    ) -> Bool {
        guard newKind != kind || newOllama != ollama else { return false }
        // The model tag moving invalidates "this model exists"; the base URL
        // moving invalidates it too, because it is a different daemon.
        if newOllama != ollama { validatedLocalModel = nil }
        kind = newKind
        ollama = newOllama
        cachedModels = []
        health = AIHealth(status: .notConfigured, updatedAt: Date())
        publish()
        Log.ai.info("AI provider selected: \(newKind.rawValue, privacy: .public)")
        return true
    }

    // MARK: - Connecting

    /// Validates `apiKey` against **Claude** and, only on success, stores it in
    /// the Keychain.
    ///
    /// A blank key never reaches the network. On failure nothing is written and
    /// any previously stored key is left alone — a typo in the Change… sheet
    /// must not disconnect a working install.
    ///
    /// The key sheet is a Claude control, so this validates against Claude even
    /// while Ollama is the selected provider; in that case the local status is
    /// left exactly as it was, because a key has nothing to do with it.
    @discardableResult
    public func connect(apiKey: String) async -> Result<[AIModelInfo], AIError> {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if kind == .claude {
                health.recordFailure(.invalidKey())
                publish()
            }
            return .failure(.invalidKey())
        }
        return await validate(
            context: ProviderContext(keySource: .fixed(trimmed), kind: .claude, ollama: ollama),
            persisting: trimmed,
            affectsStatus: kind == .claude
        )
    }

    /// Re-checks whatever provider is selected — called when Settings opens and
    /// after a failure, so the pill is never stale.
    @discardableResult
    public func refresh() async -> Result<[AIModelInfo], AIError> {
        switch kind {
        case .ollama:
            return await connectLocal()
        case .claude:
            guard let stored = try? secrets.apiKey(), !stored.isEmpty else {
                cachedModels = []
                health = AIHealth(status: .notConfigured, updatedAt: Date())
                publish()
                return .failure(.notConfigured)
            }
            return await validate(
                context: ProviderContext(keySource: .fixed(stored), kind: .claude, ollama: ollama),
                persisting: nil,
                affectsStatus: true
            )
        }
    }

    /// The keyless connection check: is the daemon up, and has the configured
    /// model been pulled? (FR-6.5, ADR-068.)
    ///
    /// Settings' **Test connection** button, and what ``refresh()`` does when
    /// Ollama is selected. Nothing here reads or writes the Keychain.
    @discardableResult
    public func connectLocal() async -> Result<[AIModelInfo], AIError> {
        // Ask before building: `OllamaProvider.init` turns an unsafe base URL
        // into a `precondition`, and Settings can hold one at any moment while
        // the user is typing.
        guard ollama.validate() else {
            validatedLocalModel = nil
            cachedModels = []
            health.record(status: .error(AIConnectionCopy.invalidBaseURL))
            publish()
            return .failure(.badRequest(message: AIConnectionCopy.baseURLHint))
        }

        let provider: any AIProvider
        do {
            provider = try makeProvider(ProviderContext(keySource: .none, kind: .ollama, ollama: ollama))
        } catch {
            return failLocal(with: error)
        }

        do {
            let models = try await provider.validateKey()
            cachedModels = models.sorted { $0.id < $1.id }
            guard ollama.isPulled(in: models) else {
                validatedLocalModel = nil
                health.record(status: .error(AIConnectionCopy.modelNotPulled))
                publish()
                Log.ai.notice("Ollama reachable, model not pulled (\(models.count, privacy: .public) available)")
                return .failure(.modelNotFound(model: ollama.model.id, message: AIConnectionCopy.modelNotPulled))
            }
            validatedLocalModel = ollama.model
            health.recordSuccess()
            publish()
            Log.ai.info("Ollama connected: \(models.count, privacy: .public) models pulled")
            return .success(cachedModels)
        } catch {
            return failLocal(with: error)
        }
    }

    /// A local failure never clears ``validatedLocalModel``: a daemon that is
    /// temporarily down is still configured, exactly as a stored key survives an
    /// outage.
    private func failLocal(with error: any Error) -> Result<[AIModelInfo], AIError> {
        let wrapped = (error as? AIError) ?? .malformedResponse(error.localizedDescription)
        cachedModels = []
        health.recordFailure(wrapped)
        publish()
        Log.ai.notice("Ollama connection failed: \(wrapped.logLabel, privacy: .public)")
        return .failure(wrapped)
    }

    private func validate(
        context: ProviderContext,
        persisting key: String?,
        affectsStatus: Bool
    ) async -> Result<[AIModelInfo], AIError> {
        func fail(_ error: AIError) -> Result<[AIModelInfo], AIError> {
            if affectsStatus {
                health.recordFailure(error)
                publish()
            }
            return .failure(error)
        }

        let provider: any AIProvider
        do {
            provider = try makeProvider(context)
        } catch let error as AIError {
            return fail(error)
        } catch {
            return fail(.malformedResponse(error.localizedDescription))
        }

        do {
            let models = try await provider.validateKey()
            if let key {
                do {
                    try secrets.setAPIKey(key)
                } catch {
                    return fail(.malformedResponse("The key could not be saved to the Keychain."))
                }
            }
            let sorted = models.sorted { $0.id < $1.id }
            if affectsStatus {
                cachedModels = sorted
                health.recordSuccess()
                publish()
            }
            Log.ai.info("AI connection validated: \(models.count, privacy: .public) models")
            return .success(sorted)
        } catch let error as AIError {
            Log.ai.notice("AI connection failed: \(error.logLabel, privacy: .public)")
            return fail(error)
        } catch {
            return fail(.malformedResponse(error.localizedDescription))
        }
    }

    /// Removes the stored Claude key. Idempotent; everything AI-powered
    /// degrades per FR-6.4 rather than failing.
    ///
    /// Under Ollama the local status is left alone — the key was not what was
    /// connecting it.
    public func disconnect() {
        try? secrets.deleteAPIKey()
        guard kind == .claude else { return }
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

    /// This calendar month's requests and tokens **for the selected provider**,
    /// or `nil` when no ledger is attached. Local traffic is counted and costs
    /// nothing; how much work went local is the FR-6.5 number worth having.
    public func monthlyUsage(now: Date = Date()) async -> AIUsageTotals? {
        guard let ledger else { return nil }
        return try? await ledger.monthlyTotals(containing: now, provider: kind)
    }

    /// The same numbers split by purpose, for the Settings detail line.
    public func monthlyUsageByPurpose(now: Date = Date()) async -> [AIPurpose: AIUsageTotals]? {
        guard let ledger else { return nil }
        return try? await ledger.monthlyTotalsByPurpose(containing: now, provider: kind)
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
