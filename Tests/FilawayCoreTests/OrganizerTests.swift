import Foundation
import Testing

@testable import FilawayCore

/// The M2-05 race matrix. Every scenario is deterministic: a manual clock, a
/// scripted provider behind a gate the test opens, and a fake applier that
/// enforces the same compare-and-swap the real one will.
@Suite("Organizer concurrency (FR-3.2, M2-05)")
struct OrganizerTests {
    // MARK: Fixtures

    static let scratchID = SessionNotes.a
    static let curlID = SessionNotes.b
    static let otherID = SessionNotes.c
    static let privateID = NoteID(UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000004")!)

    static let scratchBody = """
    curl to fetch docs from staging:

    ```sh
    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs
    ```

    remember: token expires hourly
    """
    static let curlBody = "# curl\n\nHandy invocations.\n"

    struct Harness {
        let library: FakeLibrary
        let baselines: InMemoryBaselineStore
        let queue: InMemoryPendingSessionStore
        let applier: FakeApplier
        let provider: ScriptedProvider
        let clock: TestClock
        let recorder: EventRecorder<OrganizerEvent>
        let organizer: Organizer

        func session(
            _ noteIDs: [NoteID],
            id: SessionID = SessionID(),
            reason: SessionEndReason = .idle
        ) -> Session {
            Session(
                id: id,
                noteIDs: noteIDs,
                startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                endedAt: Date(timeIntervalSince1970: 1_756_000_200),
                reason: reason
            )
        }

        func baseline(_ id: NoteID) async -> OrganizedBaseline? {
            try? await baselines.baseline(for: id)
        }

        var lastPromptText: String {
            provider.requests.last?.messages.last?.text ?? ""
        }
    }

    static func harness(
        mode: OrganizeMode = .ask,
        provider: ScriptedProvider,
        excluded: [String] = [],
        maxConcurrent: Int = 2,
        maxQueueAttempts: Int = 8
    ) async -> Harness {
        let library = FakeLibrary()
        await library.add(id: scratchID, path: "Scratch.md", body: scratchBody)
        await library.add(id: curlID, path: "Commands/curl.md", body: curlBody, tags: ["shell"])
        await library.add(id: otherID, path: "Meetings/Standup.md", body: "# Standup\n\nnotes\n")
        await library.add(id: privateID, path: "Private/Salary review.md", body: "the number is 99999\n")

        let baselines = InMemoryBaselineStore()
        let queue = InMemoryPendingSessionStore()
        let applier = FakeApplier(library: library)
        let clock = TestClock()
        let recorder = EventRecorder<OrganizerEvent>()
        let settings = OrganizerSettings(
            mode: mode,
            excludedFolders: excluded,
            maxConcurrentRequests: maxConcurrent,
            retryPolicy: RetryPolicy(maxAttempts: 5, baseDelay: 0, multiplier: 2, maxDelay: 0, jitter: 0),
            maxQueueAttempts: maxQueueAttempts
        )
        let organizer = Organizer(
            provider: provider,
            source: library,
            baselines: baselines,
            applier: applier,
            queueStore: queue,
            settings: settings,
            clock: clock,
            observer: recorder.observer
        )
        return Harness(
            library: library,
            baselines: baselines,
            queue: queue,
            applier: applier,
            provider: provider,
            clock: clock,
            recorder: recorder,
            organizer: organizer
        )
    }

    /// The plan the provider returns unless a test says otherwise: append the
    /// session's snippet to `Commands/curl`.
    static var mergePlan: JSONValue {
        PlanFixtures.toolInput(
            summary: "Curl snippet appended to curl.",
            actions: [PlanFixtures.appendToNote(curlID, content: "curl -H \"Auth: Bearer $TOK\" …", heading: "Staging docs")]
        )
    }

    // MARK: - The happy paths

    @Test("session end → a proposal, and the baseline does not move yet (ask mode)")
    func endProposes() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["proposed"])
        #expect(provider.requestCount == 1)
        let proposal = harness.recorder.proposals[0]
        #expect(proposal.plan.actions.count == 1)
        #expect(proposal.plan.promptVersion == .organize)
        #expect(proposal.noteIDs.contains(Self.scratchID))
        #expect(proposal.noteIDs.contains(Self.curlID), "the plan's target is superseded by typing too")
        #expect(await harness.baseline(Self.scratchID) == nil, "ask mode must not advance a baseline")
        #expect(harness.applier.applied.isEmpty)
    }

    @Test("session end → applied immediately (auto mode), baselines advance to what is on disk")
    func endAutoApplies() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(mode: .auto, provider: provider)
        harness.applier.effect = { _, library in
            await library.setBody(Self.curlBody + "\n## Staging docs\ncurl …\n", for: Self.curlID)
        }

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["applied"])
        #expect(harness.applier.applied.count == 1)
        #expect(harness.recorder.appliedPlans[0].summary == "Curl snippet appended to curl.")
        #expect(await harness.baseline(Self.scratchID)?.text == Self.scratchBody)
        let curlBaseline = await harness.baseline(Self.curlID)
        #expect(curlBaseline?.text.contains("Staging docs") == true, "the baseline is the post-apply text")
    }

    @Test("nothing to do advances the baseline so the same text is never re-sent")
    func nothingToDo() async {
        let provider = ScriptedProvider(plan: PlanFixtures.toolInput(summary: "Nothing needed filing.", actions: []))
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["skipped(nothingToDo)"])
        #expect(await harness.baseline(Self.scratchID)?.text == Self.scratchBody)
    }

    @Test("no effective delta → no request at all")
    func noEffectiveDelta() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)
        try? await harness.baselines.advance(
            Self.scratchID, to: Self.scratchBody + "\n\nmore\n", at: Date(), sessionID: nil
        )
        // The user deleted the line they had added: nothing new to file.
        await harness.library.setBody(Self.scratchBody, for: Self.scratchID)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(provider.requestCount == 0)
        #expect(harness.recorder.kinds == ["skipped(noEffectiveDelta)"])
        #expect(await harness.baseline(Self.scratchID)?.text == Self.scratchBody)
    }

    @Test("a session with no surviving notes is skipped")
    func noNotes() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)
        await harness.library.remove(Self.scratchID)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(provider.requestCount == 0)
        #expect(harness.recorder.kinds == ["skipped(noNotes)"])
    }

    // MARK: - Typing wins

    @Test("typing during an in-flight request cancels it and leaves the baseline alone")
    func typingCancelsInFlight() async {
        let gate = TestGate()
        let provider = ScriptedProvider(gate: gate, plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await waitUntil("the request to reach the provider") { gate.arrivals == 1 }

        await harness.organizer.noteEdited(Self.scratchID)
        gate.open()
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["cancelled"])
        #expect(harness.recorder.proposals.isEmpty)
        #expect(await harness.baseline(Self.scratchID) == nil, "a cancelled request must not advance the baseline")
        #expect(await harness.organizer.dirtyNoteIDs.contains(Self.scratchID))
        #expect(await harness.organizer.inFlightSessionIDs.isEmpty)
    }

    @Test("the cancelled note rides along in the next session, from the same baseline")
    func dirtyNoteFoldedIntoNextSession() async {
        let gate = TestGate()
        let provider = ScriptedProvider(gate: gate, plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await waitUntil("the first request") { gate.arrivals == 1 }
        await harness.organizer.noteEdited(Self.scratchID)
        gate.open()
        await harness.organizer.drain()

        await harness.organizer.sessionEnded(harness.session([Self.otherID]))
        await harness.organizer.drain()

        #expect(provider.requestCount == 2)
        let prompt = harness.lastPromptText
        #expect(prompt.contains(Self.scratchID.uuidString), "the dirty note must be in the next request")
        #expect(prompt.contains(Self.otherID.uuidString))
        #expect(await harness.organizer.dirtyNoteIDs.isEmpty)
    }

    @Test("typing in a note with a plan on screen withdraws it")
    func typingSupersedesPending() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        let proposal = harness.recorder.proposals[0]

        await harness.organizer.noteEdited(Self.scratchID)

        #expect(harness.recorder.kinds == ["proposed", "withdrawn(supersededByEdit)"])
        #expect(await harness.organizer.pendingProposals.isEmpty)
        #expect(await harness.baseline(Self.scratchID) == nil)
        #expect(harness.applier.applied.isEmpty)
        // Accepting a withdrawn proposal is a no-op, not a crash.
        await harness.organizer.accept(proposal.id)
        #expect(harness.applier.applied.isEmpty)
    }

    @Test("typing in the plan's *target* note also withdraws it")
    func typingInTargetSupersedesPending() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        await harness.organizer.noteEdited(Self.curlID)

        #expect(harness.recorder.kinds == ["proposed", "withdrawn(supersededByEdit)"])
    }

    @Test("a newer session over the same notes supersedes the pending plan")
    func newerSessionSupersedesPending() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["proposed", "withdrawn(supersededBySession)", "proposed"])
        #expect(await harness.organizer.pendingProposals.count == 1)
    }

    // MARK: - Accept / Edit / Dismiss (FR-4.2)

    @Test("accept applies the plan and advances every baseline it touched")
    func acceptApplies() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)
        harness.applier.effect = { _, library in
            await library.setBody(Self.curlBody + "\nappended\n", for: Self.curlID)
        }

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        await harness.organizer.accept(harness.recorder.proposals[0].id)

        #expect(harness.recorder.kinds == ["proposed", "applied"])
        #expect(await harness.baseline(Self.scratchID)?.text == Self.scratchBody)
        #expect(await harness.baseline(Self.curlID)?.text.contains("appended") == true)
    }

    @Test("accept after the note changed underneath is stale, and writes nothing")
    func acceptAfterExternalEditIsStale() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        // Another editor (or a sync) rewrote the target note.
        await harness.library.setBody("# curl\n\nsomeone else got here first\n", for: Self.curlID)
        await harness.organizer.accept(harness.recorder.proposals[0].id)

        #expect(harness.recorder.kinds == ["proposed", "stale"])
        #expect(harness.applier.applied.isEmpty)
        #expect(await harness.baseline(Self.curlID) == nil, "a stale plan must not advance a baseline")
        #expect(await harness.baseline(Self.scratchID) == nil)
    }

    @Test("dismiss advances the baseline to the text the plan was made against")
    func dismissAdvancesBaseline() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        // The note has moved on since the plan was made; the baseline must
        // still land on the plan-time text, not on today's.
        await harness.library.setBody(Self.scratchBody + "\n\nlater thought\n", for: Self.scratchID)

        await harness.organizer.dismiss(harness.recorder.proposals[0].id)

        #expect(harness.recorder.kinds == ["proposed", "withdrawn(dismissed)"])
        #expect(await harness.baseline(Self.scratchID)?.text == Self.scratchBody)
        #expect(harness.applier.applied.isEmpty)
    }

    @Test("an edited plan is re-validated before it is applied")
    func editedPlanRevalidated() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        let proposal = harness.recorder.proposals[0]

        // The user retargets the append at a different existing note.
        var edited = proposal.plan
        edited.actions = [.appendToNote(AppendToNoteAction(target: .id(Self.otherID), content: "curl …"))]
        await harness.organizer.accept(proposal.id, plan: edited)

        #expect(harness.recorder.kinds == ["proposed", "applied"])
        #expect(harness.applier.applied[0].actions.count == 1)
        #expect(harness.applier.applied[0].referencedNotes.first?.id == Self.otherID)
    }

    @Test("an edited plan that names a note that does not exist is refused")
    func editedPlanInvalid() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()
        let proposal = harness.recorder.proposals[0]

        var edited = proposal.plan
        edited.actions = [.appendToNote(AppendToNoteAction(target: .id(NoteID()), content: "curl …"))]
        await harness.organizer.accept(proposal.id, plan: edited)

        #expect(harness.recorder.kinds == ["proposed", "failed"])
        guard case .invalidPlan = harness.recorder.failures.first else {
            Issue.record("expected an invalid-plan failure, got \(harness.recorder.failures)")
            return
        }
        #expect(harness.applier.applied.isEmpty)
    }

    // MARK: - Serialization

    @Test("two sessions over different notes run at the same time")
    func disjointSessionsRunInParallel() async {
        let gate = TestGate()
        let provider = ScriptedProvider(gate: gate, plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.sessionEnded(harness.session([Self.otherID]))
        await waitUntil("both requests in flight") { gate.arrivals == 2 }

        #expect(await harness.organizer.inFlightSessionIDs.count == 2)
        gate.open()
        await harness.organizer.drain()
        #expect(provider.requestCount == 2)
    }

    @Test("two sessions sharing a note never overlap")
    func overlappingSessionsSerialize() async {
        let gate = TestGate()
        let provider = ScriptedProvider(gate: gate, plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        let first = harness.session([Self.scratchID, Self.otherID])
        let second = harness.session([Self.otherID])
        await harness.organizer.sessionEnded(first)
        await harness.organizer.sessionEnded(second)
        await waitUntil("the first request") { gate.arrivals == 1 }

        #expect(await harness.organizer.inFlightSessionIDs == [first.id])
        #expect(await harness.organizer.readySessionIDs == [second.id])
        #expect(gate.arrivals == 1, "the second session must wait for the shared note")

        gate.open()
        await harness.organizer.drain()
        #expect(provider.requestCount == 2)
    }

    @Test("no more than two requests run at once")
    func concurrencyCap() async {
        let gate = TestGate()
        let provider = ScriptedProvider(gate: gate, plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.sessionEnded(harness.session([Self.otherID]))
        await harness.organizer.sessionEnded(harness.session([Self.curlID]))
        await waitUntil("two requests in flight") { gate.arrivals == 2 }

        #expect(await harness.organizer.inFlightSessionIDs.count == 2)
        #expect(await harness.organizer.readySessionIDs.count == 1)
        gate.open()
        await harness.organizer.drain()
        #expect(provider.requestCount == 3)
    }

    // MARK: - Degradation (FR-6.4)

    @Test("an offline provider queues the session and never blocks")
    func offlineQueues() async {
        let provider = ScriptedProvider(handlers: [
            { _ in throw AIError.network(code: -1_009, description: "offline") },
            { _ in .toolUse(name: OrganizationPlan.toolName, input: Self.mergePlan) },
        ])
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["queued"])
        #expect(await harness.queue.count == 1)
        #expect(await harness.baseline(Self.scratchID) == nil)

        // The pill goes green: the queue drains itself.
        await harness.organizer.aiStatusChanged(.connected)
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["queued", "retrying", "proposed"])
        #expect(await harness.queue.count == 0)
        #expect(provider.requestCount == 2)
    }

    @Test("an invalid key queues; a bad request does not")
    func queueTaxonomy() {
        #expect(Organizer.shouldQueue(.invalidKey()))
        #expect(Organizer.shouldQueue(.notConfigured))
        #expect(Organizer.shouldQueue(.rateLimited(retryAfter: 30)))
        #expect(Organizer.shouldQueue(.serverOverloaded(status: 529)))
        #expect(Organizer.shouldQueue(.timedOut))
        #expect(!Organizer.shouldQueue(.badRequest(message: "bad")))
        #expect(!Organizer.shouldQueue(.modelNotFound(model: "nope")))
        #expect(!Organizer.shouldQueue(.malformedResponse("junk")))
    }

    @Test("a 400 fails outright rather than queueing forever")
    func badRequestFails() async {
        let provider = ScriptedProvider(failing: .badRequest(message: "schema"))
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["failed"])
        #expect(await harness.queue.count == 0)
    }

    @Test("the queue gives up after the attempt cap")
    func queueGivesUp() async {
        let provider = ScriptedProvider(failing: .network(code: -1_009, description: "offline"))
        let harness = await Self.harness(provider: provider, maxQueueAttempts: 1)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["failed"])
        guard case .abandoned = harness.recorder.failures.first else {
            Issue.record("expected an abandoned failure")
            return
        }
        #expect(await harness.queue.count == 0)
    }

    @Test("a refusal is reported, not retried")
    func refusalFails() async {
        let provider = ScriptedProvider(handlers: [{ request in
            AIResponse(
                id: "msg_refusal",
                model: request.model.id,
                content: [],
                stopReason: .refusal,
                stopDetails: AIStopDetails(type: "refusal", category: "other", explanation: nil),
                usage: AIUsage(inputTokens: 100, outputTokens: 0)
            )
        }])
        let harness = await Self.harness(provider: provider)

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["failed"])
        guard case .decoding = harness.recorder.failures.first else {
            Issue.record("expected a decoding failure, got \(harness.recorder.failures)")
            return
        }
        #expect(await harness.baseline(Self.scratchID) == nil)
    }

    // MARK: - Plan repair (risk #6)

    @Test("an invalid action is dropped when the summary still describes what is left")
    func invalidActionDropped() async {
        let plan = PlanFixtures.toolInput(
            summary: "Curl snippet appended to curl.",
            actions: [
                PlanFixtures.appendToNote(Self.curlID, content: "curl …"),
                PlanFixtures.appendToNote(NoteID(), content: "orphaned"),
            ]
        )
        let harness = await Self.harness(provider: ScriptedProvider(plan: plan))

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["proposed"])
        let proposal = harness.recorder.proposals[0]
        #expect(proposal.plan.actions.count == 1)
        #expect(proposal.droppedActions.count == 1)
    }

    @Test("the whole plan goes when the summary names something only a dropped action touched")
    func summaryNoLongerMatchesDiscardsPlan() async {
        let plan = PlanFixtures.toolInput(
            summary: "Curl snippet appended to curl and a new Compose folder created.",
            actions: [
                PlanFixtures.appendToNote(Self.curlID, content: "curl …"),
                PlanFixtures.createFolder("Commands/Docker/Compose"),
            ]
        )
        let harness = await Self.harness(provider: ScriptedProvider(plan: plan))

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["failed"])
        guard case .invalidPlan = harness.recorder.failures.first else {
            Issue.record("expected an invalid-plan failure")
            return
        }
        #expect(await harness.baseline(Self.scratchID) == nil)
    }

    @Test("a hallucinated action name is a warning, not a lost plan")
    func unknownActionIsAWarning() async {
        let plan = PlanFixtures.toolInput(
            summary: "Curl snippet appended to curl.",
            actions: [
                PlanFixtures.appendToNote(Self.curlID, content: "curl …"),
                .object(["action": "deleteNote", "note": .object(["id": .string(Self.scratchID.uuidString)])]),
            ]
        )
        let harness = await Self.harness(provider: ScriptedProvider(plan: plan))

        await harness.organizer.sessionEnded(harness.session([Self.scratchID]))
        await harness.organizer.drain()

        #expect(harness.recorder.kinds == ["proposed"])
        let proposal = harness.recorder.proposals[0]
        #expect(proposal.plan.actions.count == 1)
        #expect(proposal.validation.hasWarning(.unreadableAction))
    }

    // MARK: - FR-4.5

    @Test("an excluded note in the session never reaches the provider")
    func excludedNoteNeverSent() async {
        let provider = ScriptedProvider(plan: Self.mergePlan)
        let harness = await Self.harness(provider: provider, excluded: ["Private"])

        await harness.organizer.sessionEnded(harness.session([Self.scratchID, Self.privateID]))
        await harness.organizer.drain()

        let body = ClaudeWire.body(for: provider.requests[0])
        let haystack = body.allStrings.joined(separator: "\n")
        #expect(!haystack.contains("99999"))
        #expect(!haystack.contains("Salary review"))
        #expect(!haystack.contains(Self.privateID.uuidString))
        #expect(!haystack.contains("Private"))
        #expect(haystack.contains(Self.scratchID.uuidString))
    }
}

// MARK: - Queue durability across a death mid-retry (P2-06)

/// The live bug: `retryQueuedSessions` deleted the row on pickup, so a quit
/// while the retry was in flight lost the session for good. The row must now
/// outlive the flight and go away only on a terminal outcome.
@Suite("Organizer — the queue survives a death mid-flight")
struct OrganizerQueueDurabilityTests {
    private func pending(_ harness: OrganizerTests.Harness, id: SessionID, attempts: Int = 1) -> PendingSession {
        PendingSession(
            session: harness.session([OrganizerTests.scratchID], id: id),
            attempts: attempts,
            lastError: "timed out",
            nextAttemptAt: nil
        )
    }

    @Test("a cancelled flight keeps the row for the next launch")
    func cancelledFlightKeepsTheRow() async throws {
        // The quit-mid-flight, compressed: the provider dies of cancellation.
        // If pickup still deleted the row, nothing on this path would restore
        // it — the count going to 0 is exactly the lost-session bug.
        let provider = ScriptedProvider(handlers: [{ _ in throw CancellationError() }])
        let harness = await OrganizerTests.harness(provider: provider)
        let id = SessionID()
        try await harness.queue.enqueue(pending(harness, id: id))

        await harness.organizer.retryQueuedSessions()
        await harness.organizer.drain()
        #expect(provider.requestCount == 1, "the retry ran")
        #expect(await harness.queue.count == 1, "a death mid-flight keeps the session (ADR-059, M4-08)")
    }

    @Test("a successful retry clears the row")
    func successClearsTheRow() async throws {
        let provider = ScriptedProvider(plan: OrganizerTests.mergePlan)
        let harness = await OrganizerTests.harness(provider: provider)
        let id = SessionID()
        try await harness.queue.enqueue(pending(harness, id: id))

        await harness.organizer.retryQueuedSessions()
        await harness.organizer.drain()
        #expect(harness.recorder.kinds.contains("proposed"))
        #expect(await harness.queue.count == 0, "proposed is terminal")
    }

    @Test("a terminal failure clears the row; a retryable one re-queues with the attempt count")
    func failuresDisposeCorrectly() async throws {
        // Non-queueable: a bad request is a real failure, not a "come back later".
        var harness = await OrganizerTests.harness(provider: ScriptedProvider(failing: .badRequest(message: "no")))
        var id = SessionID()
        try await harness.queue.enqueue(pending(harness, id: id))
        await harness.organizer.retryQueuedSessions()
        await harness.organizer.drain()
        #expect(await harness.queue.count == 0, "a 400 must not retry forever")

        // Queueable: the row is upserted with attempts+1, never lost.
        harness = await OrganizerTests.harness(provider: ScriptedProvider(failing: .network(code: 1, description: "down")))
        id = SessionID()
        try await harness.queue.enqueue(pending(harness, id: id, attempts: 2))
        await harness.organizer.retryQueuedSessions()
        await harness.organizer.drain()
        let rows = try await harness.queue.all()
        #expect(rows.count == 1)
        #expect(rows.first?.attempts == 3, "the attempt count is durable")
    }
}
