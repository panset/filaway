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
        let provider = try factory(.none)
        #expect(provider.identifier == "mock")
        #expect(try await provider.validateKey().count == AIModel.known.count)
    }
}
