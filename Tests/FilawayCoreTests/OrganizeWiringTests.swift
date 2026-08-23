import Foundation
import Testing

@testable import FilawayCore

/// M2-12: the pieces the app layer needs to hold the organize pipeline over a
/// real library — `OrganizeLibrarySourceLive`, `KeywordCandidateFinder`, the
/// durable `PendingSessionStoreGRDB` — plus one end-to-end replay of the whole
/// rope with the *production* objects and no test doubles except the provider.
///
/// ``AppWiringFixture`` is also the corpus the app's `organize` smoke phase
/// seeds, and its fixture is the one that phase replays. The two definitions
/// are deliberately duplicated (Core tests cannot import `FilawayApp`); keep
/// `Sources/FilawayApp/Features/Organize/OrganizeSmokeCheck.swift` in step —
/// if they drift, replay throws `missingRecording` and the smoke phase fails
/// loudly rather than quietly testing the wrong thing.
enum AppWiringFixture {
    static let curl = NoteID(UUID(uuidString: "60111111-1111-4111-8111-000000000001")!)
    static let git = NoteID(UUID(uuidString: "60222222-2222-4222-8222-000000000002")!)
    static let authDebug = NoteID(UUID(uuidString: "60333333-3333-4333-8333-000000000003")!)
    static let standup = NoteID(UUID(uuidString: "60444444-4444-4444-8444-000000000004")!)
    static let scratch = NoteID(UUID(uuidString: "60666666-6666-4666-8666-000000000006")!)

    /// The session's `endedAt`, pinned so the rendered prompt — and therefore
    /// the fixture key — is the same on every run. The app's smoke hook ends
    /// the session at exactly this instant.
    static let endedAt = Date(timeIntervalSince1970: 1_756_000_200)

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

    /// What the user types in the smoke phase.
    static let curlSegment = """
    ```sh
    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs
    ```
    """

    static let sessionText = """
    curl to fetch docs from staging:

    \(curlSegment)

    remember: the token expires hourly
    """

    /// Figure 2a's card text.
    static let summary = "Code block merged into Commands / curl."

    struct Seed: Sendable {
        var path: String
        var id: NoteID
        var body: String
        var tags: [String]
    }

    /// Every note on disk before the session, in the order the smoke phase
    /// writes them. `Scratch.md` starts empty: it is the session note, and an
    /// empty baseline is what makes the prompt say "new — never filed".
    static var seeds: [Seed] {
        [
            Seed(path: "Commands/curl.md", id: curl, body: curlBody, tags: ["shell", "http"]),
            Seed(path: "Commands/git.md", id: git, body: gitBody, tags: ["git"]),
            Seed(path: "Auth API debug.md", id: authDebug, body: authDebugBody, tags: []),
            Seed(path: "Meetings/Standup.md", id: standup, body: standupBody, tags: []),
            Seed(path: "Scratch.md", id: scratch, body: "", tags: []),
        ]
    }

    /// The raw file text of a seed: front matter pinning the note id (so the
    /// prompt is byte-stable) plus the body.
    static func rawText(_ seed: Seed) -> String {
        var lines = ["---", "id: \(seed.id.uuidString)"]
        if !seed.tags.isEmpty {
            lines.append("tags:")
            lines.append(contentsOf: seed.tags.map { "  - \($0)" })
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + seed.body
    }

    /// The hand-authored reply: Figure 2a, exactly.
    static var response: JSONValue {
        .object([
            "id": .string("msg_wiring"),
            "type": "message",
            "role": "assistant",
            "model": .string(AIModel.defaultOrganize.id),
            "content": .array([
                .object([
                    "type": "tool_use",
                    "id": "toolu_wiring",
                    "name": .string(OrganizationPlan.toolName),
                    "input": PlanFixtures.toolInput(
                        summary: summary,
                        actions: [
                            PlanFixtures.moveSegment(
                                from: scratch, segment: curlSegment,
                                toExisting: curl, heading: "Fetch staging docs"
                            ),
                        ]
                    ),
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

    /// The committed fixture this corpus hashes to. It *is* M2-06's
    /// `merge-code-block` golden: the app wiring reproduces that exact session
    /// over that exact library, so one recording stands behind both the Core
    /// goldens and the `organize` smoke phase.
    static let fixtureKey = "d2e2f83a3797a9c5"

    static let fixtureNote = "hand-authored (M2-12) — app wiring / organize smoke: merge a code block into Commands/curl"

    // MARK: - The wiring, exactly as `OrganizeCoordinator` builds it

    struct Wiring {
        let temp: TempLibrary
        let metadata: MetadataStore
        let activity: ActivityLog
        let applier: PlanApplier
        let undo: UndoService
        let queue: PendingSessionStoreGRDB
        let organizer: Organizer
        let recorder: EventRecorder<OrganizerEvent>

        var store: NoteStore { temp.store }

        func session() -> Session {
            Session(
                id: SessionID(),
                noteIDs: [AppWiringFixture.scratch],
                startedAt: AppWiringFixture.endedAt.addingTimeInterval(-180),
                endedAt: AppWiringFixture.endedAt,
                reason: .idle
            )
        }
    }

    static func wire(provider: any AIProvider, mode: OrganizeMode = .ask) async throws -> Wiring {
        let temp = try TempLibrary()
        try await temp.store.prepare()
        for seed in seeds {
            let folder = PathRules.folderPath(of: seed.path)
            if !folder.isEmpty { try await temp.store.createFolder(folder) }
            _ = try await temp.store.writeRaw(rawText(seed), to: seed.path)
        }
        // The session's own text, written the way the editor's autosave writes
        // it — `NoteStore.save(body:)`, which keeps the front-matter id.
        _ = try await temp.store.save(body: sessionText, to: "Scratch.md")

        let metadata = try MetadataStore(library: temp.library)
        try await metadata.rebuild(from: temp.store.scan(settleWindow: 0))
        let activity = try ActivityLog(library: temp.library)
        let applier = PlanApplier(store: temp.store, activity: activity)
        let undo = UndoService(store: temp.store, activity: activity)
        let queue = try PendingSessionStoreGRDB(library: temp.library)
        let recorder = EventRecorder<OrganizerEvent>()

        let organizer = Organizer(
            provider: provider,
            source: OrganizeLibrarySourceLive(store: temp.store),
            baselines: activity,
            applier: applier,
            candidateFinder: KeywordCandidateFinder(search: SearchService(metadata: metadata)),
            queueStore: queue,
            settings: OrganizerSettings(mode: mode),
            observer: recorder.observer
        )
        return Wiring(
            temp: temp, metadata: metadata, activity: activity, applier: applier,
            undo: undo, queue: queue, organizer: organizer, recorder: recorder
        )
    }
}

// MARK: - The live library source

@Suite("Organize app wiring (M2-12)")
struct OrganizeWiringTests {

    @Test("the live source reads the library from disk, not from the database")
    func liveSourceReadsDisk() async throws {
        let temp = try TempLibrary()
        try await temp.store.prepare()
        try await temp.store.createFolder("Commands")
        let note = try await temp.store.save(body: "# curl\n\nhandy\n", to: "Commands/curl.md")
        let source = OrganizeLibrarySourceLive(store: temp.store)

        let snapshot = try await source.snapshot()
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.folderPaths.contains("Commands"))
        #expect(try await source.body(of: note.id) == "# curl\n\nhandy\n")

        // A write that no database has heard about yet is still visible, which
        // is the point: preconditions must be hashes of the bytes on disk.
        _ = try await temp.store.save(body: "# curl\n\nhandier\n", to: "Commands/curl.md")
        #expect(try await source.body(of: note.id) == "# curl\n\nhandier\n")
        let second = try await source.snapshot()
        #expect(second.notes.first?.contentHash != snapshot.notes.first?.contentHash)
    }

    @Test("the live source follows a note that moved, and reports a note that is gone")
    func liveSourceFollowsMoves() async throws {
        let temp = try TempLibrary()
        try await temp.store.prepare()
        let note = try await temp.store.save(body: "body\n", to: "Scratch.md")
        let source = OrganizeLibrarySourceLive(store: temp.store)
        _ = try await source.snapshot()

        try await temp.store.createFolder("Commands")
        _ = try await temp.store.move("Scratch.md", toFolder: "Commands")
        #expect(try await source.body(of: note.id) == "body\n")
        #expect(try await source.body(of: NoteID()) == nil)
    }

    // MARK: - Candidates

    @Test("keyword candidates find a note whose title says nothing about the subject")
    func keywordFindsBodyOnlyMatch() async throws {
        let temp = try TempLibrary()
        try await temp.store.prepare()
        _ = try await temp.store.save(body: "# Tuesday\n\nkubectl rollout restart deployment/api\n", to: "Tuesday.md")
        _ = try await temp.store.save(body: "# Groceries\n\nmilk, bread\n", to: "Groceries.md")
        let session = try await temp.store.save(body: "kubectl notes\n", to: "Scratch.md")
        let metadata = try MetadataStore(library: temp.library)
        let snapshot = try await temp.store.scan(settleWindow: 0)
        try await metadata.rebuild(from: snapshot)

        let context = OrganizeContext(snapshot: snapshot, excludedFolders: [], bodies: [:])
        let query = CandidateQuery(
            text: "kubectl rollout restart deployment", titles: ["Scratch"],
            excluding: [session.id], limit: 3
        )
        let overlap = try await TitleOverlapCandidateFinder().candidates(for: query, in: context)
        #expect(!overlap.contains { $0.noteID == snapshot.notes.first { $0.title == "Tuesday" }?.id },
                "title overlap cannot see the body")

        let finder = KeywordCandidateFinder(search: SearchService(metadata: metadata))
        let ranked = try await finder.candidates(for: query, in: context)
        let tuesday = snapshot.notes.first { $0.title == "Tuesday" }?.id
        #expect(ranked.first?.noteID == tuesday)
        #expect(!ranked.contains { $0.noteID == session.id }, "the session note is never its own merge target")
    }

    @Test("keyword candidates degrade to title overlap when the index is empty")
    func keywordDegradesToOverlap() async throws {
        let temp = try TempLibrary()
        try await temp.store.prepare()
        try await temp.store.createFolder("Commands")
        _ = try await temp.store.save(body: "# curl\n", to: "Commands/curl.md")
        _ = try await temp.store.save(body: "# git\n", to: "Commands/git.md")
        let session = try await temp.store.save(body: "curl things\n", to: "Scratch.md")
        let snapshot = try await temp.store.scan(settleWindow: 0)
        // A database with no text indexed at all — the launch race M2-12 has to
        // survive.
        let metadata = try MetadataStore(inMemoryFor: temp.library)
        try await metadata.rebuild(from: snapshot, indexingText: false)

        let context = OrganizeContext(snapshot: snapshot, excludedFolders: [], bodies: [:])
        let query = CandidateQuery(text: "curl fetch docs", titles: ["Scratch"], excluding: [session.id], limit: 3)
        let finder = KeywordCandidateFinder(search: SearchService(metadata: metadata))
        let ranked = try await finder.candidates(for: query, in: context)
        let overlap = try await TitleOverlapCandidateFinder().candidates(for: query, in: context)
        #expect(ranked.map(\.noteID) == overlap.map(\.noteID))
    }

    // MARK: - The durable queue (M2-09, FR-6.4)

    @Test("a queued session survives closing and reopening the database")
    func pendingQueueRoundTrips() async throws {
        let temp = try TempLibrary()
        let sessionID = SessionID()
        let noteID = NoteID()
        let pending = PendingSession(
            id: sessionID,
            noteIDs: [noteID],
            startedAt: Date(timeIntervalSince1970: 1_756_000_000),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .appResignedActive,
            attempts: 2,
            lastError: "The network is unavailable.",
            nextAttemptAt: Date(timeIntervalSince1970: 1_756_000_400)
        )
        do {
            let queue = try PendingSessionStoreGRDB(library: temp.library)
            try await queue.enqueue(pending)
            #expect(try await queue.count() == 1)
        }
        // A second store on the same file is a relaunch.
        let reopened = try PendingSessionStoreGRDB(library: temp.library)
        let all = try await reopened.all()
        #expect(all == [pending])
        #expect(all.first?.session.noteIDs == [noteID])

        try await reopened.remove(sessionID)
        #expect(try await reopened.all().isEmpty)
    }

    @Test("re-enqueuing the same session updates its attempt count rather than duplicating it")
    func pendingQueueUpserts() async throws {
        let temp = try TempLibrary()
        let queue = try PendingSessionStoreGRDB(inMemoryFor: temp.library)
        let session = Session(
            noteIDs: [NoteID()],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            reason: .idle
        )
        try await queue.enqueue(PendingSession(session: session, attempts: 1))
        try await queue.enqueue(PendingSession(session: session, attempts: 2, lastError: "rate limited"))
        let all = try await queue.all()
        #expect(all.count == 1)
        #expect(all.first?.attempts == 2)
        #expect(all.first?.lastError == "rate limited")
    }

    @Test("the queue comes back oldest first")
    func pendingQueueOrders() async throws {
        let temp = try TempLibrary()
        let queue = try PendingSessionStoreGRDB(inMemoryFor: temp.library)
        for offset in [300.0, 100.0, 200.0] {
            try await queue.enqueue(PendingSession(session: Session(
                noteIDs: [NoteID()],
                startedAt: Date(timeIntervalSince1970: offset - 50),
                endedAt: Date(timeIntervalSince1970: offset),
                reason: .idle
            )))
        }
        let ends = try await queue.all().map(\.endedAt.timeIntervalSince1970)
        #expect(ends == [100, 200, 300])
    }

    @Test("an offline organizer queues durably and drains when health returns")
    func offlineQueueDrainsAfterRelaunch() async throws {
        let temp = try TempLibrary()
        try await temp.store.prepare()
        let note = try await temp.store.save(body: "something new\n", to: "Scratch.md")
        let queue = try PendingSessionStoreGRDB(library: temp.library)
        let session = Session(
            noteIDs: [note.id],
            startedAt: Date(timeIntervalSince1970: 1_756_000_000),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .idle
        )

        let offline = EventRecorder<OrganizerEvent>()
        let first = Organizer(
            provider: MockProvider.failing(.network(code: URLError.notConnectedToInternet.rawValue, description: "offline")),
            source: OrganizeLibrarySourceLive(store: temp.store),
            baselines: InMemoryBaselineStore(),
            applier: NullApplier(),
            queueStore: queue,
            observer: offline.observer
        )
        await first.sessionEnded(session)
        await first.drain()
        #expect(offline.kinds == ["queued"])
        #expect(try await queue.count() == 1, "the queue is on disk, not in the organizer")

        // Relaunch: a brand-new organizer over the same file finds the session.
        let reopened = try PendingSessionStoreGRDB(library: temp.library)
        let online = EventRecorder<OrganizerEvent>()
        let second = Organizer(
            provider: ScriptedProvider(plan: PlanFixtures.toolInput(summary: "Nothing needed filing.", actions: [])),
            source: OrganizeLibrarySourceLive(store: temp.store),
            baselines: InMemoryBaselineStore(),
            applier: NullApplier(),
            queueStore: reopened,
            observer: online.observer
        )
        // Health is back *and* the backoff has elapsed — the pill's own
        // `aiStatusChanged(.connected)` does the same thing at `now`.
        await second.aiStatusChanged(.connected)
        await second.retryQueuedSessions(at: Date().addingTimeInterval(3_600))
        await second.drain()
        #expect(online.kinds == ["retrying", "skipped(nothingToDo)"])
        #expect(try await reopened.count() == 0)
    }

    // MARK: - End to end, on the production objects

    @Test("the app wiring asks for exactly the fixture the smoke phase replays")
    func wiringHitsTheCommittedFixture() async throws {
        let provider = ScriptedProvider(handlers: [{ _ in throw AIError.badRequest(message: "capture only") }])
        let wiring = try await AppWiringFixture.wire(provider: provider)
        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()
        let request = try #require(provider.requests.first)
        // The fixture key *is* a hash of the request, so this one line pins the
        // whole prompt: the library render, the delta, the candidate ranking and
        // the ended-at stamp. Break one of them by accident and the `organize`
        // smoke phase would otherwise fail much later with a bare
        // `missingRecording`; break one on purpose and this names the fixture to
        // author.
        #expect(request.fixtureKey == AppWiringFixture.fixtureKey)
        #expect(try AITestPaths.recordingStore.load(for: request) != nil)
    }

    /// Writes a fixture when the wiring's request is one nothing has recorded.
    /// Never overwrites: the ask-mode request lands exactly on M2-06's
    /// `merge-code-block` golden, whose note and hand-authored response belong
    /// to the goldens. `Mode:` is in the prompt, so auto mode is its own key and
    /// its own fixture.
    @Test("author the app-wiring organize fixtures if they are missing",
          .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_WRITE_AI_FIXTURES"] == "1"))
    func regenerateFixture() async throws {
        for mode in OrganizeMode.allCases {
            let provider = ScriptedProvider(handlers: [{ _ in throw AIError.badRequest(message: "capture only") }])
            let wiring = try await AppWiringFixture.wire(provider: provider, mode: mode)
            await wiring.organizer.sessionEnded(wiring.session())
            await wiring.organizer.drain()
            let request = try #require(provider.requests.first)
            guard try AITestPaths.recordingStore.load(for: request) == nil else {
                print("\(mode.rawValue): already recorded as \(request.fixtureKey).json — left alone")
                continue
            }
            let url = try AITestPaths.recordingStore.save(AIRecording(
                purpose: .organize,
                key: request.fixtureKey,
                model: request.model.id,
                recordedAt: nil,
                note: "\(AppWiringFixture.fixtureNote) (\(mode.rawValue) mode)",
                request: request,
                requestBody: ClaudeWire.body(for: request),
                responseBody: AppWiringFixture.response
            ))
            print("wrote \(mode.rawValue) app-wiring fixture → \(url.lastPathComponent)")
        }
    }

    @Test("ask mode: propose, accept, apply, undo — production applier, log and queue")
    func endToEndAskMode() async throws {
        let wiring = try await AppWiringFixture.wire(
            provider: ReplayProvider(store: AITestPaths.recordingStore)
        )
        let before = try await wiring.store.read("Commands/curl.md").body
        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        let proposal = try #require(wiring.recorder.proposals.first, "the card never appeared: \(wiring.recorder.kinds)")
        #expect(proposal.plan.summary == AppWiringFixture.summary)
        #expect(proposal.plan.actions.count == 1)

        await wiring.organizer.accept(proposal.id)
        await wiring.organizer.drain()
        let applied = try #require(wiring.recorder.appliedPlans.first)

        // The bytes moved.
        let curl = try await wiring.store.read("Commands/curl.md").body
        #expect(curl.contains("api.st.app/v2/docs"))
        #expect(curl.contains("## Fetch staging docs"))
        let scratch = try await wiring.store.read("Scratch.md").body
        #expect(!scratch.contains("api.st.app/v2/docs"))
        #expect(scratch.contains("the token expires hourly"), "nothing but the segment moved")

        // Activity has it, with a diff and the raw session text (FR-4.3/4.4).
        let events = try await wiring.activity.events(limit: 5)
        #expect(events.first?.id == applied.eventID)
        // The row's own `summary` is the applier's account of what it did; the
        // model's Figure 2a sentence rides along on the stored plan, which is
        // where the card and the Activity window read it from.
        #expect(events.first?.plan?.summary == AppWiringFixture.summary)
        let diffs = try await wiring.activity.diff(for: applied.eventID)
        #expect(diffs.contains { $0.noteID == AppWiringFixture.curl && $0.diff.insertedLineCount > 0 })

        // Undo puts every byte back (FR-4.3).
        let result = try await wiring.undo.undoLatest()
        #expect(result.outcome == .complete)
        #expect(try await wiring.store.read("Commands/curl.md").body == before)
        #expect(try await wiring.store.read("Scratch.md").body == AppWiringFixture.sessionText)
    }

    @Test("auto mode applies without asking, and the baseline advances")
    func endToEndAutoMode() async throws {
        let wiring = try await AppWiringFixture.wire(
            provider: ReplayProvider(store: AITestPaths.recordingStore), mode: .auto
        )
        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        #expect(wiring.recorder.kinds == ["applied"], "\(wiring.recorder.kinds) \(wiring.recorder.failures)")
        let applied = try #require(wiring.recorder.appliedPlans.first)
        #expect(applied.summary.isEmpty == false)
        #expect(try await wiring.store.read("Commands/curl.md").body.contains("api.st.app/v2/docs"))
        let baseline = try await wiring.activity.baseline(for: AppWiringFixture.scratch)
        #expect(baseline != nil, "a completed pipeline advances the baseline")
    }

    @Test("offline: nothing changes, the session is queued, capture is untouched")
    func endToEndOffline() async throws {
        let wiring = try await AppWiringFixture.wire(
            provider: MockProvider.failing(.network(code: URLError.notConnectedToInternet.rawValue, description: "offline"))
        )
        let before = try await wiring.store.read("Commands/curl.md").body
        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        #expect(wiring.recorder.kinds == ["queued"])
        #expect(try await wiring.store.read("Commands/curl.md").body == before)
        #expect(try await wiring.store.read("Scratch.md").body == AppWiringFixture.sessionText)
        #expect(try await wiring.queue.count() == 1)
        #expect(try await wiring.activity.events(limit: 5).isEmpty)
    }
}

/// An applier for the queue tests, which never get as far as a plan.
private struct NullApplier: PlanApplying {
    func apply(_ plan: OrganizationPlan) async throws -> AppliedPlan {
        AppliedPlan(eventID: ActivityEventID(), summary: plan.summary, appliedAt: Date())
    }
}
