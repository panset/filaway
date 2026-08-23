import Foundation
import Testing

@testable import FilawayCore

/// NFR-3: killing the app mid-apply must never corrupt or lose a note.
///
/// The `ApplyFailureHook` stands in for the kill: `.crash` throws *without*
/// unwinding, which is what a power cut looks like from the journal's point of
/// view — the row stays `inProgress` and nobody rolled anything back.
@Suite("Apply journal recovery")
struct ApplyRecoveryTests {
    private func crash(after step: @escaping @Sendable (ApplyStep) -> Bool) -> ApplyFailureHook {
        .crash(at: step)
    }

    @Test("a crash between operations rolls back to the before-images")
    func crashMidPlanRollsBack() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { step in
            if case .appendToNote = step { return true }
            return false
        }))
        try await harness.seed("Auth.md", "auth notes\n")
        try await harness.store.createFolder("Commands")
        let auth = try await harness.id(of: "Auth.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .createNote(CreateNoteAction(title: "curl", folderPath: "Commands", content: "curl -sS")),
            .appendToNote(AppendToNoteAction(target: .id(auth), content: "TOKEN=abc")),
        ])

        await expectThrows(try await harness.applier.apply(plan)) { error in
            if case .simulatedCrash = error as? ApplyError ?? .noteMissing("") { return true }
            return false
        }
        // Mid-crash: the created note is on disk and the journal row is open.
        #expect(harness.temp.allMarkdownPaths().contains("Commands/curl.md"))
        let incomplete = try await harness.activity.incompleteEvents()
        #expect(incomplete.count == 1)

        // "Relaunch."
        _ = harness.restart()
        let outcomes = try await harness.recover()
        #expect(outcomes.count == 1)
        #expect(outcomes[0].resolution == .rolledBack)
        #expect(harness.fingerprint() == before)
        #expect(try await harness.activity.incompleteEvents().isEmpty)
        let event = try #require(await harness.activity.event(outcomes[0].eventID))
        #expect(event.status == .rolledBack)
        #expect(!event.isUndoable)
        // The created note went to the Trash, not to nowhere.
        let url = try #require(outcomes[0].trashURLs.first)
        #expect(FileManager.default.fileExists(atPath: url))
    }

    @Test("a crash after the last write but before the after-images rolls back")
    func crashBeforeImagesRollsBack() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { $0 == .beforeAfterImages }))
        try await harness.seed("Scratch.md", "keep\n\ncurl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"])

        await expectThrows(try await harness.applier.apply(plan)) { $0 is ApplyError }
        // Both files were already rewritten before the crash.
        #expect(harness.fingerprint() != before)

        _ = harness.restart()
        let outcomes = try await harness.recover()
        #expect(outcomes[0].resolution == .rolledBack)
        #expect(harness.fingerprint() == before)
        #expect(try await harness.body("Scratch.md").contains("curl -sS"))
        #expect(!(try await harness.body("Commands/curl.md")).contains("curl -sS https"))
    }

    @Test("a crash after the after-images are durable rolls forward")
    func crashBeforeCommitRollsForward() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { $0 == .beforeCommit }))
        try await harness.seed("Auth.md", "auth notes\n")
        let auth = try await harness.id(of: "Auth.md")

        let plan = try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(auth), content: "TOKEN=abc")),
        ])
        await expectThrows(try await harness.applier.apply(plan)) { $0 is ApplyError }
        let applied = harness.fingerprint()

        _ = harness.restart()
        let outcomes = try await harness.recover()
        #expect(outcomes.count == 1)
        #expect(outcomes[0].resolution == .rolledForward)
        // Rolling forward changes no files — the work was already done.
        #expect(harness.fingerprint() == applied)
        let event = try #require(await harness.activity.event(outcomes[0].eventID))
        #expect(event.status == .applied)
        #expect(event.isUndoable)

        // And the recovered event is a normal, undoable Activity entry.
        let result = try await harness.undoLatest()
        #expect(result.outcome == .complete)
        #expect(try await harness.body("Auth.md") == "auth notes\n")
    }

    @Test("an error mid-apply rolls back immediately, without waiting for a relaunch")
    func failureRollsBackInline() async throws {
        let harness = try ApplyHarness(failureHook: .fail(at: { step in
            if case .retitleNote = step { return true }
            return false
        }))
        try await harness.seed("Scratch.md", "one\n")
        try await harness.seed("Auth.md", "auth\n")
        let scratch = try await harness.id(of: "Scratch.md")
        let auth = try await harness.id(of: "Auth.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(scratch), content: "two")),
            .retitleNote(RetitleNoteAction(note: .id(auth), newTitle: "Auth API debug")),
        ])

        await expectThrows(try await harness.applier.apply(plan)) { error in
            guard case .injectedFailure = error as? ApplyError ?? .noteMissing("") else { return false }
            return true
        }

        #expect(harness.fingerprint() == before)
        #expect(try await harness.activity.incompleteEvents().isEmpty)
        let events = try await harness.activity.events()
        #expect(events.count == 1)
        #expect(events[0].status == .rolledBack)
        #expect(!events[0].isUndoable)
        #expect(try await harness.undo.undoableEvents().isEmpty)
    }

    @Test("a crash while trashing an emptied source leaves the note recoverable")
    func crashAroundTrashRollsBack() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { step in
            if case .trashEmptySource = step { return true }
            return false
        }))
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"])
        await expectThrows(try await harness.applier.apply(plan)) { $0 is ApplyError }

        // The source is still on disk, untouched: the trash step never ran.
        #expect(harness.temp.allMarkdownPaths().contains("Scratch.md"))

        _ = harness.restart()
        try await harness.recover()
        #expect(harness.fingerprint() == before)
    }

    @Test("recovery is idempotent and leaves nothing incomplete")
    func recoveryIsIdempotent() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { step in
            if case .appendToNote = step { return true }
            return false
        }))
        try await harness.seed("Auth.md", "auth\n")
        let auth = try await harness.id(of: "Auth.md")
        let before = harness.fingerprint()
        let plan = try await harness.plan([
            .createNote(CreateNoteAction(title: "New", folderPath: "", content: "x")),
            .appendToNote(AppendToNoteAction(target: .id(auth), content: "y")),
        ])
        await expectThrows(try await harness.applier.apply(plan)) { $0 is ApplyError }

        _ = harness.restart()
        #expect(try await harness.recover().count == 1)
        #expect(try await harness.recover().isEmpty)
        #expect(harness.fingerprint() == before)
        #expect(harness.temp.strayEntries().isEmpty)
    }
}
