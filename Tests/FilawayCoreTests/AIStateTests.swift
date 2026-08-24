import Foundation
import Testing

@testable import FilawayCore

@Suite("Secret store")
struct SecretStoreTests {
    @Test("the in-memory store round-trips")
    func inMemory() throws {
        let store = InMemorySecretStore()
        #expect(try store.apiKey() == nil)
        try store.setAPIKey("sk-ant-abc")
        #expect(try store.apiKey() == "sk-ant-abc")
        try store.setAPIKey("sk-ant-def")
        #expect(try store.apiKey() == "sk-ant-def")
        try store.deleteAPIKey()
        #expect(try store.apiKey() == nil)
        try store.deleteAPIKey()  // deleting nothing is fine
    }

    @Test("key sources resolve in the documented order")
    func keySources() throws {
        #expect(try APIKeySource.none.key() == nil)
        #expect(try APIKeySource.fixed("k").key() == "k")
        #expect(try APIKeySource.fixed("  ").key() == nil, "whitespace is not a key")
        #expect(try APIKeySource.fixed("  k\n").key() == "k", "pasted keys often carry a newline")

        let store = InMemorySecretStore(apiKey: "from-keychain")
        #expect(try APIKeySource.store(store).key() == "from-keychain")
        #expect(try APIKeySource.storeThenEnvironment(store, variable: "FILAWAY_NOT_SET").key() == "from-keychain")

        let empty = InMemorySecretStore()
        #expect(try APIKeySource.storeThenEnvironment(empty, variable: "FILAWAY_NOT_SET").key() == nil)
        #expect(try APIKeySource.environment("FILAWAY_NOT_SET").key() == nil)
    }

    /// The real Keychain, only when explicitly asked for: an unsigned
    /// `swift test` binary can prompt or fail outright.
    @Test(
        "the real Keychain round-trips",
        .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_TEST_KEYCHAIN"] == "1")
    )
    func keychain() throws {
        let store = KeychainStore(service: "com.tejaspanse.filaway.tests.\(UUID().uuidString)")
        let account = "anthropic-api-key-test"
        defer { try? store.deleteSecret(for: account) }

        #expect(try store.secret(for: account) == nil)
        try store.setSecret("sk-ant-keychain", for: account)
        #expect(try store.secret(for: account) == "sk-ant-keychain")
        try store.setSecret("sk-ant-replaced", for: account)
        #expect(try store.secret(for: account) == "sk-ant-replaced")
        try store.deleteSecret(for: account)
        #expect(try store.secret(for: account) == nil)
    }

    @Test("the Keychain service and account are the documented ones")
    func keychainConstants() {
        #expect(KeychainStore.defaultService == "com.tejaspanse.filaway")
        #expect(KeychainStore.apiKeyAccount == "anthropic-api-key")
        #expect(KeychainStore().service == FilawayCore.subsystem)
    }
}

@Suite("AI status")
struct AIStatusTests {
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("errors map onto the pill")
    func mapping() {
        #expect(AIHealth.status(for: .notConfigured, at: now) == .notConfigured)
        #expect(AIHealth.status(for: .invalidKey(), at: now) == .invalidKey)
        #expect(AIHealth.status(for: .network(code: -1009, description: "offline"), at: now) == .offline)
        #expect(AIHealth.status(for: .timedOut, at: now) == .offline)
        #expect(AIHealth.status(for: .cancelled, at: now) == .connected)
        #expect(AIHealth.status(for: .rateLimited(retryAfter: 30), at: now) == .rateLimited(until: now.addingTimeInterval(30)))
        #expect(AIHealth.status(for: .rateLimited(), at: now) == .rateLimited(until: now.addingTimeInterval(60)))
        if case .error = AIHealth.status(for: .serverOverloaded(status: 529), at: now) {} else {
            Issue.record("529 should be .error")
        }
    }

    @Test("a rate limit heals when its deadline passes")
    func rateLimitExpires() {
        var health = AIHealth()
        health.recordFailure(.rateLimited(retryAfter: 30), at: now)
        #expect(health.status(at: now) == .rateLimited(until: now.addingTimeInterval(30)))
        #expect(health.status(at: now).isUsable(at: now) == false)
        #expect(health.status(at: now.addingTimeInterval(31)) == .connected)
    }

    @Test("consecutive retryable failures are counted, and reset on success")
    func failureCounting() {
        var health = AIHealth()
        health.recordFailure(.serverOverloaded(status: 500), at: now)
        health.recordFailure(.serverOverloaded(status: 500), at: now)
        #expect(health.consecutiveFailures == 2)
        health.recordFailure(.invalidKey(), at: now)
        #expect(health.consecutiveFailures == 0, "a bad key is not worth backing off from")
        health.recordSuccess(at: now)
        #expect(health.status(at: now) == .connected)
        #expect(health.consecutiveFailures == 0)
        #expect(health.updatedAt == now)
    }

    @Test("a refusal and a truncated reply are failures without blaming the connection")
    func responseOutcomes() {
        var health = AIHealth()
        health.recordResponse(AIResponse(
            id: "m", model: "x", content: [], stopReason: .refusal,
            stopDetails: AIStopDetails(type: "refusal", category: "cyber")
        ))
        #expect(health.status() != .connected)

        health.recordResponse(AIResponse(id: "m", model: "x", content: [], stopReason: .maxTokens))
        if case let .error(message) = health.status() {
            #expect(message.contains("cut off"))
        } else {
            Issue.record("truncation should be an error state")
        }

        health.recordResponse(.text("fine"))
        #expect(health.status() == .connected)
    }

    @Test("only the offline-ish states queue work (FR-6.4)")
    func queueing() {
        #expect(AIStatus.offline.shouldQueue)
        #expect(AIStatus.rateLimited(until: now).shouldQueue)
        #expect(AIStatus.error("x").shouldQueue)
        #expect(!AIStatus.invalidKey.shouldQueue, "queueing behind a bad key would nag forever")
        #expect(!AIStatus.notConfigured.shouldQueue)
        #expect(!AIStatus.connected.shouldQueue)
    }

    @Test("labels are content-free")
    func labels() {
        for status in [
            AIStatus.notConfigured, .connected, .invalidKey, .offline, .rateLimited(until: now), .error("boom"),
        ] {
            #expect(status.label.hasPrefix("AI: "))
            #expect(!status.label.contains("boom"), "the pill never shows raw error text")
        }
    }

    @Test("error descriptions stay content-free and actionable")
    func errorDescriptions() {
        #expect(AIError.notConfigured.description.contains("key"))
        #expect(AIError.rateLimited(retryAfter: 30).description.contains("30"))
        #expect(AIError.modelNotFound(model: "claude-x").description.contains("claude-x"))
        #expect(AIError.missingRecording(purpose: .organize, key: "abc", path: "/tmp/abc.json")
            .description.contains("/tmp/abc.json"))
    }
}

@Suite("AI usage ledger (FR-6.6)")
struct AIUsageLedgerTests {
    private func ledger() throws -> AIUsageLedger { try AIUsageLedger() }

    private let january = Date(timeIntervalSince1970: 1_767_312_000)  // 2026-01-02 UTC
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("recording a response stores its usage")
    func recordResponse() async throws {
        let ledger = try ledger()
        let response = AIResponse(
            id: "m",
            model: "claude-sonnet-5",
            content: [],
            stopReason: .toolUse,
            usage: AIUsage(inputTokens: 1_000, outputTokens: 200, cacheReadInputTokens: 50),
            requestID: "req_1"
        )
        try await ledger.record(response: response, purpose: .organize, at: january)

        let records = try await ledger.allRecords()
        #expect(records.count == 1)
        #expect(records[0].model == "claude-sonnet-5")
        #expect(records[0].purpose == .organize)
        #expect(records[0].usage.inputTokens == 1_000)
        #expect(records[0].usage.cacheReadInputTokens == 50)
        #expect(records[0].requestID == "req_1")
        #expect(records[0].provider == "claude")
    }

    @Test("monthly totals add up and stop at the month boundary")
    func monthlyTotals() async throws {
        let ledger = try ledger()
        let calendar = utc
        let (start, end) = AIUsageLedger.monthBounds(containing: january, calendar: calendar)

        for offset in [0.0, 3_600.0, 86_400.0] {
            try await ledger.record(AIUsageRecord(
                timestamp: start.addingTimeInterval(offset + 60),
                model: "claude-sonnet-5",
                purpose: .organize,
                usage: AIUsage(inputTokens: 100, outputTokens: 10)
            ))
        }
        // One in the next month, one from a replayed (free) call.
        try await ledger.record(AIUsageRecord(
            timestamp: end.addingTimeInterval(60), model: "claude-sonnet-5", purpose: .organize,
            usage: AIUsage(inputTokens: 999, outputTokens: 999)
        ))
        try await ledger.record(AIUsageRecord(
            timestamp: start.addingTimeInterval(120), model: "claude-sonnet-5", purpose: .organize,
            usage: AIUsage(inputTokens: 500, outputTokens: 500), provider: "replay"
        ))

        let totals = try await ledger.monthlyTotals(containing: january, calendar: calendar)
        #expect(totals.requests == 3)
        #expect(totals.inputTokens == 300)
        #expect(totals.outputTokens == 30)
        #expect(totals.totalTokens == 330)

        let everything = try await ledger.monthlyTotals(containing: january, calendar: calendar, provider: nil)
        #expect(everything.requests == 4, "replayed traffic is recorded, just not billed")
    }

    @Test("totals split by purpose")
    func byPurpose() async throws {
        let ledger = try ledger()
        let calendar = utc
        try await ledger.record(AIUsageRecord(
            timestamp: january, model: "claude-sonnet-5", purpose: .organize,
            usage: AIUsage(inputTokens: 1_000, outputTokens: 100)
        ))
        try await ledger.record(AIUsageRecord(
            timestamp: january, model: "claude-haiku-4-5", purpose: .search,
            usage: AIUsage(inputTokens: 200, outputTokens: 20)
        ))
        try await ledger.record(AIUsageRecord(
            timestamp: january, model: "claude-haiku-4-5", purpose: .search,
            usage: AIUsage(inputTokens: 300, outputTokens: 30)
        ))

        let split = try await ledger.monthlyTotalsByPurpose(containing: january, calendar: calendar)
        #expect(split[.organize]?.requests == 1)
        #expect(split[.search]?.requests == 2)
        #expect(split[.search]?.inputTokens == 500)
        #expect(split[.validate] == nil)
    }

    @Test("an empty month reports zero, not nil")
    func emptyMonth() async throws {
        let totals = try await ledger().monthlyTotals(containing: january, calendar: utc)
        #expect(totals == AIUsageTotals())
        #expect(totals.totalTokens == 0)
    }

    @Test("pruning drops old rows only")
    func pruning() async throws {
        let ledger = try ledger()
        try await ledger.record(AIUsageRecord(
            timestamp: january, model: "m", purpose: .organize, usage: AIUsage(inputTokens: 1)
        ))
        try await ledger.record(AIUsageRecord(
            timestamp: january.addingTimeInterval(90 * 86_400), model: "m", purpose: .organize,
            usage: AIUsage(inputTokens: 2)
        ))
        let removed = try await ledger.prune(before: january.addingTimeInterval(86_400))
        #expect(removed == 1)
        #expect(try await ledger.allRecords().count == 1)
    }

    @Test("the ledger opens on disk beside the metadata database, not inside it")
    func onDisk() async throws {
        let library = try TempLibrary()
        let ledger = try AIUsageLedger(library: library.library)
        try await ledger.record(AIUsageRecord(
            timestamp: january, model: "m", purpose: .validate, usage: AIUsage(inputTokens: 5)
        ))
        let path = library.library.supportDirectory.appendingPathComponent("ai-usage.sqlite").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path != library.library.databaseURL.path)

        // Reopening finds the rows again.
        let reopened = try AIUsageLedger(library: library.library)
        #expect(try await reopened.allRecords().count == 1)
    }

    @Test("usage sums and cache fields are surfaced")
    func usageArithmetic() {
        let a = AIUsage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
        let b = AIUsage(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 30, cacheReadInputTokens: 40)
        let sum = a + b
        #expect(sum.inputTokens == 11)
        #expect(sum.outputTokens == 22)
        #expect(sum.cacheCreationInputTokens == 33)
        #expect(sum.cacheReadInputTokens == 44)
        #expect(a.totalInputTokens == 8)
    }
}
