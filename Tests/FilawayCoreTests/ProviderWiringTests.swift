import Foundation
import Testing

@testable import FilawayCore

/// P2-03: the parts of "which backend answers, and for how long" that live in
/// Core — the request budgets, the swappable organizer provider, the renamed
/// answer source, and the onboarding card's state machine.
///
/// The app-level half (resolution order, the live rebuild, the onboarding
/// window) is proved by the `settings-wiring`, `onboarding-ollama` and
/// `organize-ollama` smoke phases; everything here needs no window and no
/// daemon (ADR-069).
@Suite("Provider wiring (FR-6.5, FR-8.1, P2-03)")
struct ProviderWiringTests {

    // MARK: - Request budgets (ADR-054, ADR-069)

    @Test("the organize request budget follows the provider kind")
    func organizeTimeoutFollowsKind() throws {
        #expect(OrganizerSettings(providerKind: .claude).requestTimeout == 60)
        #expect(OrganizerSettings(providerKind: .ollama).requestTimeout == 180)
        // The default must stay Claude's, so nothing changes for a user who
        // never touches the preference.
        #expect(OrganizerSettings().requestTimeout == AIPurpose.organize.defaultTimeout)
    }

    @Test("OrganizeRequestBuilder threads the budget into the request")
    func requestCarriesTheBudget() async throws {
        let context = try await Self.requestContext()
        let claude = try OrganizeRequestBuilder.request(
            for: context, settings: OrganizerSettings(providerKind: .claude)
        )
        let ollama = try OrganizeRequestBuilder.request(
            for: context, settings: OrganizerSettings(providerKind: .ollama)
        )
        #expect(claude.timeout == 60)
        #expect(ollama.timeout == 180)
        // The fixture key is model + system + messages + tools + tool choice.
        // A timeout is none of those, so a provider switch must not orphan a
        // committed recording (ADR-067).
        #expect(claude.fixtureKey == ollama.fixtureKey)
    }

    @Test("the answer request uses the kind's search budget, and the race is unchanged")
    func answerTimeoutFollowsKind() throws {
        let scenario = AnswerGolden.scenario("curl-code-card")
        func request(_ kind: AIProviderKind) throws -> AIRequest {
            try AnswerExtractor.request(
                query: scenario.query,
                chunks: scenario.results.promptChunks,
                configuration: AnswerExtractor.Configuration(
                    providerKind: kind, promptsDirectory: AITestPaths.prompts
                )
            )
        }
        let claude = try request(.claude)
        let ollama = try request(.ollama)
        #expect(claude.timeout == AIProviderKind.claude.timeout(for: .search))
        #expect(ollama.timeout == AIProviderKind.ollama.timeout(for: .search))
        // NFR-1's 5 s card budget is the actor's own race and does not move
        // with the backend — the local heuristic is what fills the gap.
        #expect(AnswerExtractor.Configuration(providerKind: .ollama).timeout == 5)
        #expect(AnswerExtractor.Configuration(providerKind: .claude).timeout == 5)
        #expect(claude.fixtureKey == ollama.fixtureKey)
    }

    // MARK: - AnswerSource (P2-03)

    @Test("the model-answered source is named for the model, not for Anthropic")
    func answerSourceIsProviderNeutral() throws {
        #expect(AnswerSource.model.rawValue == "model")
        #expect(AnswerSource.allCases.contains(.model))
        #expect(AnswerSource(rawValue: "claude") == nil)
    }

    // MARK: - Organizer.setProvider (FR-8.1)

    @Test("a provider swapped mid-life is the one the next request uses")
    func setProviderTakesEffectOnTheNextRequest() async throws {
        let first = CountingProvider(identifier: "first")
        let second = CountingProvider(identifier: "second")
        let organizer = await Self.organizer(provider: first)

        await organizer.sessionEnded(Self.session(note: Self.scratchID))
        await organizer.drain()
        #expect(first.count == 1)
        #expect(second.count == 0)
        #expect(await organizer.providerIdentifier == "first")

        await organizer.setProvider(second)
        #expect(await organizer.providerIdentifier == "second")

        // A *different* note, so the second session has a delta of its own —
        // the first one's baseline has advanced past what it typed.
        await organizer.sessionEnded(Self.session(note: Self.otherID))
        await organizer.drain()
        #expect(second.count == 1, "the swap must reach the next request")
        #expect(first.count == 1, "and must not reach the one already served")
    }

    // MARK: - Organizer + context fixtures

    /// One note with a real delta, which is the least the context builder and
    /// the organizer both accept.
    static let scratchID = SessionNotes.a
    static let otherID = SessionNotes.b
    static let scratchBody = "curl -H \"Auth: Bearer $TOK\" https://api.st.app/v2/docs\n"

    static func library() async -> FakeLibrary {
        let library = FakeLibrary()
        await library.add(id: scratchID, path: "Scratch.md", body: scratchBody)
        await library.add(id: otherID, path: "Notebook.md", body: "docker compose up -d\n")
        return library
    }

    static func requestContext() async throws -> OrganizeRequestContext {
        let library = await library()
        return try await OrganizeContextBuilder(promptVersion: .organize).build(
            sessionID: SessionID(),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .idle,
            deltas: [SessionDelta(
                noteID: scratchID, title: "Scratch", relativePath: "Scratch.md",
                baselineText: "", currentText: scratchBody
            )],
            snapshot: try await library.snapshot(),
            mode: .ask,
            source: library,
            candidateFinder: TitleOverlapCandidateFinder()
        )
    }

    static func session(note: NoteID = scratchID) -> Session {
        Session(
            id: SessionID(),
            noteIDs: [note],
            startedAt: Date(timeIntervalSince1970: 1_756_000_000),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .idle
        )
    }

    static func organizer(provider: any AIProvider) async -> Organizer {
        let library = await library()
        return Organizer(
            provider: provider,
            source: library,
            baselines: InMemoryBaselineStore(),
            applier: FakeApplier(library: library),
            queueStore: InMemoryPendingSessionStore(),
            settings: OrganizerSettings(),
            clock: TestClock()
        )
    }

    // MARK: - The onboarding card's state machine (FR-6.5, FR-7.1)

    @MainActor
    @Test("a daemon that answers and has the tag connects, and yields a configuration")
    func setupConnects() async {
        let setup = OllamaSetupModel(validator: StubOllamaValidator(models: ["llama3.1:8b", "qwen3:4b"]))
        #expect(setup.phase == .idle)
        #expect(setup.canTest)

        await setup.test()

        #expect(setup.isConnected)
        #expect(setup.phase == .connected(model: "llama3.1:8b"))
        #expect(setup.statusMessage == "Connected · llama3.1:8b")
        #expect(setup.availableModels == ["llama3.1:8b", "qwen3:4b"])
        let configuration = try? #require(setup.configuration)
        #expect(configuration?.model == AIModel("llama3.1:8b"))
        #expect(configuration?.baseURL == OllamaConfiguration.defaultBaseURL)
    }

    @MainActor
    @Test("a dead daemon names the command that starts it")
    func setupReportsADeadDaemon() async {
        let setup = OllamaSetupModel(validator: StubOllamaValidator(
            failure: .network(code: -1004, description: "connection refused")
        ))
        await setup.test()

        #expect(!setup.isConnected)
        #expect(setup.phase == .failed(.daemonUnreachable))
        #expect(setup.statusMessage.contains("ollama serve"))
        #expect(setup.configuration == nil, "an unverified daemon is never stored")
    }

    @MainActor
    @Test("a daemon without the tag names the pull command")
    func setupReportsAMissingModel() async {
        let setup = OllamaSetupModel(validator: StubOllamaValidator(models: ["qwen3:4b"]))
        setup.selectModel("llama3.1:8b")
        await setup.test()

        #expect(setup.phase == .failed(.modelNotPulled("llama3.1:8b")))
        #expect(setup.statusMessage.contains("ollama pull llama3.1:8b"))
        #expect(setup.configuration == nil)
    }

    @MainActor
    @Test("Refresh fills the popup and adopts the daemon's model when the default is absent")
    func refreshAdoptsWhatIsThere() async {
        let setup = OllamaSetupModel(validator: StubOllamaValidator(models: ["qwen3:4b"]))
        let models = await setup.refreshModels()

        #expect(models == ["qwen3:4b"])
        #expect(setup.selectedModel == "qwen3:4b")
        #expect(setup.phase == .idle, "refresh lists, it does not judge")
        await setup.test()
        #expect(setup.isConnected)
    }

    @MainActor
    @Test("NFR-4's loopback rule is enforced before anything is asked")
    func setupRejectsPlaintextToAnotherHost() async {
        let validator = StubOllamaValidator(models: ["llama3.1:8b"])
        let setup = OllamaSetupModel(validator: validator)

        setup.urlEdited("http://192.168.1.20:11434")
        #expect(setup.baseURL == nil)
        #expect(!setup.canTest)
        await setup.test()
        #expect(setup.phase == .failed(.badURL))

        setup.urlEdited("https://ollama.example.test")
        #expect(setup.baseURL != nil, "https to another host is allowed")
        #expect(setup.canTest)

        setup.urlEdited("not a url at all")
        #expect(setup.baseURL == nil)
    }

    @MainActor
    @Test("editing the address or the model retracts the last verdict")
    func editingClearsTheVerdict() async {
        let setup = OllamaSetupModel(validator: StubOllamaValidator(models: ["llama3.1:8b", "qwen3:4b"]))
        await setup.test()
        #expect(setup.isConnected)

        setup.selectModel("qwen3:4b")
        #expect(!setup.isConnected, "a different tag is a different question")
        #expect(setup.phase == .idle)

        await setup.test()
        #expect(setup.isConnected)
        setup.urlEdited("http://localhost:9999")
        #expect(setup.phase == .idle)
        #expect(setup.availableModels.isEmpty)
        #expect(setup.configuration == nil)
    }

    @MainActor
    @Test("every state change reaches the window's redraw hook")
    func setupPublishesChanges() async {
        let setup = OllamaSetupModel(validator: StubOllamaValidator(models: ["llama3.1:8b"]))
        let counter = ChangeCounter()
        setup.onChange = { counter.bump() }

        setup.urlEdited("http://localhost:11434/")
        await setup.test()

        #expect(counter.value >= 3, "edit, testing, and the verdict")
    }
}

// MARK: - Support

/// A provider that only counts and answers, so "which one served this request"
/// is observable. ``ScriptedProvider``'s identifier is fixed.
private final class CountingProvider: AIProvider, @unchecked Sendable {
    let identifier: String
    private let lock = NSLock()
    private var served = 0

    init(identifier: String) {
        self.identifier = identifier
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return served
    }

    /// Synchronous, so the lock is never touched from an async context.
    private func bump() {
        lock.lock()
        served += 1
        lock.unlock()
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        bump()
        return .toolUse(
            name: OrganizationPlan.toolName,
            input: PlanFixtures.toolInput(summary: "Nothing to do.", actions: [])
        )
    }

    func validateKey() async throws -> [AIModelInfo] { [] }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var reads: Int { value }
}

@Suite("Local request budgets (the runaway-generation fixes)")
struct LocalBudgetTests {
    @Test("an organize request to a local model caps generation at localMaxTokens")
    func localCap() throws {
        #expect(OrganizeRequestBuilder.localMaxTokens < OrganizeRequestBuilder.maxTokens)
        // The cap must leave room for every committed golden plan.
        #expect(OrganizeRequestBuilder.localMaxTokens >= 1_024)
    }

    @Test("the local retry policy retries transport errors but never a timeout")
    func localRetryPolicy() {
        let policy = RetryPolicy.local
        #expect(policy.shouldRetry(.network(code: 1, description: "x"), attempt: 1))
        #expect(!policy.shouldRetry(.timedOut, attempt: 1),
                "temperature 0: an identical prompt deterministically runs away again")
        let claude = RetryPolicy()
        #expect(claude.shouldRetry(.timedOut, attempt: 1),
                "the cloud default is unchanged")
    }
}
