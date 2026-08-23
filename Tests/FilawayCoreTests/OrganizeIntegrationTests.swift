import Foundation
import Testing

@testable import FilawayCore

/// The seam M2-05 and M2-07 were built either side of, exercised for real
/// (ADR-033): the `Organizer` actor, the *real* `PlanApplier`, the `ActivityLog`
/// standing in as the `BaselineStore`, and `UndoService` — over a temp library
/// on disk, with a `MockProvider` in place of the model.
///
/// Everything else in these suites uses a double on one side or the other. This
/// is the one place where a plan travels the whole way: session end → prompt →
/// plan → compare-and-swap → files on disk → Activity event → baseline → Undo.
@Suite("Organize integration (Organizer + PlanApplier + ActivityLog)")
struct OrganizeIntegrationTests {
    static let scratchBody = """
    curl to fetch docs from staging:

    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs

    remember: token expires hourly
    """
    static let curlBody = "# curl\n\nHandy invocations.\n"
    static let appended = "curl -H \"Auth: Bearer $TOK\" https://api.st.app/v2/docs"

    /// The `OrganizeLibrarySource` the app will assemble from `MetadataStore`
    /// and `NoteStore`. A two-note library needs no cache, so this rescans.
    struct StoreSource: OrganizeLibrarySource {
        let store: NoteStore

        func snapshot() async throws -> LibrarySnapshot {
            try await store.scan(settleWindow: 0)
        }

        func body(of noteID: NoteID) async throws -> String? {
            let snapshot = try await snapshot()
            guard let note = snapshot.notes.first(where: { $0.id == noteID }) else { return nil }
            return try await store.read(note.relativePath).body
        }
    }

    /// A library, an applier, a log, an undo service and an organizer wired to
    /// each other exactly as the app will wire them.
    struct Wiring {
        let harness: ApplyHarness
        let organizer: Organizer
        let recorder: EventRecorder<OrganizerEvent>
        let scratchID: NoteID
        let curlID: NoteID

        func session() -> Session {
            Session(
                id: SessionID(),
                noteIDs: [scratchID],
                startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                endedAt: Date(timeIntervalSince1970: 1_756_000_200),
                reason: .idle
            )
        }

        func body(_ path: String) async throws -> String {
            try await harness.body(path)
        }
    }

    static func wire(mode: OrganizeMode) async throws -> Wiring {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", scratchBody)
        try await harness.seed("Commands/curl.md", curlBody, tags: ["shell"])
        let scratchID = try await harness.id(of: "Scratch.md")
        let curlID = try await harness.id(of: "Commands/curl.md")

        // The model always answers with the same plan: merge the session's
        // snippet into the note that already covers curl (FR-4.6 convergence).
        let plan = PlanFixtures.toolInput(
            summary: "Curl snippet appended to curl.",
            actions: [PlanFixtures.appendToNote(curlID, content: appended, heading: "Staging docs")]
        )
        let provider = MockProvider { _ in .toolUse(name: OrganizationPlan.toolName, input: plan) }
        let recorder = EventRecorder<OrganizerEvent>()

        let organizer = Organizer(
            provider: provider,
            source: StoreSource(store: harness.store),
            // The production baseline store: `note_baselines`, through the log.
            baselines: harness.activity,
            // The production applier: journalled, transactional, undoable.
            applier: harness.applier,
            settings: OrganizerSettings(mode: mode),
            clock: TestClock(),
            observer: recorder.observer
        )
        return Wiring(
            harness: harness,
            organizer: organizer,
            recorder: recorder,
            scratchID: scratchID,
            curlID: curlID
        )
    }

    @Test("auto mode files a session end to end: files written, journalled, baselines advanced")
    func autoModeEndToEnd() async throws {
        let wiring = try await Self.wire(mode: .auto)
        let harness = wiring.harness

        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        #expect(wiring.recorder.kinds == ["applied"])
        let applied = try #require(wiring.recorder.appliedPlans.first)
        #expect(applied.summary.isEmpty == false)
        #expect(applied.outcomes.count == 1)
        #expect(applied.outcomes[0].kind == .appendToNote)
        #expect(applied.isComplete)

        // The bytes really moved.
        let curl = try await wiring.body("Commands/curl.md")
        #expect(curl.contains(Self.appended))
        #expect(curl.contains("## Staging docs"))

        // One Activity event, applied and undoable, carrying both images.
        let event = try #require(await harness.activity.event(applied.eventID))
        #expect(event.kind == .applied)
        #expect(event.status == .applied)
        #expect(event.isUndoable)
        #expect(event.images.count == 1)

        // The baselines advanced through the *same* `ActivityLog`, to what is on
        // disk after the apply — so the next session sees no delta at all.
        let curlBaseline = try #require(await harness.activity.baseline(for: wiring.curlID))
        #expect(curlBaseline.text == curl)
        let scratchBaseline = try #require(await harness.activity.baseline(for: wiring.scratchID))
        #expect(scratchBaseline.text == Self.scratchBody)
        harness.track(applied)
    }

    @Test("ask mode: propose → accept → applied, and Undo puts every byte back")
    func askModeAcceptThenUndo() async throws {
        let wiring = try await Self.wire(mode: .ask)
        let harness = wiring.harness
        let before = harness.fingerprint()

        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        #expect(wiring.recorder.kinds == ["proposed"])
        let proposal = try #require(wiring.recorder.proposals.first)
        #expect(proposal.noteIDs.contains(wiring.curlID), "the plan's target is part of the proposal")
        #expect(try await harness.body("Commands/curl.md") == Self.curlBody, "ask mode writes nothing")
        #expect(try await harness.activity.baseline(for: wiring.curlID) == nil)

        // Accept: the same plan, now through the real applier's compare-and-swap.
        await wiring.organizer.accept(proposal.id)
        #expect(wiring.recorder.kinds == ["proposed", "applied"])
        let applied = try #require(wiring.recorder.appliedPlans.first)
        harness.track(applied)
        #expect(applied.sessionID == proposal.sessionID)
        #expect(try await harness.body("Commands/curl.md").contains(Self.appended))
        #expect(harness.fingerprint() != before)

        // Undo, through the event the applier journalled.
        let undone = try await harness.undoLatest()
        #expect(undone.eventID == applied.eventID)
        #expect(undone.outcome == .complete)
        #expect(harness.fingerprint() == before, "Undo restores the tree byte for byte")
        #expect(try await harness.body("Commands/curl.md") == Self.curlBody)
    }
}
