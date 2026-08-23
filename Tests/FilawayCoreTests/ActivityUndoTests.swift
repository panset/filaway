import Foundation
import Testing

@testable import FilawayCore

/// M2-08: Undo. FR-4.3 asks for a single Undo over at least the last ten
/// organization events; FR-4.4 says nothing may be dropped on the way back.
@Suite("Undo")
struct ActivityUndoTests {
    @Test("undo of an untouched note restores a byte-identical tree")
    func undoRestoresBytes() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Auth.md", "auth notes\n")
        let before = harness.fingerprint()
        let id = try await harness.id(of: "Auth.md")

        let applied = try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "TOKEN=abc")),
        ]))
        #expect(harness.fingerprint() != before)

        let result = try await harness.undoLatest()
        #expect(result.eventID == applied.eventID)
        #expect(result.outcome == .complete)
        #expect(result.notes.first?.action == .restored)
        #expect(harness.fingerprint() == before)

        // The undo is itself an Activity event, and the original is spent.
        let undone = try #require(await harness.activity.event(applied.eventID))
        #expect(undone.status == .undone)
        #expect(!undone.isUndoable)
        #expect(undone.undoneBy == result.undoEventID)
        let undoEvent = try #require(await harness.activity.event(result.undoEventID))
        #expect(undoEvent.kind == .undone)
        #expect(!undoEvent.isUndoable)
    }

    @Test("ten stacked events unwind to a byte-identical tree at every step")
    func tenDeepUndo() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "start\n")
        var fingerprints: [[String: String]] = []
        var eventIDs: [ActivityEventID] = []

        for index in 1 ... 10 {
            fingerprints.append(harness.fingerprint())
            let id = try await harness.id(of: "Notes.md")
            let applied = try await harness.apply(try await harness.plan([
                .appendToNote(AppendToNoteAction(target: .id(id), content: "step \(index)", heading: "Step \(index)")),
            ], summary: "step \(index)"))
            eventIDs.append(applied.eventID)
        }
        #expect(try await harness.undo.undoableEvents().count == 10)

        for index in stride(from: 9, through: 0, by: -1) {
            let result = try await harness.undoLatest()
            #expect(result.eventID == eventIDs[index], "undo must be LIFO")
            #expect(result.outcome == .complete)
            #expect(harness.fingerprint() == fingerprints[index], "step \(index) must restore byte-identically")
        }
        #expect(try await harness.undo.undoableEvents().isEmpty)
        await expectThrows(try await harness.undo.undoLatest()) { $0 as? UndoError == .nothingToUndo }
    }

    @Test("undo of a created note moves it to the Trash, never deletes it")
    func undoOfCreateTrashes() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "notes\n")
        try await harness.store.createFolder("Commands")
        let before = harness.fingerprint()

        try await harness.apply(try await harness.plan([
            .createNote(CreateNoteAction(title: "curl", folderPath: "Commands", content: "curl -sS")),
        ]))
        let result = try await harness.undoLatest()

        #expect(result.notes.first?.action == .trashed)
        let trashURL = try #require(result.notes.first?.trashURL)
        #expect(FileManager.default.fileExists(atPath: trashURL))
        #expect(try String(contentsOf: URL(fileURLWithPath: trashURL), encoding: .utf8).contains("curl -sS"))
        #expect(harness.fingerprint() == before)
    }

    @Test("undo of a moveSegment that trashed its source writes the source back")
    func undoRecreatesTrashedSource() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let before = harness.fingerprint()
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")

        try await harness.apply(try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"]))
        #expect(harness.temp.allMarkdownPaths() == ["Commands/curl.md"])

        let result = try await harness.undoLatest()
        #expect(result.outcome == .complete)
        #expect(result.notes.contains { $0.action == .recreated })
        #expect(harness.fingerprint() == before)
    }

    @Test("undo of a move and a retitle puts the file back where it was")
    func undoOfRelocation() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("curl.md", "curl -sS\n")
        try await harness.store.createFolder("Commands")
        let before = harness.fingerprint()
        let id = try await harness.id(of: "curl.md")

        try await harness.apply(try await harness.plan([
            .moveNote(MoveNoteAction(note: .id(id), toFolderPath: "Commands")),
            .retitleNote(RetitleNoteAction(note: .id(id), newTitle: "curl commands")),
        ]))
        #expect(harness.temp.allMarkdownPaths() == ["Commands/curl commands.md"])

        let result = try await harness.undoLatest()
        #expect(result.notes.first?.previousPath == "Commands/curl commands.md")
        #expect(harness.temp.allMarkdownPaths() == ["curl.md"])
        #expect(harness.fingerprint() == before)
    }

    // MARK: - Undo after the user has edited (FR-4.4)

    @Test("an edit elsewhere in the note survives the reverse patch")
    func reversePatchKeepsTheUsersEdit() async throws {
        let harness = try ApplyHarness()
        let original = (1 ... 12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try await harness.seed("Notes.md", original)
        let id = try await harness.id(of: "Notes.md")

        try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "TOKEN=abc", heading: "Token")),
        ]))

        // The user comes back and edits the top of the note.
        var edited = try await harness.body("Notes.md")
        edited = edited.replacingOccurrences(of: "line 1\n", with: "line one, rewritten\n")
        try await harness.store.save(body: edited, to: "Notes.md")

        let result = try await harness.undoLatest()
        #expect(result.outcome == .complete)
        #expect(result.notes.first?.action == .patched)
        let body = try await harness.body("Notes.md")
        #expect(body.contains("line one, rewritten"))   // the user's edit is intact
        #expect(!body.contains("TOKEN=abc"))            // the AI's append is gone
        #expect(!body.contains(ApplyText.undoConflictHeading))
    }

    @Test("an edit the patch cannot unpick becomes a marked conflict block, never a loss")
    func conflictAppendsRecoveredText() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "keep this\n\nsecret line\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")

        try await harness.apply(try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "secret line",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"]))

        // The user rewrites the source note completely.
        try await harness.store.save(body: "an entirely different note now\n", to: "Scratch.md")

        let result = try await harness.undoLatest()
        #expect(result.outcome == .partial)
        let scratch = try #require(result.notes.first { $0.noteID == source })
        #expect(scratch.action == .conflicted)

        let body = try await harness.body("Scratch.md")
        #expect(body.contains("an entirely different note now"))          // nothing overwritten
        #expect(body.contains("## \(ApplyText.undoConflictHeading)"))     // clearly marked
        #expect(body.contains("secret line"))                            // nothing dropped
        // The other note still came all the way back.
        #expect(try await harness.body("Commands/curl.md") == "# curl\n")
    }

    // MARK: - Ordering

    @Test("a later event touching the same note blocks an out-of-order undo")
    func lifoBlocking() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let first = try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "one")),
        ], summary: "one"))
        let second = try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "two")),
        ], summary: "two"))

        await expectThrows(try await harness.undo.undo(first.eventID)) {
            $0 as? UndoError == .blockedByLaterEvent(second.eventID)
        }
        // In order, both come back.
        try await harness.undo(second.eventID)
        try await harness.undo(first.eventID)
        #expect(try await harness.body("Notes.md") == "start\n")
    }

    @Test("events that touch different notes may be undone in any order")
    func independentEventsAreNotBlocked() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("A.md", "a\n")
        try await harness.seed("B.md", "b\n")
        let before = harness.fingerprint()
        let a = try await harness.id(of: "A.md")
        let b = try await harness.id(of: "B.md")

        let first = try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(a), content: "one")),
        ], summary: "A"))
        try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(b), content: "two")),
        ], summary: "B"))

        let result = try await harness.undo(first.eventID)
        #expect(result.outcome == .complete)
        #expect(try await harness.body("A.md") == "a\n")
        try await harness.undoLatest()
        #expect(harness.fingerprint() == before)
    }

    @Test("an event can only be undone once")
    func undoIsNotRepeatable() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "one")),
        ]))
        try await harness.undo(applied.eventID)
        await expectThrows(try await harness.undo.undo(applied.eventID)) {
            $0 as? UndoError == .notUndoable(applied.eventID)
        }
        await expectThrows(try await harness.undo.undo(ActivityEventID())) {
            guard case .unknownEvent = $0 as? UndoError ?? .nothingToUndo else { return false }
            return true
        }
    }

    @Test("undoing an apply leaves no stray files and no third folder level")
    func undoKeepsTheInvariants() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "keep\n\ncurl -sS https://example.com\n")
        let before = harness.fingerprint()
        let id = try await harness.id(of: "Scratch.md")

        try await harness.apply(try await harness.plan([
            .createFolder(CreateFolderAction(path: "Commands/HTTP")),
            .moveSegment(MoveSegmentAction(
                source: .id(id),
                segment: "curl -sS https://example.com",
                destination: .newNote(title: "curl", folderPath: "Commands/HTTP", tags: [])
            )),
        ], bodiesFor: ["Scratch.md"]))

        try await harness.undoLatest()
        #expect(harness.fingerprint() == before)
        #expect(harness.temp.strayEntries().isEmpty)
        for folder in harness.folders() {
            #expect(PathRules.depth(ofFolder: folder) <= PathRules.maxFolderDepth)
        }
    }
}
