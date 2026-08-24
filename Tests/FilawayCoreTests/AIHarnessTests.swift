import Foundation
import Testing

@testable import FilawayCore

@Suite("AI mode selection")
struct AIModeTests {
    @Test("replay is the default, everywhere")
    func defaults() {
        #expect(AIMode.current(environment: [:]) == .replay)
        #expect(AIMode.current(environment: ["FILAWAY_AI_MODE": "nonsense"]) == .replay)
        #expect(AIMode.current(environment: ["FILAWAY_AI_MODE": "record"]) == .record)
        #expect(AIMode.current(environment: ["FILAWAY_AI_MODE": "LIVE"]) == .live)
        #expect(AIMode.replay.isLive == false)
        #expect(AIMode.record.isLive)
    }

    @Test("this test process is in replay mode")
    func testsAreOffline() {
        // If this ever fails, CI is about to try to spend money.
        #expect(AIMode.current() == .replay || ProcessInfo.processInfo.environment["FILAWAY_AI_MODE"] != nil)
    }

    @Test("the factory builds what the mode asks for")
    func factory() throws {
        let store = AITestPaths.recordingStore
        let replay = try AIProviderFactory.make(mode: .replay, store: store, keySource: .none)
        #expect(replay.identifier == "replay")

        let live = try AIProviderFactory.make(
            mode: .live, store: nil, keySource: .fixed("k"), configuration: StubURLProtocol.configuration()
        )
        #expect(live.identifier == "claude")

        let record = try AIProviderFactory.make(
            mode: .record, store: store, keySource: .fixed("k"), configuration: StubURLProtocol.configuration()
        )
        #expect(record.identifier == "recording")

        #expect(throws: AIError.self) {
            try AIProviderFactory.make(mode: .replay, store: nil, keySource: .none)
        }
    }
}

@Suite("AI recording fixtures")
struct AIRecordingFixtureTests {
    /// Writes the hand-authored fixtures to `Tests/Fixtures/ai-recordings`.
    /// Off by default; it is how the committed files were produced.
    @Test(
        "regenerate the committed fixtures",
        .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_WRITE_AI_FIXTURES"] == "1")
    )
    func regenerate() throws {
        let store = AITestPaths.recordingStore
        for recording in AIFixtures.recordings() {
            let url = try store.save(recording)
            print("wrote \(url.path)")
        }
    }

    @Test("every committed fixture loads, decodes and keeps its key")
    func integrity() throws {
        let store = AITestPaths.recordingStore
        let all = try store.all()
        #expect(all.count >= 5, "expected the hand-authored M2-02 set")
        for recording in all {
            #expect(recording.version == AIRecording.currentVersion)
            #expect(recording.key == store.url(purpose: recording.purpose, key: recording.key)
                .deletingPathExtension().lastPathComponent)
            if recording.purpose != .validate {
                #expect(
                    recording.request.fixtureKey == recording.key,
                    "the stored request must hash to the filename, or replay would miss"
                )
                #expect(recording.requestBody == ClaudeWire.body(for: recording.request))
                _ = try recording.response()
            }
        }
    }

    @Test("the valid-plan fixture replays into a plan the validator accepts")
    func validPlan() async throws {
        let provider = ReplayProvider(store: AITestPaths.recordingStore)
        let response = try await provider.complete(AIFixtures.validPlanRequest)
        #expect(response.stopReason == .toolUse)
        #expect(response.usage.inputTokens > 0)

        let decoding = try PlanDecoder.decode(response: response, context: SampleLibrary.context)
        #expect(decoding.unknownActions.isEmpty)
        #expect(decoding.plan.actions.count == 2)
        #expect(decoding.plan.summary.contains("Commands/curl"))

        let result = PlanValidator(context: SampleLibrary.context)
            .validate(decoding.plan, unknownActions: decoding.unknownActions)
        #expect(result.isValid, "\(result.summary)")
    }

    @Test("the invalid-plan fixture is caught by the validator, not by apply")
    func invalidPlan() async throws {
        let provider = ReplayProvider(store: AITestPaths.recordingStore)
        let response = try await provider.complete(AIFixtures.invalidPlanRequest)
        let decoding = try PlanDecoder.decode(response: response, context: SampleLibrary.context)

        // The `deleteNote` the model invented is not representable at all.
        #expect(decoding.unknownActions.map(\.name) == ["deleteNote"])

        let result = PlanValidator(context: SampleLibrary.context)
            .validate(decoding.plan, unknownActions: decoding.unknownActions)
        #expect(!result.isValid)
        #expect(result.hasError(.folderTooDeep))
        #expect(result.hasError(.unknownNote))
        #expect(result.hasError(.unsafeTitle))
        #expect(result.hasError(.segmentNotFound))
        #expect(result.hasWarning(.unreadableAction))
    }

    @Test("the nothing-to-do fixture is a valid, empty plan")
    func nothingToDo() async throws {
        let provider = ReplayProvider(store: AITestPaths.recordingStore)
        let response = try await provider.complete(AIFixtures.nothingToDoRequest)
        let decoding = try PlanDecoder.decode(response: response, context: SampleLibrary.context)
        #expect(decoding.plan.isEmpty)
        let result = PlanValidator(context: SampleLibrary.context).validate(decoding.plan)
        #expect(result.isValid)
        #expect(result.hasWarning(.nothingToDo))
    }

    @Test("the refusal fixture surfaces as a refusal, not a crash")
    func refusal() async throws {
        let provider = ReplayProvider(store: AITestPaths.recordingStore)
        let response = try await provider.complete(AIFixtures.refusalRequest)
        #expect(response.isRefusal)
        #expect(response.stopDetails?.category == "cyber")
        #expect(throws: PlanDecodingError.refused(category: "cyber")) {
            try PlanDecoder.decode(response: response)
        }

        var health = AIHealth()
        health.recordResponse(response)
        if case let .error(message) = health.status() {
            #expect(message.contains("declined"))
        } else {
            Issue.record("a refusal should land in .error, got \(health.status())")
        }
    }

    @Test("the key-validation fixture replays the model list")
    func validateKey() async throws {
        let provider = ReplayProvider(store: AITestPaths.recordingStore)
        let models = try await provider.validateKey()
        #expect(models.map(\.id).contains("claude-sonnet-5"))
        #expect(models.first { $0.id == "claude-haiku-4-5" }?.supportsAdaptiveThinking == false)
        #expect(models.first { $0.id == "claude-opus-5" }?.maxInputTokens == 1_000_000)
    }

    @Test("no excluded note ever appears in a recorded request (FR-4.5)")
    func exclusionsNeverRecorded() throws {
        let filter = ExclusionFilter(excludedFolders: ["Private"])
        for recording in try AITestPaths.recordingStore.all() {
            let leaks = filter.leaks(
                in: recording.requestBody, bodies: SampleLibrary.bodies, notes: SampleLibrary.notes
            )
            #expect(leaks.isEmpty, "\(recording.purpose)/\(recording.key) leaked \(leaks)")

            // Belt and braces: the excluded note's distinctive text, wherever it
            // might have been embedded.
            let haystack = recording.requestBody.allStrings.joined(separator: "\n")
            #expect(!haystack.contains("Salary"))
            #expect(!haystack.contains("12345"))
        }
    }

    @Test("a missing fixture fails loudly and names the file to record")
    func missingFixture() async throws {
        let provider = ReplayProvider(store: AITestPaths.recordingStore)
        let request = AIFixtures.organizeRequest("A prompt nobody has recorded.")
        do {
            _ = try await provider.complete(request)
            Issue.record("expected a missing-recording failure")
        } catch let error as AIError {
            guard case let .missingRecording(purpose, key, path) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(purpose == .organize)
            #expect(key == request.fixtureKey)
            #expect(path.hasSuffix("organize/\(key).json"))
            #expect(error.description.contains("FILAWAY_AI_MODE=record"))
        }
    }
}

@Suite("Record and replay round trip")
struct RecordReplayTests {
    private func temporaryStore() throws -> (AIRecordingStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("filaway-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AIRecordingStore(directory: directory), directory)
    }

    @Test("record then replay returns the same response, without the upstream")
    func roundTrip() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let planInput = try PlanDecoder.toolInput(for: OrganizationPlan(
            summary: "Merge it", actions: [SampleActions.appendToNote]
        ))
        let upstream = MockProvider { request in
            AIResponse(
                id: "msg_live",
                model: request.model.id,
                content: [.toolUse(id: "toolu_1", name: OrganizationPlan.toolName, input: planInput)],
                stopReason: .toolUse,
                usage: AIUsage(inputTokens: 100, outputTokens: 25),
                requestID: "req_live"
            )
        }

        let request = AIFixtures.organizeRequest("Round trip.")
        let recorder = RecordingProvider(upstream: upstream, store: store, clock: TestClock())
        let live = try await recorder.complete(request)

        let replay = ReplayProvider(store: store)
        let replayed = try await replay.complete(request)

        // `requestID` is a per-call header and is not part of the fixture.
        #expect(replayed.id == live.id)
        #expect(replayed.content == live.content)
        #expect(replayed.stopReason == live.stopReason)
        #expect(replayed.usage == live.usage)

        let file = store.url(for: request)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let recording = try #require(try store.load(for: request))
        #expect(recording.request == request, "the full request is stored so a diff is readable")
        #expect(recording.requestBody["system"] == .string(AIFixtures.system))
        #expect(recording.recordedAt != nil)
    }

    @Test("the fixture is pretty-printed and sorted, so diffs are readable")
    func fixtureFormat() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = AIFixtures.organizeRequest("Formatting.")
        let recorder = RecordingProvider(
            upstream: MockProvider.echoing("hi"), store: store, clock: TestClock()
        )
        _ = try await recorder.complete(request)

        let text = try String(contentsOf: store.url(for: request), encoding: .utf8)
        #expect(text.contains("\n  \""), "pretty printed")
        let keyIndex = try #require(text.range(of: "\"key\""))
        let modelIndex = try #require(text.range(of: "\"model\""))
        #expect(keyIndex.lowerBound < modelIndex.lowerBound, "keys are sorted")
    }

    @Test("recording key validation stores the model list")
    func recordValidateKey() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let upstream = MockProvider(
            models: [AIModelInfo(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", maxInputTokens: 1_000_000)],
            handler: { _ in .text("unused") }
        )
        let recorder = RecordingProvider(upstream: upstream, store: store, clock: TestClock())
        _ = try await recorder.validateKey()

        let replayed = try await ReplayProvider(store: store).validateKey()
        #expect(replayed.map(\.id) == ["claude-sonnet-5"])
        #expect(replayed[0].maxInputTokens == 1_000_000)
    }

    @Test("replay falls back to the known model list with no fixture")
    func replayValidateWithoutFixture() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try await ReplayProvider(store: store).validateKey()
        #expect(models.map(\.id) == AIModel.known.map(\.id))
    }

    @Test("MockProvider covers the degradation paths")
    func mockProvider() async throws {
        let failing = MockProvider.failing(.rateLimited(retryAfter: 30))
        await #expect(throws: AIError.rateLimited(retryAfter: 30)) {
            try await failing.complete(AIFixtures.validPlanRequest)
        }
        await #expect(throws: AIError.rateLimited(retryAfter: 30)) { try await failing.validateKey() }

        let echoing = MockProvider.echoing("nothing to do")
        #expect(try await echoing.complete(AIFixtures.validPlanRequest).text == "nothing to do")
        #expect(echoing.identifier == "mock")
    }
}
