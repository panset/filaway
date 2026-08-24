import Foundation
import Testing

@testable import FilawayCore

@Suite("Autosave scheduler (FR-2.3, NFR-3)")
struct AutosaveSchedulerTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func note(_ n: Int) -> (id: NoteID, path: String) {
        (NoteID(UUID(uuidString: "0000000\(n)-0000-0000-0000-00000000000\(n)")!), "Note \(n).md")
    }

    // MARK: - Debounce

    @Test("Nothing is due before the 750 ms window elapses")
    func debounceHoldsBack() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        let deadline = await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "he", at: t0)

        #expect(deadline == t0.addingTimeInterval(0.75))
        #expect(await scheduler.jobsDue(at: t0).isEmpty)
        #expect(await scheduler.jobsDue(at: t0.addingTimeInterval(0.74)).isEmpty)
        #expect(await scheduler.jobsDue(at: t0.addingTimeInterval(0.75)).count == 1)
    }

    @Test("A keystroke burst coalesces into one write of the latest text")
    func burstCoalesces() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        for (offset, text) in ["h", "he", "hel", "hell", "hello"].enumerated() {
            await scheduler.bufferChanged(
                noteID: a.id, relativePath: a.path, text: text,
                at: t0.addingTimeInterval(Double(offset) * 0.1)
            )
        }
        // Window restarts from the *last* keystroke, at t0+0.4.
        #expect(await scheduler.jobsDue(at: t0.addingTimeInterval(1.0)).isEmpty)

        let due = await scheduler.jobsDue(at: t0.addingTimeInterval(1.15))
        #expect(due.count == 1)
        #expect(due.first?.text == "hello")
        #expect(due.first?.trigger == .debounce)
        #expect(await scheduler.nextDeadline() == t0.addingTimeInterval(1.15))
    }

    @Test("Finishing a job clears the buffer; a fresh edit re-arms it")
    func finishClears() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "x", at: t0)
        let job = try #require(await scheduler.jobsDue(at: t0.addingTimeInterval(1)).first)

        #expect(await scheduler.finish(job))
        #expect(await scheduler.isDirty(a.id) == false)
        #expect(await scheduler.nextDeadline() == nil)
        #expect(await scheduler.jobsDue(at: t0.addingTimeInterval(10)).isEmpty)

        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "xy", at: t0.addingTimeInterval(2))
        #expect(await scheduler.isDirty(a.id))
    }

    // MARK: - Flush points

    @Test("Switching notes flushes the outgoing buffer before its deadline")
    func flushOnNoteSwitch() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "half typed", at: t0)

        // 100 ms later the user clicks another note: no debounce job is due yet.
        let now = t0.addingTimeInterval(0.1)
        #expect(await scheduler.jobsDue(at: now).isEmpty)

        let job = try #require(await scheduler.flush(noteID: a.id, trigger: .noteSwitch))
        #expect(job.text == "half typed")
        #expect(job.trigger == .noteSwitch)
        await scheduler.finish(job)
        #expect(await scheduler.isDirty(a.id) == false)
    }

    @Test("flushAll covers every flush point and reports the trigger")
    func flushAllTriggers() async throws {
        for trigger in [AutosaveTrigger.windowResignKey, .appResignActive, .manual, .terminate] {
            let scheduler = AutosaveScheduler(debounce: 0.75)
            let a = note(1)
            await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "t", at: t0)
            let jobs = await scheduler.flushAll(trigger: trigger)
            #expect(jobs.count == 1)
            #expect(jobs.first?.trigger == trigger)
        }
    }

    @Test("Terminate flushes every dirty note, in the order they went dirty")
    func terminateOrdering() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let notes = (1 ... 3).map(note)
        for (offset, n) in notes.enumerated() {
            await scheduler.bufferChanged(
                noteID: n.id, relativePath: n.path, text: "body \(offset)",
                at: t0.addingTimeInterval(Double(offset) * 0.05)
            )
        }
        // Re-typing in the first note must not push it to the back of the queue.
        await scheduler.bufferChanged(
            noteID: notes[0].id, relativePath: notes[0].path, text: "body 0 more",
            at: t0.addingTimeInterval(0.2)
        )

        let jobs = await scheduler.flushAll(trigger: .terminate)
        #expect(jobs.map(\.noteID) == notes.map(\.id))
        #expect(jobs.map(\.text) == ["body 0 more", "body 1", "body 2"])
        #expect(jobs.allSatisfy { $0.trigger == .terminate })
        #expect(await scheduler.dirtyCount == 3)  // still dirty until each finishes
    }

    @Test("A keystroke during a write leaves the note dirty — no burst is lost")
    func typingDuringWriteIsNotLost() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "first", at: t0)
        let job = try #require(await scheduler.jobsDue(at: t0.addingTimeInterval(1)).first)

        // The write is in flight; the user keeps typing.
        await scheduler.bufferChanged(
            noteID: a.id, relativePath: a.path, text: "first second", at: t0.addingTimeInterval(1.01)
        )

        #expect(await scheduler.finish(job) == false)
        #expect(await scheduler.isDirty(a.id))
        let next = try #require(await scheduler.jobsDue(at: t0.addingTimeInterval(2)).first)
        #expect(next.text == "first second")
    }

    @Test("A failed write keeps the buffer dirty and does not spin")
    func failureKeepsBufferDirty() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "x", at: t0)
        let job = try #require(await scheduler.jobsDue(at: t0.addingTimeInterval(1)).first)

        await scheduler.fail(job, retryAt: t0.addingTimeInterval(1))
        #expect(await scheduler.isDirty(a.id))
        #expect(await scheduler.jobsDue(at: t0.addingTimeInterval(1.5)).isEmpty)
        #expect(await scheduler.jobsDue(at: t0.addingTimeInterval(1.8)).count == 1)
    }

    // MARK: - Conflicts (ADR-010)

    @Test("An external change to a dirty note routes the next write through conflict resolution")
    func conflictFlagSet() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "mine", at: t0)

        #expect(await scheduler.externalChangeSeen(noteID: a.id))
        let job = try #require(await scheduler.flush(noteID: a.id, trigger: .externalChange))
        #expect(job.needsConflictResolution)
        #expect(job.text == "mine")

        await scheduler.finish(job)
        #expect(await scheduler.isDirty(a.id) == false)
    }

    @Test("An external change to a clean note reports not-dirty, so the UI reloads instead")
    func conflictFlagNotSetWhenClean() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        #expect(await scheduler.externalChangeSeen(noteID: a.id) == false)
        #expect(await scheduler.flush(noteID: a.id, trigger: .externalChange) == nil)
    }

    @Test("The conflict flag is cleared once a write consumed it")
    func conflictFlagCleared() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "mine", at: t0)
        await scheduler.externalChangeSeen(noteID: a.id)
        let job = try #require(await scheduler.flush(noteID: a.id, trigger: .externalChange))

        // Typed during the resolution: still dirty, but the copy already exists.
        await scheduler.bufferChanged(
            noteID: a.id, relativePath: a.path, text: "mine more", at: t0.addingTimeInterval(0.1)
        )
        #expect(await scheduler.finish(job) == false)
        let next = try #require(await scheduler.flush(noteID: a.id, trigger: .terminate))
        #expect(next.needsConflictResolution == false)
    }

    // MARK: - Housekeeping

    @Test("A rename redirects the pending write to the new path")
    func relocation() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "x", at: t0)
        await scheduler.noteRelocated(noteID: a.id, to: "Commands/Renamed.md")
        let job = try #require(await scheduler.jobsDue(at: t0.addingTimeInterval(1)).first)
        #expect(job.relativePath == "Commands/Renamed.md")
    }

    @Test("Dropping a buffer discards it without a write")
    func dropDiscards() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "x", at: t0)
        await scheduler.drop(noteID: a.id)
        #expect(await scheduler.isDirty(a.id) == false)
        #expect(await scheduler.flushAll(trigger: .terminate).isEmpty)
    }

    @Test("Dirty note ids drive the sidebar's 'Now · editing' state")
    func dirtySet() async throws {
        let scheduler = AutosaveScheduler(debounce: 0.75)
        let a = note(1), b = note(2)
        await scheduler.bufferChanged(noteID: a.id, relativePath: a.path, text: "x", at: t0)
        await scheduler.bufferChanged(noteID: b.id, relativePath: b.path, text: "y", at: t0)
        #expect(await scheduler.dirtyNoteIDs() == [a.id, b.id])
    }
}
