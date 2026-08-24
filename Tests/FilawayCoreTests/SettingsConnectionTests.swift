import Foundation
import Testing

@testable import FilawayCore

@Suite("Settings — AI connection manager (FR-6.1, FR-6.2, FR-6.4)")
struct AIConnectionManagerTests {

    private static let models = [
        AIModelInfo(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        AIModelInfo(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
    ]

    private func manager(
        secrets: InMemorySecretStore,
        provider: @escaping @Sendable () throws -> any AIProvider
    ) -> AIConnectionManager {
        AIConnectionManager(secrets: secrets, ledger: nil, providerFactory: { _ in try provider() })
    }

    @Test("a fresh install is notConfigured until a key validates")
    func startsNotConfigured() async {
        let secrets = InMemorySecretStore()
        let manager = manager(secrets: secrets) { MockProvider(models: Self.models) { _ in .text("") } }

        #expect(await manager.status == .notConfigured)
        #expect(await manager.hasStoredKey == false)
        #expect(await manager.models.isEmpty)

        let refreshed = await manager.refresh()
        #expect(refreshed == .failure(.notConfigured), "no key means no call")
        #expect(await manager.status == .notConfigured)
    }

    @Test("a valid key is stored in the secret store and flips the status")
    func connectStoresKey() async throws {
        let secrets = InMemorySecretStore()
        let manager = manager(secrets: secrets) { MockProvider(models: Self.models) { _ in .text("") } }

        let result = await manager.connect(apiKey: "  sk-ant-good\n")
        #expect(result == .success(Self.models.sorted { $0.id < $1.id }))
        #expect(await manager.status == .connected)
        #expect(await manager.hasStoredKey)
        #expect(try secrets.apiKey() == "sk-ant-good", "the key is trimmed before it is stored")
        #expect(await manager.models.count == 2)
    }

    @Test("a rejected key is never written, and a working key survives the typo")
    func rejectedKeyIsNotStored() async throws {
        let secrets = InMemorySecretStore(apiKey: "sk-ant-already-good")
        let manager = manager(secrets: secrets) { MockProvider.failing(.invalidKey(message: "bad key")) }

        let result = await manager.connect(apiKey: "sk-ant-typo")
        #expect(result == .failure(.invalidKey(message: "bad key")))
        #expect(await manager.status == .invalidKey)
        #expect(try secrets.apiKey() == "sk-ant-already-good", "a failed validation must not clobber the stored key")
    }

    @Test("a blank key short-circuits without reaching the provider")
    func blankKey() async {
        let secrets = InMemorySecretStore()
        let reached = Locked(false)
        let manager = manager(secrets: secrets) {
            reached.mutate { $0 = true }
            return MockProvider(models: Self.models) { _ in .text("") }
        }

        let result = await manager.connect(apiKey: "   ")
        #expect(result == .failure(.invalidKey()))
        #expect(reached.value == false)
        #expect((try? secrets.apiKey()) == .some(nil))
    }

    @Test("network trouble reads as offline, not as a bad key (FR-6.4)")
    func offlineDegradation() async throws {
        let secrets = InMemorySecretStore(apiKey: "sk-ant-good")
        let manager = manager(secrets: secrets) {
            MockProvider.failing(.network(code: -1009, description: "offline"))
        }

        _ = await manager.refresh()
        #expect(await manager.status == .offline)
        #expect(try secrets.apiKey() == "sk-ant-good", "going offline never removes the key")
    }

    @Test("a rate limit heals itself once its deadline passes")
    func rateLimitHeals() async {
        let manager = manager(secrets: InMemorySecretStore()) { MockProvider(models: Self.models) { _ in .text("") } }

        await manager.recordFailure(.rateLimited(retryAfter: -1))
        #expect(await manager.status == .connected, "an expired limit is not a limit")

        await manager.recordFailure(.rateLimited(retryAfter: 600))
        if case .rateLimited = await manager.status {} else {
            Issue.record("expected .rateLimited, got \(await manager.status)")
        }
        #expect(await manager.consecutiveFailures == 2)

        await manager.recordSuccess()
        #expect(await manager.status == .connected)
        #expect(await manager.consecutiveFailures == 0)
    }

    @Test("disconnect removes the key and the cached models")
    func disconnect() async throws {
        let secrets = InMemorySecretStore()
        let manager = manager(secrets: secrets) { MockProvider(models: Self.models) { _ in .text("") } }

        _ = await manager.connect(apiKey: "sk-ant-good")
        await manager.disconnect()

        #expect(await manager.status == .notConfigured)
        #expect(await manager.models.isEmpty)
        #expect(try secrets.apiKey() == nil)
        await manager.disconnect()  // idempotent
        #expect(await manager.status == .notConfigured)
    }

    @Test("the status stream carries the transitions the pill draws")
    func statusStream() async {
        let manager = manager(secrets: InMemorySecretStore()) { MockProvider(models: Self.models) { _ in .text("") } }
        var iterator = await manager.statusChanges().makeAsyncIterator()

        #expect(await iterator.next() == .notConfigured, "a new subscriber is given the current status")

        _ = await manager.connect(apiKey: "sk-ant-good")
        #expect(await iterator.next() == .connected)

        await manager.disconnect()
        #expect(await iterator.next() == .notConfigured)
    }

    @Test("a provider that cannot even be built surfaces as a failure, not a crash")
    func providerConstructionFailure() async {
        let manager = AIConnectionManager(secrets: InMemorySecretStore(), ledger: nil) { _ in
            throw AIError.malformedResponse("replay mode needs a fixture directory")
        }
        let result = await manager.connect(apiKey: "sk-ant-good")
        #expect(result == .failure(.malformedResponse("replay mode needs a fixture directory")))
    }

    @Test("monthly usage comes from the ledger (FR-6.6)")
    func monthlyUsage() async throws {
        let ledger = try AIUsageLedger(inMemory: true)
        try await ledger.record(AIUsageRecord(
            model: AIModel.sonnet5.id,
            purpose: .organize,
            usage: AIUsage(inputTokens: 1_200, outputTokens: 300)
        ))
        try await ledger.record(AIUsageRecord(
            model: AIModel.haiku45.id,
            purpose: .search,
            usage: AIUsage(inputTokens: 400, outputTokens: 100)
        ))
        // Replayed traffic costs nothing and must not inflate the line.
        try await ledger.record(AIUsageRecord(
            model: AIModel.sonnet5.id,
            purpose: .organize,
            usage: AIUsage(inputTokens: 9_999, outputTokens: 9_999),
            provider: "replay"
        ))

        let manager = AIConnectionManager(
            secrets: InMemorySecretStore(),
            ledger: ledger,
            providerFactory: { _ in MockProvider(models: Self.models) { _ in .text("") } }
        )

        let totals = await manager.monthlyUsage()
        #expect(totals?.requests == 2)
        #expect(totals?.totalTokens == 2_000)

        let split = await manager.monthlyUsageByPurpose()
        #expect(split?[.organize]?.requests == 1)
        #expect(split?[.search]?.requests == 1)
    }

    @Test("with no ledger attached the usage line is simply absent")
    func noLedger() async {
        let manager = manager(secrets: InMemorySecretStore()) { MockProvider(models: Self.models) { _ in .text("") } }
        #expect(await manager.monthlyUsage() == nil)
    }

    @Test("the app's default factory falls back to a mock when replay has no fixtures")
    func replayFallback() async throws {
        let factory = AIConnectionManager.defaultProviderFactory(mode: .replay, store: nil)
        for kind in AIProviderKind.allCases {
            let provider = try factory(AIConnectionManager.ProviderContext(keySource: .none, kind: kind))
            #expect(provider.identifier == "mock")
            #expect(try await provider.validateKey().count == AIModel.known.count)
        }
    }
}

// MARK: - The keyless provider (P2-02, FR-6.5, ADR-068)

@Suite("Settings — keyless Ollama connection (FR-6.5, FR-6.4)")
struct AIConnectionManagerOllamaTests {

    private static let tags = [
        AIModelInfo(id: "llama3.1:8b", displayName: "llama3.1:8b"),
        AIModelInfo(id: "qwen2.5-coder:7b", displayName: "qwen2.5-coder:7b"),
    ]

    /// A manager wired to a scripted `/api/tags`, with the kind the factory was
    /// asked for recorded so a test can prove the local path never builds a
    /// Claude provider.
    private func manager(
        secrets: InMemorySecretStore = InMemorySecretStore(),
        kind: AIProviderKind = .ollama,
        ollama: OllamaConfiguration = OllamaConfiguration(),
        seen: Locked<[AIProviderKind]>? = nil,
        provider: @escaping @Sendable (AIConnectionManager.ProviderContext) throws -> any AIProvider
    ) -> AIConnectionManager {
        AIConnectionManager(secrets: secrets, ledger: nil, kind: kind, ollama: ollama) { context in
            seen?.mutate { $0.append(context.kind) }
            return try provider(context)
        }
    }

    /// A stand-in for `GET /api/tags`: `validateKey()` answers, `complete` does not.
    private func tagsProvider(_ models: [AIModelInfo] = tags) -> any AIProvider {
        MockProvider(identifier: "ollama", models: models) { _ in throw AIError.notConfigured }
    }

    @Test("a reachable daemon with the model pulled is connected")
    func connected() async {
        let manager = manager { _ in self.tagsProvider() }

        let result = await manager.connectLocal()
        #expect(result == .success(Self.tags.sorted { $0.id < $1.id }))
        #expect(await manager.status == .connected)
        #expect(await manager.isConfigured)
        #expect(await manager.models.count == 2, "the tag list feeds the model picker")
        #expect(
            AIConnectionCopy.statusLine(kind: .ollama, status: .connected, model: .defaultOllama)
                == "Connected · llama3.1:8b · fully private"
        )
    }

    @Test("a reachable daemon missing the model says how to pull it")
    func modelNotPulled() async {
        let manager = manager { _ in
            self.tagsProvider([AIModelInfo(id: "qwen2.5-coder:7b", displayName: "qwen")])
        }

        let result = await manager.connectLocal()
        #expect(result == .failure(.modelNotFound(model: "llama3.1:8b", message: AIConnectionCopy.modelNotPulled)))
        #expect(await manager.status == .error(AIConnectionCopy.modelNotPulled))
        #expect(await manager.isConfigured == false, "a model that is not there is not configured")
        #expect(await manager.models.count == 1, "what *is* pulled still populates the picker")
        let line = AIConnectionCopy.statusLine(
            kind: .ollama, status: await manager.status, model: .defaultOllama
        )
        #expect(line == "Model not pulled — run: ollama pull llama3.1:8b")
    }

    @Test("a daemon that is not running reads as offline, not as a bad key")
    func daemonDown() async {
        let manager = manager { _ in MockProvider.failing(.network(code: -1004, description: "refused")) }

        let result = await manager.connectLocal()
        #expect(result == .failure(.network(code: -1004, description: "refused")))
        #expect(await manager.status == .offline)
        #expect(
            AIConnectionCopy.statusLine(kind: .ollama, status: .offline, model: .defaultOllama)
                == "Ollama offline — is the daemon running? (ollama serve)"
        )
    }

    @Test("an outage does not un-configure a daemon that answered once")
    func outageKeepsConfiguration() async {
        let fail = Locked(false)
        let manager = manager { _ in
            fail.value
                ? MockProvider.failing(.network(code: -1004, description: "refused"))
                : self.tagsProvider()
        }

        _ = await manager.connectLocal()
        #expect(await manager.isConfigured)

        fail.mutate { $0 = true }
        _ = await manager.connectLocal()
        #expect(await manager.status == .offline)
        #expect(await manager.isConfigured, "a daemon that is down is still configured")
    }

    @Test("a base URL the loopback rule forbids is refused, not crashed on")
    func invalidBaseURL() async {
        let built = Locked(false)
        let manager = manager(
            ollama: OllamaConfiguration(baseURL: URL(string: "http://ollama.example.com")!)
        ) { _ in
            built.mutate { $0 = true }
            return self.tagsProvider()
        }

        let result = await manager.connectLocal()
        #expect(result == .failure(.badRequest(message: AIConnectionCopy.baseURLHint)))
        #expect(built.value == false, "the provider is never built with a URL its precondition rejects")
        #expect(await manager.status == .error(AIConnectionCopy.invalidBaseURL))
        #expect(await manager.isConfigured == false)
    }

    @Test("the local path never touches the Keychain, and the key survives the round trip")
    func keychainUntouched() async throws {
        let secrets = InMemorySecretStore(apiKey: "sk-ant-good")
        let seen = Locked<[AIProviderKind]>([])
        let manager = manager(secrets: secrets, kind: .claude, seen: seen) { context in
            context.kind == .ollama
                ? self.tagsProvider()
                : MockProvider(models: [AIModelInfo(id: "claude-sonnet-5", displayName: "Sonnet")]) { _ in .text("") }
        }

        _ = await manager.refresh()
        #expect(await manager.status == .connected)
        #expect(await manager.hasStoredKey)

        #expect(await manager.setProvider(.ollama, ollama: OllamaConfiguration()))
        #expect(await manager.status == .notConfigured, "a switch drops the other provider's state")
        _ = await manager.refresh()
        #expect(await manager.status == .connected)
        #expect(await manager.providerKind == .ollama)
        #expect(try secrets.apiKey() == "sk-ant-good", "the local path leaves the key alone")
        #expect(await manager.hasStoredKey, "hasStoredKey is about the key, not the selection")

        // …and switching back re-validates the stored key rather than asking for it again.
        #expect(await manager.setProvider(.claude))
        _ = await manager.refresh()
        #expect(await manager.status == .connected)
        #expect(await manager.isConfigured)
        #expect(seen.value == [.claude, .ollama, .claude])
    }

    @Test("setProvider is a no-op when the selection has not moved")
    func setProviderIsIdempotent() async {
        let manager = manager(kind: .ollama) { _ in self.tagsProvider() }
        _ = await manager.connectLocal()

        #expect(await manager.setProvider(.ollama, ollama: OllamaConfiguration()) == false)
        #expect(await manager.status == .connected, "no needless re-validation, no status churn")

        let moved = OllamaConfiguration(baseURL: URL(string: "http://127.0.0.1:11500")!)
        #expect(await manager.setProvider(.ollama, ollama: moved))
        #expect(await manager.status == .notConfigured)
        #expect(await manager.isConfigured == false, "a different daemon has not been checked")
    }

    @Test("isConfigured is per provider: a key for Claude, a pulled model for Ollama")
    func isConfiguredMatrix() async {
        let empty = manager(secrets: InMemorySecretStore(), kind: .claude) { _ in self.tagsProvider() }
        #expect(await empty.isConfigured == false)

        let keyed = manager(secrets: InMemorySecretStore(apiKey: "sk-ant-good"), kind: .claude) { _ in
            self.tagsProvider()
        }
        #expect(await keyed.isConfigured, "a stored key configures Claude without a network call")

        _ = await keyed.setProvider(.ollama)
        #expect(await keyed.isConfigured == false, "the key says nothing about the daemon")
        _ = await keyed.connectLocal()
        #expect(await keyed.isConfigured)
    }

    @Test("the status stream carries every local transition")
    func statusStream() async {
        let fail = Locked(false)
        let manager = manager(kind: .claude) { context in
            if context.kind == .claude { return MockProvider.failing(.invalidKey()) }
            return fail.value
                ? MockProvider.failing(.network(code: -1004, description: "refused"))
                : self.tagsProvider()
        }
        var iterator = await manager.statusChanges().makeAsyncIterator()
        #expect(await iterator.next() == .notConfigured)

        _ = await manager.setProvider(.ollama)
        #expect(await iterator.next() == .notConfigured, "the switch itself is a transition")

        _ = await manager.connectLocal()
        #expect(await iterator.next() == .connected)

        fail.mutate { $0 = true }
        _ = await manager.connectLocal()
        #expect(await iterator.next() == .offline)
    }

    @Test("usage is reported for the selected provider, and local work costs nothing")
    func usageByProvider() async throws {
        let ledger = try AIUsageLedger(inMemory: true)
        try await ledger.record(AIUsageRecord(
            model: AIModel.sonnet5.id,
            purpose: .organize,
            usage: AIUsage(inputTokens: 1_000, outputTokens: 200)
        ))
        try await ledger.record(AIUsageRecord(
            model: AIModel.defaultOllama.id,
            purpose: .organize,
            usage: AIUsage(inputTokens: 4_000, outputTokens: 400),
            provider: AIProviderKind.ollama.rawValue
        ))

        let manager = AIConnectionManager(
            secrets: InMemorySecretStore(), ledger: ledger, kind: .ollama
        ) { _ in MockProvider(models: Self.tags) { _ in .text("") } }

        let local = await manager.monthlyUsage()
        #expect(local?.requests == 1)
        #expect(local?.totalTokens == 4_400, "the Claude row is somebody else's bill")
        #expect(
            AIConnectionCopy.usageSummary(kind: .ollama, totals: local)
                == "This month: ~1 local request · ~4,400 tokens · $0"
        )
        let split = await manager.monthlyUsageByPurpose()
        #expect(split?[.organize]?.requests == 1)

        _ = await manager.setProvider(.claude)
        let billed = await manager.monthlyUsage()
        #expect(billed?.requests == 1)
        #expect(billed?.totalTokens == 1_200)
    }
}

@Suite("Settings — connection copy (FR-6.3, FR-6.4, FR-6.5)")
struct AIConnectionCopyTests {

    @Test("a bare model name matches Ollama's :latest tag, and back")
    func tagMatching() {
        let pulled = [
            AIModelInfo(id: "llama3.1:latest", displayName: "llama3.1"),
            AIModelInfo(id: "Mistral:7B", displayName: "mistral"),
        ]
        #expect(OllamaConfiguration.isPulled(AIModel("llama3.1"), in: pulled))
        #expect(OllamaConfiguration.isPulled(AIModel("llama3.1:latest"), in: pulled))
        #expect(OllamaConfiguration.isPulled(AIModel("mistral:7b"), in: pulled), "tags compare case-insensitively")
        #expect(OllamaConfiguration.isPulled(AIModel("llama3.1:8b"), in: pulled) == false)
        #expect(OllamaConfiguration.isPulled(AIModel("  "), in: pulled) == false)
        #expect(OllamaConfiguration().isPulled(in: [AIModelInfo(id: "llama3.1:8b", displayName: "")]))
    }

    @Test("titles and status lines name the provider that is actually selected")
    func providerAwareCopy() {
        #expect(AIConnectionCopy.title(kind: .claude, status: .connected) == "Claude · connected")
        #expect(AIConnectionCopy.title(kind: .ollama, status: .offline) == "Ollama · offline")
        #expect(
            AIConnectionCopy.statusLine(kind: .claude, status: .connected, model: .defaultOrganize)
                == AIModel.defaultOrganize.id
        )
        #expect(
            AIConnectionCopy.statusLine(kind: .claude, status: .offline, model: .defaultOrganize)
                .contains("The API is unreachable")
        )
        // An error message that is not one of the two markers is passed through.
        #expect(
            AIConnectionCopy.statusLine(kind: .ollama, status: .error("Something else"), model: .defaultOllama)
                == "Something else"
        )
        #expect(
            AIConnectionCopy.statusLine(
                kind: .ollama, status: .error(AIConnectionCopy.invalidBaseURL), model: .defaultOllama
            ) == AIConnectionCopy.baseURLHint
        )
    }

    @Test("the privacy statement promises more under the local provider (FR-6.3)")
    func privacyStatement() {
        let claude = AIConnectionCopy.privacyStatement(kind: .claude, notesPath: "~/Notes")
        #expect(claude.contains("~/Notes"))
        #expect(claude.contains("sent to Claude"))
        let local = AIConnectionCopy.privacyStatement(kind: .ollama, notesPath: "~/Notes")
        #expect(local.contains("Nothing is uploaded"))
        #expect(!local.contains("sent to Claude"))
        #expect(local.contains("Excluded folders"))
        #expect(AIConnectionCopy.exclusionDetail(kind: .ollama).contains("local or not"))
    }

    @Test("the usage line pluralises, and says nothing at all with no ledger")
    func usageSummary() {
        #expect(AIConnectionCopy.usageSummary(kind: .claude, totals: nil) == nil)
        #expect(AIConnectionCopy.usageSummary(kind: .claude, totals: AIUsageTotals()) == "This month: no requests yet")
        #expect(
            AIConnectionCopy.usageSummary(kind: .ollama, totals: AIUsageTotals())
                == "This month: no local requests yet · $0"
        )
        let totals = AIUsageTotals(requests: 2, usage: AIUsage(inputTokens: 30, outputTokens: 5))
        #expect(AIConnectionCopy.usageSummary(kind: .claude, totals: totals) == "This month: ~2 requests · ~35 tokens")
    }
}

/// The user-visible scenario behind the "Model not pulled" bug: the default
/// factory in `.live` against the real daemon must report connected when the
/// tag is pulled. Gated the same way as the provider's own live probe.
@Suite("AIConnectionManager against the live daemon",
       .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_TEST_OLLAMA"] == "1"))
struct AIConnectionManagerLiveOllamaTests {
    @Test("connectLocal over the default live factory sees the pulled model")
    func liveConnect() async {
        let manager = AIConnectionManager(
            secrets: InMemorySecretStore(),
            kind: .ollama,
            providerFactory: AIConnectionManager.defaultProviderFactory(mode: .live, store: nil)
        )
        let result = await manager.connectLocal()
        guard case .success(let models) = result else {
            Issue.record("connectLocal failed: \(result)")
            return
        }
        #expect(OllamaConfiguration().isPulled(in: models))
        #expect(await manager.status == .connected)
        #expect(await manager.isConfigured)
    }
}
