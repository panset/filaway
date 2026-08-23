import Foundation
import Testing

@testable import FilawayCore

/// M4-08 — the two halves of FR-4.4's promise about the past.
///
/// * **Keep what was promised.** Raw session text is recoverable for at least
///   30 days, and a before/after image is never dropped while its event is
///   still undoable — pruning "old" data that Undo still needs would turn a
///   retention policy into data loss.
/// * **Actually run.** Retention that nothing calls is a comment.
///   ``MaintenanceScheduler`` is what calls it, once a day, off a durable stamp
///   and an injected clock.
///
/// And the gap this task closed: the automatic path now carries the session's
/// raw text all the way to the Activity row.
@Suite("Retention and maintenance (FR-4.4)")
struct ReliabilityRetentionTests {

    // MARK: - Retention

    @Test("Raw session text is still there on day 30 and gone on day 31")
    func sessionTextSurvivesThirtyDays() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock)
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))]),
            sessionText: "everything the user typed that afternoon"
        )

        // FR-4.4 says "at least 30 days", so the boundary itself must keep it.
        clock.advance(ActivityLog.sessionTextRetention - 60)
        #expect(try await harness.activity.prune(now: clock.date).sessionTextsPruned == 0)
        #expect(
            try await harness.activity.sessionText(for: applied.eventID)
                == "everything the user typed that afternoon"
        )

        clock.advance(24 * 60 * 60)
        #expect(try await harness.activity.prune(now: clock.date).sessionTextsPruned == 1)
        #expect(try await harness.activity.sessionText(for: applied.eventID) == nil)
        #expect(try await harness.activity.eventCount() == 1, "the event itself is history, not data")
    }

    @Test("An undoable event keeps its images however old it gets")
    func undoableImagesAreNeverPruned() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock)
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))]),
            sessionText: "raw"
        )

        // A year later, and pruned three times for good measure.
        clock.advance(365 * 24 * 60 * 60)
        for _ in 0 ..< 3 { _ = try await harness.activity.prune(now: clock.date) }

        let event = try #require(await harness.activity.event(applied.eventID))
        #expect(event.isUndoable)
        #expect(event.images.count == 1)
        #expect(event.images[0].before?.text.contains("start") == true)
        // Which is to say: Undo still works, a year on.
        let result = try await harness.undoLatest()
        #expect(result.outcome == .complete)
        #expect(try await harness.body("Notes.md") == "start\n")
    }

    @Test("Images go only once the event is past Undo's reach")
    func imagesGoWhenTheEventNoLongerUndoable() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock)
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))])
        )
        // Undoing it is what makes it no longer undoable.
        try await harness.undoLatest()
        clock.advance(ActivityLog.sessionTextRetention + 86_400)

        let report = try await harness.activity.prune(now: clock.date)
        #expect(report.eventsStrippedOfImages >= 1)
        let event = try #require(await harness.activity.event(applied.eventID))
        #expect(event.images.isEmpty)
        #expect(!event.isUndoable)
    }

    @Test("A journal row awaiting recovery is never stripped, however old")
    func inProgressRowsSurvivePruning() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock, failureHook: .crash(at: { step in
            if case .appendToNote = step { return true }
            return false
        }))
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        await expectThrows(try await harness.applier.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))])
        )) { $0 is ApplyError }

        clock.advance(400 * 24 * 60 * 60)
        _ = try await harness.activity.prune(now: clock.date)

        // The images are the only thing that can put the files back.
        let incomplete = try await harness.activity.incompleteEvents()
        #expect(incomplete.count == 1)
        #expect(!incomplete[0].images.isEmpty)
        _ = harness.restart()
        #expect(try await harness.recover()[0].resolution == .rolledBack)
        #expect(try await harness.body("Notes.md") == "start\n")
    }

    // MARK: - MaintenanceScheduler

    @Test("The prune runs once a day, not once a launch")
    func schedulerRunsOncePerDay() async throws {
        let temp = try TempLibrary()
        let clock = ApplyClock()
        let scheduler = MaintenanceScheduler(library: temp.library, clock: clock.now)
        let runs = Counter()

        #expect(await scheduler.isDue(.activityPrune), "never run means due")
        #expect(await scheduler.runIfDue(.activityPrune) { runs.increment() })
        #expect(runs.count == 1)

        // Three more launches in the same hour: nothing happens.
        clock.advance(60 * 60)
        for _ in 0 ..< 3 { _ = await scheduler.runIfDue(.activityPrune) { runs.increment() } }
        #expect(runs.count == 1)

        clock.advance(24 * 60 * 60)
        #expect(await scheduler.runIfDue(.activityPrune) { runs.increment() })
        #expect(runs.count == 2)
    }

    @Test("The stamp survives a relaunch, and a backwards clock does not lock it out")
    func schedulerStampIsDurable() async throws {
        let temp = try TempLibrary()
        let clock = ApplyClock()
        do {
            let scheduler = MaintenanceScheduler(library: temp.library, clock: clock.now)
            await scheduler.markRan(.activityPrune)
        }
        clock.advance(60 * 60)

        // "Relaunch": a brand-new scheduler reads the stamp off disk.
        let relaunched = MaintenanceScheduler(library: temp.library, clock: clock.now)
        #expect(await relaunched.isDue(.activityPrune) == false)
        #expect(await relaunched.lastRun(.activityPrune) != nil)

        // A restored backup or a timezone fix can move the clock backwards; a
        // stamp in the future must not silence maintenance forever.
        clock.advance(-100 * 24 * 60 * 60)
        let rewound = MaintenanceScheduler(library: temp.library, clock: clock.now)
        #expect(await rewound.isDue(.activityPrune))
    }

    @Test("A corrupt stamp file is treated as 'never ran', not as a failure")
    func schedulerSurvivesAGarbageStamp() async throws {
        let temp = try TempLibrary()
        try FileManager.default.createDirectory(
            at: temp.library.supportDirectory, withIntermediateDirectories: true
        )
        let stamp = temp.library.supportDirectory.appendingPathComponent("maintenance.json")
        try Data("{{{ not json".utf8).write(to: stamp)

        let scheduler = MaintenanceScheduler(library: temp.library)
        #expect(await scheduler.isDue(.activityPrune))
        await scheduler.markRan(.activityPrune)
        #expect(await scheduler.isDue(.activityPrune) == false)
    }

    @Test("Scheduled pruning enforces the 30-day window across simulated launches")
    func schedulerDrivesTheRealPrune() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock)
        let scheduler = MaintenanceScheduler(library: harness.library, clock: clock.now)
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))]),
            sessionText: "raw session text"
        )

        // Thirty-one launches, one a day. Only the days that come due prune.
        let activity = harness.activity
        for _ in 0 ..< 31 {
            clock.advance(24 * 60 * 60)
            await scheduler.runIfDue(.activityPrune) { [clock] in
                _ = try? await activity.prune(now: clock.date)
            }
        }
        #expect(try await harness.activity.sessionText(for: applied.eventID) == nil)
    }

    // MARK: - FR-4.4's raw session text on the automatic path

    @Test("Every applied event on the automatic path has its raw session text")
    func autoPathRecordsRawSessionText() async throws {
        let wiring = try await OrganizeIntegrationTests.wire(mode: .auto)
        let harness = wiring.harness

        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        let applied = try #require(wiring.recorder.appliedPlans.first)
        let text = try #require(
            await harness.activity.sessionText(for: applied.eventID),
            "FR-4.4: the automatic path must file the raw session text"
        )
        // It is the *session's* material, verbatim — not the whole note, and
        // not a summary of it.
        #expect(text.contains("curl -H \"Auth: Bearer $TOK\""))
        #expect(text.contains("remember: token expires hourly"))

        let event = try #require(await harness.activity.event(applied.eventID))
        #expect(event.hasSessionText)
        harness.track(applied)
    }

    @Test("The ask path carries the same text from proposal to applied event")
    func askPathRecordsRawSessionText() async throws {
        let wiring = try await OrganizeIntegrationTests.wire(mode: .ask)
        let harness = wiring.harness

        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()
        let proposal = try #require(wiring.recorder.proposals.first)
        let proposed = try #require(proposal.sessionText)

        await wiring.organizer.accept(proposal.id)
        await wiring.organizer.drain()
        let applied = try #require(wiring.recorder.appliedPlans.first)
        #expect(try await harness.activity.sessionText(for: applied.eventID) == proposed)
        harness.track(applied)
    }

    @Test("Raw session text is the new material, not the note it was typed into")
    func rawSessionTextIsTheDelta() {
        let one = SessionDelta(
            noteID: NoteID(),
            title: "Scratch",
            relativePath: "Scratch.md",
            baselineText: "old line\n",
            currentText: "old line\nbrand new line\n"
        )
        #expect(SessionDelta.rawSessionText(of: [one]) == "brand new line")

        let two = SessionDelta(
            noteID: NoteID(),
            title: "Auth",
            relativePath: "Auth.md",
            baselineText: "",
            currentText: "token expires hourly\n"
        )
        let both = try? #require(SessionDelta.rawSessionText(of: [one, two]))
        #expect(both?.contains("## Scratch") == true)
        #expect(both?.contains("## Auth") == true)
        #expect(both?.contains("brand new line") == true)
        #expect(both?.contains("old line") == false, "the baseline is not session text")

        // Deleting and reflowing add nothing, so there is no session to record.
        let nothing = SessionDelta(
            noteID: NoteID(), title: "T", relativePath: "T.md",
            baselineText: "a\nb\n", currentText: "a\n"
        )
        #expect(SessionDelta.rawSessionText(of: [nothing]) == nil)
    }
}
