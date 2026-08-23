import Foundation
import Testing

@testable import FilawayCore

// MARK: - The rules, synchronously

@Suite("Session rules (FR-3.1)")
struct SessionMachineTests {
    private let start = Date(timeIntervalSince1970: 1_756_000_000)

    private func machine(
        idle: TimeInterval = 180,
        grace: TimeInterval = 30
    ) -> SessionMachine {
        SessionMachine(
            configuration: SessionConfiguration(idleInterval: idle, gracePeriod: grace),
            makeID: { SessionID(UUID(uuidString: "5E551000-0000-4000-8000-000000000001")!) }
        )
    }

    @Test("a session starts on the first edit, not on scrolling")
    func startsOnEdit() {
        var machine = machine()
        #expect(machine.handle(.activity(SessionNotes.a, .scroll), at: start).isEmpty)
        #expect(machine.handle(.activity(SessionNotes.a, .selection), at: start).isEmpty)
        #expect(!machine.isSessionActive)

        let outputs = machine.handle(.edit(SessionNotes.a), at: start)
        #expect(outputs.count == 1)
        #expect(machine.isSessionActive)
        #expect(machine.touchedNoteIDs == [SessionNotes.a])
    }

    @Test("touched notes accumulate in first-touch order, without duplicates")
    func touchedNotes() {
        var machine = machine()
        _ = machine.handle(.edit(SessionNotes.b), at: start)
        _ = machine.handle(.edit(SessionNotes.a), at: start + 1)
        _ = machine.handle(.edit(SessionNotes.b), at: start + 2)
        #expect(machine.touchedNoteIDs == [SessionNotes.b, SessionNotes.a])
    }

    @Test("the idle timer ends the session, and the end time is the deadline")
    func idleEnd() {
        var machine = machine(idle: 180)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        #expect(machine.handle(.tick, at: start + 179).isEmpty)

        let outputs = machine.handle(.tick, at: start + 181)
        guard case let .ended(session) = outputs.first else {
            Issue.record("expected an ended session, got \(outputs)")
            return
        }
        #expect(session.reason == .idle)
        #expect(session.noteIDs == [SessionNotes.a])
        #expect(session.endedAt == start + 180)
        #expect(!machine.isSessionActive)
    }

    @Test("scrolling and selecting reset the idle timer (FR-3.1)", arguments: [
        EditorActivityKind.scroll, .selection, .keystroke,
    ])
    func activityResetsIdle(kind: EditorActivityKind) {
        var machine = machine(idle: 180)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.activity(SessionNotes.a, kind), at: start + 170)
        #expect(machine.nextDeadline == start + 350)
        #expect(machine.handle(.tick, at: start + 200).isEmpty, "the session must not end 30 s after activity")
        #expect(machine.handle(.tick, at: start + 351).count == 1)
    }

    @Test("switching notes keeps the session alive but does not touch the note")
    func noteSwitchIsActivityNotAnEdit() {
        var machine = machine(idle: 180)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.noteSwitched(SessionNotes.b), at: start + 100)
        #expect(machine.touchedNoteIDs == [SessionNotes.a])
        #expect(machine.nextDeadline == start + 280)
    }

    @Test("⌘-Tab ends the session but the pipeline waits out the grace (amendment 2)")
    func resignActiveGrace() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        let scheduled = machine.handle(.appDidResignActive, at: start + 10)
        guard case let .endScheduled(_, reason, fireAt) = scheduled.first else {
            Issue.record("expected a scheduled end, got \(scheduled)")
            return
        }
        #expect(reason == .appResignedActive)
        #expect(fireAt == start + 40)
        #expect(machine.isEndPending)
        #expect(!machine.isSessionActive)

        #expect(machine.handle(.tick, at: start + 39).isEmpty)
        guard case let .ended(session) = machine.handle(.tick, at: start + 41).first else {
            Issue.record("expected the session to fire after the grace")
            return
        }
        #expect(session.reason == .appResignedActive)
        #expect(session.endedAt == start + 10, "the session ended when the user left, not when the timer fired")
    }

    @Test("typing inside the grace supersedes the end silently")
    func typingCancelsGrace() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.appDidResignActive, at: start + 10)

        let outputs = machine.handle(.edit(SessionNotes.b), at: start + 20)
        guard case .endCancelled = outputs.first else {
            Issue.record("expected the end to be cancelled, got \(outputs)")
            return
        }
        #expect(machine.isSessionActive)
        #expect(machine.touchedNoteIDs == [SessionNotes.a, SessionNotes.b])
        #expect(machine.handle(.tick, at: start + 41).isEmpty, "the grace deadline must be gone")
        #expect(machine.handle(.tick, at: start + 201).count == 1, "the idle timer restarts from the edit")
    }

    @Test("scrolling inside the grace also cancels it")
    func activityCancelsGrace() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.windowClosed, at: start + 5)
        guard case .endCancelled = machine.handle(.activity(SessionNotes.a, .scroll), at: start + 10).first else {
            Issue.record("expected the end to be cancelled")
            return
        }
        #expect(machine.isSessionActive)
    }

    @Test("coming back to the app does not, by itself, cancel the grace")
    func becomeActiveDoesNotCancelGrace() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.appDidResignActive, at: start + 10)
        #expect(machine.handle(.appDidBecomeActive, at: start + 15).isEmpty)
        #expect(machine.isEndPending)
        #expect(machine.handle(.tick, at: start + 41).count == 1)
    }

    @Test("a second ⌘-Tab does not push the deadline further out")
    func graceIsNotExtended() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.appDidResignActive, at: start + 10)
        #expect(machine.handle(.windowClosed, at: start + 20).isEmpty)
        #expect(machine.nextDeadline == start + 40)
    }

    @Test("quitting ends the session immediately, with no grace")
    func terminateHasNoGrace() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        guard case let .ended(session) = machine.handle(.appWillTerminate, at: start + 5).first else {
            Issue.record("expected an immediate end")
            return
        }
        #expect(session.reason == .appWillTerminate)
    }

    @Test("quitting during the grace fires the pending session at once")
    func terminateDuringGrace() {
        var machine = machine(grace: 30)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        _ = machine.handle(.appDidResignActive, at: start + 10)
        guard case let .ended(session) = machine.handle(.appWillTerminate, at: start + 15).first else {
            Issue.record("expected the pending session to fire")
            return
        }
        #expect(session.reason == .appResignedActive)
        #expect(session.endedAt == start + 10)
    }

    @Test("a session nobody typed in is discarded, not organized")
    func emptySessionDiscarded() {
        var machine = machine()
        _ = machine.handle(.activity(SessionNotes.a, .scroll), at: start)
        #expect(machine.handle(.appDidResignActive, at: start + 1).isEmpty)
        #expect(machine.handle(.tick, at: start + 1_000).isEmpty)
    }

    @Test("inputs are inert with no session running")
    func inertWhenIdle() {
        var machine = machine()
        for input: SessionMachine.Input in [
            .activity(SessionNotes.a, .scroll), .noteSwitched(nil), .appDidResignActive,
            .appDidBecomeActive, .windowClosed, .appWillTerminate, .tick,
        ] {
            #expect(machine.handle(input, at: start).isEmpty, "\(input) should be inert")
        }
        #expect(machine.nextDeadline == nil)
    }

    @Test("the idle interval is clamped to FR-3.1's 1–15 minutes")
    func idleIntervalClamped() {
        #expect(SessionConfiguration(idleInterval: 5).idleInterval == 60)
        #expect(SessionConfiguration(idleInterval: 3_600).idleInterval == 900)
        #expect(SessionConfiguration().idleInterval == 180)
        #expect(SessionConfiguration().gracePeriod == 30)
    }

    @Test("a zero grace ends the session immediately on ⌘-Tab")
    func zeroGrace() {
        var machine = machine(grace: 0)
        _ = machine.handle(.edit(SessionNotes.a), at: start)
        guard case .ended = machine.handle(.appDidResignActive, at: start + 1).first else {
            Issue.record("expected an immediate end with no grace configured")
            return
        }
    }

    @Test("an EditorActivity value routes to the same rules")
    func editorActivityConvenience() {
        var machine = machine()
        _ = machine.handle(EditorActivity(noteID: SessionNotes.a, kind: .keystroke, at: start))
        #expect(machine.touchedNoteIDs == [SessionNotes.a])
        _ = machine.handle(EditorActivity(noteID: SessionNotes.b, kind: .scroll, at: start + 1))
        #expect(machine.touchedNoteIDs == [SessionNotes.a], "scrolling does not touch a note")
    }
}

// MARK: - The actor

@Suite("SessionTracker (M2-03)")
struct SessionTrackerTests {
    private func tracker(
        idle: TimeInterval = 180,
        grace: TimeInterval = 30,
        clock: ManualSessionClock,
        recorder: EventRecorder<SessionEvent>
    ) -> SessionTracker {
        SessionTracker(
            configuration: SessionConfiguration(idleInterval: idle, gracePeriod: grace),
            clock: clock,
            observer: recorder.observer
        )
    }

    @Test("idle end publishes a session with the notes that were typed in")
    func idleEndPublishes() async {
        let clock = ManualSessionClock()
        let recorder = EventRecorder<SessionEvent>()
        let tracker = tracker(clock: clock, recorder: recorder)

        await tracker.noteEdited(SessionNotes.a)
        await tracker.editorActivity(SessionNotes.a, kind: .scroll)
        await tracker.noteEdited(SessionNotes.b)
        clock.advance(by: 200)
        await tracker.tick()

        #expect(recorder.kinds == ["started", "ended"])
        #expect(recorder.endedSessions.first?.noteIDs == [SessionNotes.a, SessionNotes.b])
        #expect(recorder.endedSessions.first?.reason == .idle)
        await tracker.stop()
    }

    @Test("the flush hook runs before the ended event (ordering contract)")
    func flushBeforeEnd() async {
        let clock = ManualSessionClock()
        let order = EventRecorder<String>()
        let tracker = SessionTracker(
            configuration: SessionConfiguration(idleInterval: 60, gracePeriod: 0),
            clock: clock,
            observer: { event in
                if case .ended = event { order.record("ended") }
            }
        )
        await tracker.setFlushHook { order.record("flush") }

        await tracker.noteEdited(SessionNotes.a)
        clock.advance(by: 100)
        await tracker.tick()

        #expect(order.events == ["flush", "ended"])
        await tracker.stop()
    }

    @Test("the armed timer fires the session with no explicit tick")
    func timerFires() async {
        let clock = ManualSessionClock()
        let recorder = EventRecorder<SessionEvent>()
        let tracker = tracker(idle: 60, clock: clock, recorder: recorder)

        await tracker.noteEdited(SessionNotes.a)
        #expect(await tracker.nextDeadline == clock.now().addingTimeInterval(60))

        // Wake the timer's sleep rather than calling tick(): this is the path
        // the app takes.
        clock.advance(by: 61)
        var spins = 0
        while recorder.endedSessions.isEmpty, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        #expect(recorder.endedSessions.count == 1)
        await tracker.stop()
    }

    @Test("⌘-Tab schedules, typing in the grace cancels, and nothing is filed")
    func graceCancelled() async {
        let clock = ManualSessionClock()
        let recorder = EventRecorder<SessionEvent>()
        let tracker = tracker(clock: clock, recorder: recorder)

        await tracker.noteEdited(SessionNotes.a)
        await tracker.appDidResignActive()
        #expect(await tracker.isEndPending)

        clock.advance(by: 20)
        await tracker.appDidBecomeActive()
        await tracker.noteEdited(SessionNotes.a)
        #expect(recorder.kinds == ["started", "endScheduled", "endCancelled"])

        clock.advance(by: 20)
        await tracker.tick()
        #expect(recorder.endedSessions.isEmpty, "the grace deadline must not survive the cancel")
        #expect(await tracker.isSessionActive)
        await tracker.stop()
    }

    @Test("⌘-Tab with no return files the session once the grace expires")
    func graceExpires() async {
        let clock = ManualSessionClock()
        let recorder = EventRecorder<SessionEvent>()
        let tracker = tracker(clock: clock, recorder: recorder)

        await tracker.noteEdited(SessionNotes.a)
        await tracker.appDidResignActive()
        clock.advance(by: 31)
        await tracker.tick()

        #expect(recorder.kinds == ["started", "endScheduled", "ended"])
        #expect(recorder.endedSessions.first?.reason == .appResignedActive)
        await tracker.stop()
    }

    @Test("the AsyncStream sees the same events as the observer")
    func streamDelivers() async {
        let clock = ManualSessionClock()
        let tracker = SessionTracker(
            configuration: SessionConfiguration(idleInterval: 60, gracePeriod: 0), clock: clock
        )
        var iterator = tracker.events.makeAsyncIterator()

        await tracker.noteEdited(SessionNotes.c)
        clock.advance(by: 61)
        await tracker.tick()

        guard case .started = await iterator.next() else {
            Issue.record("expected .started first")
            return
        }
        guard case let .ended(session) = await iterator.next() else {
            Issue.record("expected .ended second")
            return
        }
        #expect(session.noteIDs == [SessionNotes.c])
        await tracker.stop()
    }

    @Test("shortening the idle interval in Settings applies to the running session")
    func configurationChangeAppliesLive() async {
        let clock = ManualSessionClock()
        let recorder = EventRecorder<SessionEvent>()
        let tracker = tracker(idle: 900, clock: clock, recorder: recorder)

        await tracker.noteEdited(SessionNotes.a)
        clock.advance(by: 120)
        await tracker.setConfiguration(SessionConfiguration(idleInterval: 60))
        await tracker.tick()

        #expect(recorder.endedSessions.count == 1)
        await tracker.stop()
    }

    @Test("stop() leaves no timer armed")
    func stopDisarms() async {
        let clock = ManualSessionClock()
        let recorder = EventRecorder<SessionEvent>()
        let tracker = tracker(clock: clock, recorder: recorder)
        await tracker.noteEdited(SessionNotes.a)
        await tracker.stop()
        // Give the cancelled timer a turn to unwind.
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(clock.waiterCount == 0)
    }
}
