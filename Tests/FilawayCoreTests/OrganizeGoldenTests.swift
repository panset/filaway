import Foundation
import Testing

@testable import FilawayCore

/// The golden organize scenarios (M2-06, plan §3: "≥8 recorded scenarios").
///
/// Each one runs the **whole** pipeline — context builder → prompt → provider →
/// decoder → validator → organizer — against a committed replay fixture, so a
/// change to the prompt, the rendering or the budget shows up as a missing
/// fixture rather than as a silent behaviour change (the fixture filename *is*
/// a hash of the request).
///
/// There is no API key on this machine, so the responses are hand-authored;
/// the **requests** are not. They are captured from the real builder:
///
/// ```
/// FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "regenerate the organize goldens"
/// ```
///
/// Re-record them against the live API when a key exists (plan M4-09):
///
/// ```
/// FILAWAY_AI_MODE=record swift test --filter "Organize goldens"
/// ```
enum OrganizeGolden {
    // MARK: The library every scenario shares

    static let curl = NoteID(UUID(uuidString: "60111111-1111-4111-8111-000000000001")!)
    static let git = NoteID(UUID(uuidString: "60222222-2222-4222-8222-000000000002")!)
    static let authDebug = NoteID(UUID(uuidString: "60333333-3333-4333-8333-000000000003")!)
    static let standup = NoteID(UUID(uuidString: "60444444-4444-4444-8444-000000000004")!)
    static let payReview = NoteID(UUID(uuidString: "60555555-5555-4555-8555-000000000005")!)
    static let scratch = NoteID(UUID(uuidString: "60666666-6666-4666-8666-000000000006")!)
    static let untitled = NoteID(UUID(uuidString: "60777777-7777-4777-8777-000000000007")!)

    static let sessionID = SessionID(UUID(uuidString: "60888888-8888-4888-8888-000000000008")!)
    static let endedAt = Date(timeIntervalSince1970: 1_756_000_200)
    static let excludedFolders = ["Private"]

    static let curlBody = """
    # curl

    Handy invocations.

    ## Fetch a page

    ```sh
    curl -sS https://example.test/
    ```
    """

    static let gitBody = """
    # git

    ```sh
    git rebase -i HEAD~3
    ```
    """

    static let authDebugBody = "Notes from debugging the auth API. The 401 was a clock skew.\n"
    static let standupBody = "# Standup\n\n- shipped the parser\n"
    /// Excluded (FR-4.5). Deliberately distinctive text, so a leak is obvious.
    static let payReviewBody = "compensation figure is 88888 and must never leave this machine\n"

    // MARK: Session material

    static let curlSegment = """
    ```sh
    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs
    ```
    """

    static let scratchWithCurl = """
    curl to fetch docs from staging:

    \(curlSegment)

    remember: the token expires hourly
    """

    static let scratchWithSSH = """
    ssh port forward for the staging database:

    ```sh
    ssh -N -L 5432:db.internal:5432 jump.st.app
    ```
    """

    static let scratchWithKubernetes = """
    kubernetes rollout notes:

    ```sh
    kubectl rollout restart deployment/api
    kubectl rollout status deployment/api
    ```

    the readiness probe needs a longer initial delay
    """

    static let untitledBody = """
    the staging auth token lives in 1Password under "staging api"

    export TOK=$(op read "op://staging/api/token")
    """

    // MARK: - Scenarios

    struct Scenario: Sendable {
        var name: String
        /// What the fixture file is *for*, in one line.
        var note: String
        var sessionNoteID: NoteID
        var sessionPath: String
        var sessionBody: String
        /// Extra notes the session touched (the exclusion scenario adds one).
        var alsoTouched: [NoteID] = []
        /// The session note is an existing library note rather than a new one.
        var baseline: String?
        var response: JSONValue
    }

    static var scenarios: [Scenario] {
        [
            Scenario(
                name: "new-note",
                note: "a new subject with no obvious home note → createNote in the best existing folder",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: scratchWithSSH,
                response: plan(
                    summary: "New note \"SSH port forwarding\" filed under Commands.",
                    actions: [
                        PlanFixtures.createNote(
                            title: "SSH port forwarding",
                            folder: "Commands",
                            content: "```sh\nssh -N -L 5432:db.internal:5432 jump.st.app\n```",
                            tags: ["ssh", "staging"]
                        ),
                    ]
                )
            ),
            Scenario(
                name: "merge-code-block",
                note: "a code block that belongs in an existing note → moveSegment (amendment 1)",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: scratchWithCurl,
                response: plan(
                    summary: "Code block merged into Commands / curl.",
                    actions: [
                        PlanFixtures.moveSegment(
                            from: scratch, segment: curlSegment, toExisting: curl, heading: "Fetch staging docs"
                        ),
                    ]
                )
            ),
            Scenario(
                name: "retitle-untitled",
                note: "an untitled note with real content → retitleNote + tagNote",
                sessionNoteID: untitled,
                sessionPath: "Untitled note.md",
                sessionBody: untitledBody,
                response: plan(
                    summary: "Untitled note renamed to Staging auth token and tagged.",
                    actions: [
                        PlanFixtures.retitle(untitled, to: "Staging auth token"),
                        PlanFixtures.tag(untitled, ["auth", "staging"]),
                    ]
                )
            ),
            Scenario(
                name: "new-folder",
                note: "nothing that exists fits → createFolder at depth 1, then file into it",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: scratchWithKubernetes,
                response: plan(
                    summary: "New folder Kubernetes created and the rollout notes filed into it.",
                    actions: [
                        PlanFixtures.createFolder("Kubernetes"),
                        PlanFixtures.createNote(
                            title: "Rollout restarts",
                            folder: "Kubernetes",
                            content: "```sh\nkubectl rollout restart deployment/api\n```",
                            tags: ["kubernetes"]
                        ),
                    ]
                )
            ),
            Scenario(
                name: "nothing-to-do",
                note: "FR-4.6 — the session is already where it belongs",
                sessionNoteID: standup,
                sessionPath: "Meetings/Standup.md",
                sessionBody: standupBody + "- reviewed the plan\n",
                baseline: standupBody,
                response: plan(summary: "Nothing needed filing.", actions: [])
            ),
            Scenario(
                name: "convergence",
                note: "FR-4.6 — an existing note is preferred over a plausible new folder",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: "another curl invocation, this one with a proxy:\n\n```sh\ncurl -x http://proxy:3128 https://example.test/\n```\n",
                response: plan(
                    summary: "Proxy invocation appended to Commands / curl.",
                    actions: [
                        PlanFixtures.appendToNote(curl, content: "```sh\ncurl -x http://proxy:3128 https://example.test/\n```", heading: "Through a proxy"),
                    ]
                )
            ),
            Scenario(
                name: "excluded-folder",
                note: "FR-4.5 — a session that touched an excluded note sends none of it",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: scratchWithCurl,
                alsoTouched: [payReview],
                response: plan(
                    summary: "Code block merged into Commands / curl.",
                    actions: [
                        PlanFixtures.moveSegment(
                            from: scratch, segment: curlSegment, toExisting: curl, heading: "Fetch staging docs"
                        ),
                    ]
                )
            ),
            Scenario(
                name: "invalid-action-dropped",
                note: "risk #6 — one hallucinated target must not cost the user the good action",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: "notes on the deploy script and its retry loop\n",
                response: plan(
                    summary: "Deploy notes appended to Auth API debug.",
                    actions: [
                        PlanFixtures.appendToNote(authDebug, content: "the deploy script retries three times"),
                        PlanFixtures.appendToNote(
                            NoteID(UUID(uuidString: "00000000-0000-4000-8000-000000000000")!),
                            content: "a note that does not exist"
                        ),
                    ]
                )
            ),
            Scenario(
                name: "summary-no-longer-matches",
                note: "risk #6 — dropping the action would make the card's summary a lie, so the plan goes",
                sessionNoteID: scratch,
                sessionPath: "Scratch.md",
                sessionBody: "compose file tweaks: the api service needs depends_on\n",
                response: plan(
                    summary: "Compose tweaks appended to Auth API debug and a new Compose folder created.",
                    actions: [
                        PlanFixtures.appendToNote(authDebug, content: "the api service needs depends_on"),
                        PlanFixtures.createFolder("Commands/Docker/Compose"),
                    ]
                )
            ),
        ]
    }

    static func plan(summary: String, actions: [JSONValue]) -> JSONValue {
        .object([
            "id": .string("msg_golden"),
            "type": "message",
            "role": "assistant",
            "model": .string(AIModel.defaultOrganize.id),
            "content": .array([
                .object([
                    "type": "tool_use",
                    "id": "toolu_golden",
                    "name": .string(OrganizationPlan.toolName),
                    "input": PlanFixtures.toolInput(summary: summary, actions: actions),
                ]),
            ]),
            "stop_reason": "tool_use",
            "usage": .object([
                "input_tokens": .integer(2_400),
                "output_tokens": .integer(180),
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
            ]),
        ])
    }

    // MARK: - Harness

    struct Run {
        var organizer: Organizer
        var recorder: EventRecorder<OrganizerEvent>
        var library: FakeLibrary
        var baselines: InMemoryBaselineStore
        var session: Session
    }

    /// Builds one scenario's world.
    ///
    /// - Parameter kind: which backend the *request* is built for (P2-04). It
    ///   moves the model id, and the model id is in ``AIRequest/fixtureKey``, so
    ///   `.ollama` reads and writes its own fixtures rather than Claude's
    ///   (ADR-067). It also moves the request timeout (ADR-069).
    static func makeRun(
        _ scenario: Scenario,
        provider: any AIProvider,
        mode: OrganizeMode = .ask,
        kind: AIProviderKind = .claude
    ) async -> Run {
        let library = FakeLibrary()
        await library.add(id: curl, path: "Commands/curl.md", body: curlBody, tags: ["shell", "http"])
        await library.add(id: git, path: "Commands/git.md", body: gitBody, tags: ["git"])
        await library.add(id: authDebug, path: "Auth API debug.md", body: authDebugBody)
        await library.add(id: standup, path: "Meetings/Standup.md", body: standupBody)
        await library.add(id: payReview, path: "Private/Pay review.md", body: payReviewBody)
        // The session note: either a new file, or one of the notes above with
        // this session's text already in it.
        await library.add(id: scenario.sessionNoteID, path: scenario.sessionPath, body: scenario.sessionBody)

        let baselines = InMemoryBaselineStore()
        if let baseline = scenario.baseline {
            try? await baselines.advance(
                scenario.sessionNoteID, to: baseline, at: Date(timeIntervalSince1970: 1_755_900_000)
            )
        }

        let recorder = EventRecorder<OrganizerEvent>()
        let organizer = Organizer(
            provider: provider,
            source: library,
            baselines: baselines,
            applier: FakeApplier(library: library),
            settings: OrganizerSettings(
                mode: mode,
                model: kind.defaultOrganizeModel,
                providerKind: kind,
                excludedFolders: excludedFolders
            ),
            clock: TestClock(),
            observer: recorder.observer
        )
        let session = Session(
            id: sessionID,
            noteIDs: [scenario.sessionNoteID] + scenario.alsoTouched,
            startedAt: endedAt.addingTimeInterval(-300),
            endedAt: endedAt,
            reason: .idle
        )
        return Run(
            organizer: organizer, recorder: recorder, library: library, baselines: baselines, session: session
        )
    }

    /// A provider that records the request and refuses to answer — used to
    /// capture exactly what the builder produces when writing fixtures.
    static func captureProvider() -> ScriptedProvider {
        ScriptedProvider(handlers: [{ _ in throw AIError.badRequest(message: "capture only") }])
    }
}

@Suite("Organize goldens (M2-06)")
struct OrganizeGoldenTests {
    static let store = AITestPaths.recordingStore

    @Test(
        "regenerate the organize goldens",
        .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_WRITE_AI_FIXTURES"] == "1")
    )
    func regenerate() async throws {
        var notesByKey: [String: String] = [:]
        for scenario in OrganizeGolden.scenarios {
            let provider = OrganizeGolden.captureProvider()
            let run = await OrganizeGolden.makeRun(scenario, provider: provider)
            await run.organizer.sessionEnded(run.session)
            await run.organizer.drain()
            guard let request = provider.requests.first else {
                Issue.record("\(scenario.name): no request was built")
                continue
            }
            // Two scenarios can legitimately hash to the same request — the
            // excluded-folder one is *designed* to, since the excluded note
            // contributes nothing. Keep both names on the fixture.
            let line = "\(scenario.name): \(scenario.note)"
            let note = notesByKey[request.fixtureKey].map { "\($0) | \(line)" } ?? "hand-authored (M2-06) — \(line)"
            notesByKey[request.fixtureKey] = note
            let url = try Self.store.save(AIRecording(
                purpose: .organize,
                key: request.fixtureKey,
                model: request.model.id,
                recordedAt: nil,
                note: note,
                request: request,
                requestBody: ClaudeWire.body(for: request),
                responseBody: scenario.response
            ))
            print("wrote \(scenario.name) → \(url.lastPathComponent)")
        }
    }

    @Test("every golden scenario replays end to end", arguments: OrganizeGolden.scenarios)
    func replays(scenario: OrganizeGolden.Scenario) async throws {
        let provider = ReplayProvider(store: Self.store)
        let run = await OrganizeGolden.makeRun(scenario, provider: provider)
        await run.organizer.sessionEnded(run.session)
        await run.organizer.drain()

        switch scenario.name {
        case "nothing-to-do":
            #expect(run.recorder.kinds == ["skipped(nothingToDo)"])
            let baseline = try? await run.baselines.baseline(for: scenario.sessionNoteID)
            #expect(baseline?.text == scenario.sessionBody, "nothing-to-do still advances the baseline")

        case "summary-no-longer-matches":
            #expect(run.recorder.kinds == ["failed"])
            guard case .invalidPlan = run.recorder.failures.first else {
                Issue.record("expected the plan to be discarded, got \(run.recorder.failures)")
                return
            }

        default:
            #expect(run.recorder.kinds == ["proposed"], "\(scenario.name)")
            guard let proposal = run.recorder.proposals.first else { return }
            #expect(proposal.plan.promptVersion == .organize)
            #expect(proposal.plan.model == AIModel.defaultOrganize.id)
            #expect(proposal.plan.neverDeletesUserText)
            #expect(!proposal.plan.summary.isEmpty)
        }
    }

    @Test("the scenarios cover what plan §3 asks of M2-06")
    func coverage() async throws {
        let names = Set(OrganizeGolden.scenarios.map(\.name))
        for required in [
            "new-note", "merge-code-block", "retitle-untitled", "new-folder",
            "nothing-to-do", "convergence", "excluded-folder", "invalid-action-dropped",
        ] {
            #expect(names.contains(required), "missing the \(required) scenario")
        }
        #expect(OrganizeGolden.scenarios.count >= 8)
    }

    @Test("new material with no home lands in the best existing folder")
    func newNote() async throws {
        let plan = try await plan(for: "new-note")
        guard case let .createNote(action) = plan.actions.first else {
            Issue.record("expected a createNote, got \(plan.actions)")
            return
        }
        #expect(action.folderPath == "Commands", "an existing folder, not a new one")
        #expect(action.tags.count <= 5)
        #expect(action.tags.allSatisfy { $0 == $0.lowercased() })
    }

    @Test("merging is a segment move carrying the segment verbatim (amendment 1)")
    func mergeCodeBlock() async throws {
        let plan = try await plan(for: "merge-code-block")
        guard case let .moveSegment(action) = plan.actions.first else {
            Issue.record("expected a moveSegment, got \(plan.actions)")
            return
        }
        #expect(action.segment == OrganizeGolden.curlSegment)
        #expect(OrganizeGolden.scratchWithCurl.contains(action.segment), "verbatim, or apply would refuse it")
        #expect(action.expectedSegmentHash == Hashing.sha256Hex(OrganizeGolden.curlSegment))
        #expect(plan.neverDeletesUserText)
    }

    @Test("an untitled note gets a name and at most five lowercase tags")
    func retitle() async throws {
        let plan = try await plan(for: "retitle-untitled")
        let titles = plan.actions.compactMap { action -> String? in
            if case let .retitleNote(retitle) = action { return retitle.newTitle }
            return nil
        }
        #expect(titles == ["Staging auth token"])
        let tags = plan.actions.flatMap { action -> [String] in
            if case let .tagNote(tag) = action { return tag.tags }
            return []
        }
        #expect(!tags.isEmpty)
        #expect(tags.count <= 5)
        #expect(tags.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") })
    }

    @Test("a new folder is one level deep and is filled in the same plan")
    func newFolder() async throws {
        let plan = try await plan(for: "new-folder")
        let folders = plan.actions.compactMap { action -> String? in
            if case let .createFolder(create) = action { return create.path }
            return nil
        }
        #expect(folders == ["Kubernetes"])
        #expect(PathRules.depth(ofFolder: folders[0]) <= PathRules.maxFolderDepth)
        #expect(plan.actions.contains { action in
            if case let .createNote(create) = action { return create.folderPath == "Kubernetes" }
            return false
        })
    }

    @Test("convergence: an existing note is preferred over new structure (FR-4.6)")
    func convergence() async throws {
        let plan = try await plan(for: "convergence")
        #expect(plan.actions.count == 1)
        #expect(!plan.actions.contains { $0.kind == .createFolder })
        #expect(!plan.actions.contains { $0.kind == .createNote })
        guard case let .appendToNote(action) = plan.actions[0] else {
            Issue.record("expected an append")
            return
        }
        #expect(action.target.id == OrganizeGolden.curl)
    }

    @Test("an invalid action is dropped and the good one survives")
    func invalidActionDropped() async throws {
        let provider = ReplayProvider(store: Self.store)
        let scenario = OrganizeGolden.scenarios.first { $0.name == "invalid-action-dropped" }!
        let run = await OrganizeGolden.makeRun(scenario, provider: provider)
        await run.organizer.sessionEnded(run.session)
        await run.organizer.drain()

        guard let proposal = run.recorder.proposals.first else {
            Issue.record("expected a proposal, got \(run.recorder.kinds)")
            return
        }
        #expect(proposal.plan.actions.count == 1)
        #expect(proposal.droppedActions.count == 1)
        #expect(proposal.droppedActions[0].kind == .unknownNote)
    }

    // MARK: - The request body itself

    @Test("every golden request says which prompt built it, and fits the budget")
    func requestBodies() throws {
        for recording in try Self.store.all() where recording.purpose == .organize {
            guard recording.note?.contains("M2-06") == true else { continue }
            let request = recording.request

            #expect(request.model.id == "claude-sonnet-5")
            #expect(request.effort == .low)
            #expect(request.thinking == .adaptive())
            #expect(request.timeout == 60)
            #expect(request.toolChoice == .tool(name: OrganizationPlan.toolName))
            #expect(request.tools.first?.strict == true)

            let user = request.messages.map(\.text).joined(separator: "\n")
            #expect(user.contains("Prompt: organize.v1"))
            #expect(
                OrganizeContextBuilder.estimatedTokens(of: user) <= OrganizerSettings().tokenBudget,
                "\(recording.key) is over the token budget"
            )
            // The system prompt is the versioned resource, include expanded.
            #expect(request.system?.contains(OrganizeRequestBuilder.includeMarker) != true)
            #expect(request.system?.contains("organization_plan") == true)
        }
    }

    @Test("the excluded note leaves no trace at all — the request is byte-identical without it")
    func excludedNoteChangesNothing() async throws {
        let scenarios = OrganizeGolden.scenarios
        let withExclusion = scenarios.first { $0.name == "excluded-folder" }!
        let without = scenarios.first { $0.name == "merge-code-block" }!
        #expect(withExclusion.alsoTouched == [OrganizeGolden.payReview])
        #expect(without.alsoTouched.isEmpty)

        func request(_ scenario: OrganizeGolden.Scenario) async throws -> AIRequest {
            let provider = OrganizeGolden.captureProvider()
            let run = await OrganizeGolden.makeRun(scenario, provider: provider)
            await run.organizer.sessionEnded(run.session)
            await run.organizer.drain()
            guard let request = provider.requests.first else { throw AIError.malformedResponse("no request") }
            return request
        }
        #expect(try await request(withExclusion).fixtureKey == request(without).fixtureKey)
    }

    @Test("no golden request contains a byte of the excluded folder (FR-4.5)")
    func exclusionsNeverRecorded() throws {
        for recording in try Self.store.all() where recording.purpose == .organize {
            guard recording.note?.contains("M2-06") == true else { continue }
            let haystack = recording.requestBody.allStrings.joined(separator: "\n")
            #expect(!haystack.contains("88888"), "\(recording.key)")
            #expect(!haystack.contains("Pay review"), "\(recording.key)")
            #expect(!haystack.contains("compensation"), "\(recording.key)")
            #expect(!haystack.contains(OrganizeGolden.payReview.uuidString), "\(recording.key)")
            #expect(!haystack.contains("Private"), "\(recording.key)")
        }
    }

    // MARK: - Helpers

    private func plan(for name: String) async throws -> OrganizationPlan {
        let scenario = OrganizeGolden.scenarios.first { $0.name == name }!
        let provider = ReplayProvider(store: Self.store)
        let run = await OrganizeGolden.makeRun(scenario, provider: provider)
        await run.organizer.sessionEnded(run.session)
        await run.organizer.drain()
        guard let proposal = run.recorder.proposals.first else {
            throw AIError.malformedResponse("\(name): no proposal — \(run.recorder.kinds)")
        }
        return proposal.plan
    }
}
