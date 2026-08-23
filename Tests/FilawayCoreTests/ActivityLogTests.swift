import Foundation
import Testing

@testable import FilawayCore

/// M2-08: the Activity log itself — what it lists, what it diffs, what it keeps
/// and for how long (FR-4.3, FR-4.4).
@Suite("Activity log")
struct ActivityLogTests {
    @Test("the log lists events newest first and pages with a cursor")
    func pagingIsNewestFirst() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "start\n")
        for index in 1 ... 5 {
            let id = try await harness.id(of: "Notes.md")
            try await harness.apply(try await harness.plan([
                .appendToNote(AppendToNoteAction(target: .id(id), content: "line \(index)")),
            ], summary: "append \(index)"))
        }

        let firstPage = try await harness.activity.events(limit: 2)
        #expect(firstPage.count == 2)
        #expect(firstPage[0].timestamp > firstPage[1].timestamp)
        #expect(firstPage.allSatisfy { $0.kind == .applied && $0.status == .applied })
        #expect(firstPage[0].affectedNoteCount == 1)
        // A list query leaves the note text on disk.
        #expect(firstPage[0].images.isEmpty)

        let secondPage = try await harness.activity.events(limit: 2, before: firstPage[1].cursor)
        #expect(secondPage.count == 2)
        #expect(secondPage[0].timestamp < firstPage[1].timestamp)
        let all = try await harness.activity.events(limit: 50)
        #expect(all.count == 5)
        #expect(Set(all.map(\.id)).count == 5)
    }

    @Test("an event carries its plan, prompt version, model and summary")
    func eventProvenance() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        var plan = try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "more")),
        ], summary: "Append the snippet.")
        plan.model = "claude-opus-5"
        let applied = try await harness.apply(plan, sessionText: "the raw session")

        let event = try #require(await harness.activity.event(applied.eventID))
        #expect(event.model == "claude-opus-5")
        #expect(event.promptVersion?.description == "organize.v1")
        #expect(event.plan?.actions.count == 1)
        #expect(event.summary == applied.summary)
        #expect(event.hasSessionText)
        #expect(try await harness.activity.sessionText(for: applied.eventID) == "the raw session")
    }

    @Test("diff(for:) is a per-note before/after over the body, front matter aside")
    func diffPerNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "keep\n\ncurl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")

        let applied = try await harness.apply(try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"]))

        let diffs = try await harness.activity.diff(for: applied.eventID)
        #expect(diffs.count == 2)
        let sourceDiff = try #require(diffs.first { $0.noteID == source })
        #expect(sourceDiff.diff.deletedLineCount > 0)
        #expect(sourceDiff.unified.contains("-curl -sS https://example.com"))
        let targetDiff = try #require(diffs.first { $0.noteID == target })
        #expect(targetDiff.diff.insertedLineCount > 0)
        #expect(targetDiff.unified.contains("+curl -sS https://example.com"))
        // Front-matter churn is not shown as a change the user made.
        #expect(!sourceDiff.unified.contains("id:"))
    }

    @Test("a created note diffs as pure insertion; a trashed one as pure deletion")
    func diffForCreateAndTrash() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n")
        try await harness.store.createFolder("Commands")
        let source = try await harness.id(of: "Scratch.md")

        let applied = try await harness.apply(try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .newNote(title: "curl", folderPath: "Commands", tags: [])
            )),
        ], bodiesFor: ["Scratch.md"]))

        let diffs = try await harness.activity.diff(for: applied.eventID)
        let created = try #require(diffs.first { $0.created })
        #expect(created.diff.deletedLineCount == 0)
        #expect(created.beforePath == nil)
        let trashed = try #require(diffs.first { $0.trashed })
        #expect(trashed.afterPath == nil)
        #expect(trashed.diff.insertedLineCount == 0)
    }

    @Test("a move shows up as a relocation, not as a rewrite")
    func diffShowsRelocation() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("curl.md", "curl -sS\n")
        try await harness.store.createFolder("Commands")
        let id = try await harness.id(of: "curl.md")
        let applied = try await harness.apply(try await harness.plan([
            .moveNote(MoveNoteAction(note: .id(id), toFolderPath: "Commands")),
        ]))
        let diff = try #require(await harness.activity.diff(for: applied.eventID).first)
        #expect(diff.wasRelocated)
        #expect(diff.beforePath == "curl.md")
        #expect(diff.afterPath == "Commands/curl.md")
        #expect(diff.diff.isEmpty)
    }

    @Test("a dismissed proposal is logged but touches nothing")
    func dismissedProposal() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "start\n")
        let before = harness.fingerprint()
        let plan = try await harness.plan([
            .createNote(CreateNoteAction(title: "Rejected", folderPath: "", content: "x")),
        ], summary: "File this?")

        let id = try await harness.activity.recordDismissed(plan: plan, sessionText: "raw", at: harness.clock.now())
        let event = try #require(await harness.activity.event(id))
        #expect(event.kind == .proposedDismissed)
        #expect(event.status == .none)
        #expect(!event.isUndoable)
        #expect(harness.fingerprint() == before)
        #expect(try await harness.undo.undoableEvents().isEmpty)
    }

    // MARK: - Retention (FR-4.4)

    @Test("raw session text survives 29 days and is pruned at 31")
    func sessionTextRetention() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock)
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))]),
            sessionText: "the raw session text"
        )

        clock.advance(29 * 24 * 60 * 60)
        var report = try await harness.activity.prune(now: clock.date)
        #expect(report.sessionTextsPruned == 0)
        #expect(try await harness.activity.sessionText(for: applied.eventID) == "the raw session text")

        clock.advance(2 * 24 * 60 * 60)
        report = try await harness.activity.prune(now: clock.date)
        #expect(report.sessionTextsPruned == 1)
        #expect(try await harness.activity.sessionText(for: applied.eventID) == nil)
        // The event itself stays: the Activity log is a history.
        #expect(try await harness.activity.eventCount() == 1)
    }

    @Test("before/after images are kept while an event is undoable")
    func imagesKeptWhileUndoable() async throws {
        let clock = ApplyClock()
        let harness = try ApplyHarness(clock: clock)
        try await harness.seed("Notes.md", "start\n")
        let id = try await harness.id(of: "Notes.md")
        let applied = try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))])
        )

        clock.advance(60 * 24 * 60 * 60)
        _ = try await harness.activity.prune(now: clock.date)
        #expect(try await harness.activity.images(for: applied.eventID).count == 1)
        #expect(try await harness.undo.undoableEvents().count == 1)

        // Once it has been undone it is no longer undoable, so its images may go.
        try await harness.undo(applied.eventID)
        let report = try await harness.activity.prune(now: clock.date)
        #expect(report.eventsStrippedOfImages == 1)
        #expect(try await harness.activity.images(for: applied.eventID).isEmpty)
    }

    // MARK: - Baselines (FR-3.2)

    @Test("baselines round-trip through the database and update in place")
    func baselines() async throws {
        let harness = try ApplyHarness()
        let id = NoteID()
        #expect(try await harness.activity.baseline(for: id) == nil)

        let store: any BaselineStore = DatabaseBaselineStore(log: harness.activity)
        try await store.setBaseline(noteID: id, hash: Hashing.sha256Hex("one"), text: "one")
        var baseline = try #require(await store.baseline(for: id))
        #expect(baseline.text == "one")
        #expect(baseline.contentHash == Hashing.sha256Hex("one"))

        try await store.setBaseline(noteID: id, hash: Hashing.sha256Hex("two"), text: "two")
        baseline = try #require(await store.baseline(for: id))
        #expect(baseline.text == "two")
        #expect(try await harness.activity.baselineCount() == 1)

        try await harness.activity.removeBaseline(for: id)
        #expect(try await harness.activity.baseline(for: id) == nil)
    }

    @Test("the log shares filaway.sqlite with the metadata store")
    func sharesTheDatabaseFile() async throws {
        let harness = try ApplyHarness(onDisk: true)
        let metadata = try MetadataStore(library: harness.library)
        #expect(try await metadata.schemaVersion() == DatabaseSchema.version)

        try await harness.seed("Notes.md", "start\n")
        try await metadata.rebuild(from: try await harness.snapshot())
        let id = try await harness.id(of: "Notes.md")
        try await harness.apply(
            try await harness.plan([.appendToNote(AppendToNoteAction(target: .id(id), content: "more"))])
        )
        try await harness.activity.setBaseline(noteID: id, hash: "h", text: "t", at: Date())

        #expect(try await metadata.noteCount() == 1)
        #expect(try await harness.activity.eventCount() == 1)
        #expect(try await harness.activity.baseline(for: id)?.text == "t")
        #expect(FileManager.default.fileExists(atPath: harness.library.databaseURL.path))
    }
}
