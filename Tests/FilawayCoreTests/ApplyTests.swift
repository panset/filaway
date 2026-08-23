import Foundation
import Testing

@testable import FilawayCore

/// M2-07: the apply matrix — one test per action, plus the two ways an apply
/// must refuse (FR-4.2, FR-4.4, FR-3.2).
@Suite("Plan apply")
struct ApplyTests {
    // MARK: - The closed action set

    @Test("createNote writes the note, its tags and its Activity images")
    func createNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "notes\n")
        try await harness.store.createFolder("Commands")

        let plan = try await harness.plan([
            .createNote(CreateNoteAction(
                title: "curl",
                folderPath: "Commands",
                content: "curl -sS https://example.com\n",
                tags: ["http", "cli"]
            )),
        ], summary: "File the curl snippet.")

        let applied = try await harness.apply(plan, sessionText: "raw session text")

        #expect(applied.outcomes.count == 1)
        #expect(applied.outcomes[0].relativePath == "Commands/curl.md")
        #expect(applied.createdNotes.count == 1)
        let note = try await harness.note("Commands/curl.md")
        #expect(note.body.contains("curl -sS"))
        #expect(note.tags == ["http", "cli"])

        let event = try #require(await harness.activity.event(applied.eventID))
        #expect(event.kind == .applied)
        #expect(event.status == .applied)
        #expect(event.isUndoable)
        #expect(event.plan?.actions.count == 1)
        #expect(event.promptVersion == PromptVersion.organize)
        #expect(event.images.count == 1)
        #expect(event.images[0].before == nil)
        #expect(event.images[0].created)
        #expect(try await harness.activity.sessionText(for: applied.eventID) == "raw session text")
    }

    @Test("appendToNote appends under a divider and heading, never interleaved")
    func appendToNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Auth API debug.md", "# Auth\n\nfirst paragraph\n")
        let id = try await harness.id(of: "Auth API debug.md")

        let plan = try await harness.plan([
            .appendToNote(AppendToNoteAction(
                target: .id(id),
                content: "TOKEN=abc123",
                heading: "Session token"
            )),
        ])
        try await harness.apply(plan)

        let body = try await harness.body("Auth API debug.md")
        #expect(body.hasPrefix("# Auth\n\nfirst paragraph\n"))
        #expect(body.contains("\n---\n\n## Session token\n\nTOKEN=abc123"))
        // The original text is still there, in one piece.
        #expect(body.range(of: "first paragraph")?.lowerBound ?? body.startIndex
            < (body.range(of: "TOKEN=abc123")?.lowerBound ?? body.startIndex))
    }

    @Test("createFolder makes the folder and reports it")
    func createFolder() async throws {
        let harness = try ApplyHarness()
        let plan = try await harness.plan([
            .createFolder(CreateFolderAction(path: "Commands/Docker")),
        ])
        let applied = try await harness.apply(plan)

        #expect(harness.folders().contains("Commands/Docker"))
        #expect(applied.createdFolders.contains("Commands/Docker"))
        #expect(applied.createdFolders.contains("Commands"))
    }

    @Test("moveNote moves the file and keeps every byte")
    func moveNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("curl.md", "curl -sS\n")
        try await harness.store.createFolder("Commands")
        let before = try await harness.note("curl.md")

        let plan = try await harness.plan([
            .moveNote(MoveNoteAction(note: .id(before.id), toFolderPath: "Commands")),
        ])
        let applied = try await harness.apply(plan)

        #expect(applied.outcomes[0].relativePath == "Commands/curl.md")
        #expect(applied.outcomes[0].previousPath == "curl.md")
        #expect(!harness.temp.allMarkdownPaths().contains("curl.md"))
        let after = try await harness.note("Commands/curl.md")
        #expect(after.body == before.body)
        #expect(after.id == before.id)
    }

    @Test("retitleNote renames the file, which is the title (DS-1)")
    func retitleNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Untitled note.md", "docker ps -a\n")
        let id = try await harness.id(of: "Untitled note.md")

        let plan = try await harness.plan([
            .retitleNote(RetitleNoteAction(note: .id(id), newTitle: "Docker cheats")),
        ])
        let applied = try await harness.apply(plan)

        #expect(applied.outcomes[0].relativePath == "Docker cheats.md")
        #expect(harness.temp.allMarkdownPaths() == ["Docker cheats.md"])
        #expect(try await harness.body("Docker cheats.md") == "docker ps -a\n")
    }

    @Test("tagNote is additive — it never drops a tag the user has")
    func tagNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Notes.md", "text\n", tags: ["mine"])
        let id = try await harness.id(of: "Notes.md")

        let plan = try await harness.plan([
            .tagNote(TagNoteAction(note: .id(id), tags: ["ai", "mine"])),
        ])
        try await harness.apply(plan)

        let note = try await harness.note("Notes.md")
        #expect(note.tags == ["mine", "ai"])
        #expect(note.body == "text\n")
    }

    @Test("moveSegment into an existing note moves the text and leaves the rest")
    func moveSegmentIntoExistingNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "keep this\n\ncurl -sS https://example.com\n\nand this\n")
        try await harness.seed("Commands/curl.md", "# curl\n\nold example\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target)),
                heading: "From the session"
            )),
        ], bodiesFor: ["Scratch.md"])
        let applied = try await harness.apply(plan)

        let sourceBody = try await harness.body("Scratch.md")
        #expect(!sourceBody.contains("curl -sS"))
        #expect(sourceBody.contains("keep this"))
        #expect(sourceBody.contains("and this"))
        let targetBody = try await harness.body("Commands/curl.md")
        #expect(targetBody.contains("old example"))
        #expect(targetBody.contains("## From the session\n\ncurl -sS https://example.com"))
        #expect(applied.outcomes[0].relativePath == "Commands/curl.md")
        #expect(applied.trashedNotes.isEmpty)
    }

    @Test("moveSegment into a new note creates it and fills it")
    func moveSegmentIntoNewNote() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "keep this\n\ndocker compose up -d\n")
        try await harness.store.createFolder("Commands")
        let source = try await harness.id(of: "Scratch.md")

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "docker compose up -d",
                destination: .newNote(title: "Docker compose", folderPath: "Commands", tags: ["docker"])
            )),
        ], bodiesFor: ["Scratch.md"])
        let applied = try await harness.apply(plan)

        let created = try await harness.note("Commands/Docker compose.md")
        #expect(created.body.trimmingCharacters(in: .whitespacesAndNewlines) == "docker compose up -d")
        #expect(created.tags == ["docker"])
        #expect(applied.createdNotes.count == 1)
        #expect(try await harness.body("Scratch.md") == "keep this\n")
    }

    @Test("moveSegment that empties its source sends it to the Trash, never a delete")
    func moveSegmentEmptiesSource() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")
        let sourceBytes = try String(contentsOf: harness.temp.url("Scratch.md"), encoding: .utf8)

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"])
        let applied = try await harness.apply(plan)

        #expect(harness.temp.allMarkdownPaths() == ["Commands/curl.md"])
        #expect(applied.trashedNotes.count == 1)
        let trashed = try #require(applied.trashedNotes.first)
        #expect(trashed.relativePath == "Scratch.md")
        let trashURL = try #require(trashed.trashURL)
        // Nothing was hard-deleted: the file is in the Trash, bytes intact.
        #expect(FileManager.default.fileExists(atPath: trashURL))
        #expect(try String(contentsOf: URL(fileURLWithPath: trashURL), encoding: .utf8) == sourceBytes)

        let event = try #require(await harness.activity.event(applied.eventID))
        let image = try #require(event.images.first { $0.noteID == source })
        #expect(image.wasTrashed)
        #expect(image.before?.text == sourceBytes)
    }

    // MARK: - Refusals

    @Test("a compare-and-swap miss changes nothing at all")
    func compareAndSwapMissChangesNothing() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "one\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let id = try await harness.id(of: "Scratch.md")
        let plan = try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(id), content: "appended")),
            .createNote(CreateNoteAction(title: "New", folderPath: "Commands", content: "body")),
        ])

        // The user keeps typing (FR-3.2).
        try await harness.store.save(body: "one\ntwo\n", to: "Scratch.md")
        let before = harness.fingerprint()

        await expectThrows(try await harness.applier.apply(plan)) { error in
            guard case let ApplyError.preconditionFailed(ids) = error else { return false }
            return ids == [id]
        }

        #expect(harness.fingerprint() == before)
        #expect(!harness.temp.allMarkdownPaths().contains("Commands/New.md"))
        #expect(try await harness.activity.eventCount() == 0)
    }

    @Test("a segment that is no longer verbatim is a precondition miss, not a guess")
    func segmentGoneIsPreconditionFailure() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")

        var plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ])
        // Rewrite the source, then forge the precondition so only the segment
        // check can catch it.
        let rewritten = try await harness.store.save(body: "curl -sSL https://example.com\n", to: "Scratch.md")
        plan.preconditions[source] = rewritten.contentHash
        let before = harness.fingerprint()

        await expectThrows(try await harness.applier.apply(plan)) { error in
            guard case let ApplyError.preconditionFailed(ids) = error else { return false }
            return ids == [source]
        }
        #expect(harness.fingerprint() == before)
    }

    @Test("a plan that no longer validates is refused before anything is written")
    func invalidPlanChangesNothing() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "one\n")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .createNote(CreateNoteAction(title: "Deep", folderPath: "A/B/C", content: "x")),
        ])
        await expectThrows(try await harness.applier.apply(plan)) { error in
            guard case let ApplyError.invalidPlan(issues) = error else { return false }
            return issues.contains { $0.kind == .folderTooDeep }
        }
        #expect(harness.fingerprint() == before)
        #expect(harness.folders().isEmpty)
    }

    // MARK: - Invariants

    @Test("a multi-action plan runs in a fixed order and reports every action")
    func multiActionPlan() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "intro\n\ncurl -sS https://example.com\n")
        try await harness.seed("Auth.md", "auth notes\n")
        let scratch = try await harness.id(of: "Scratch.md")
        let auth = try await harness.id(of: "Auth.md")

        let plan = try await harness.plan([
            .createFolder(CreateFolderAction(path: "Commands")),
            .moveSegment(MoveSegmentAction(
                source: .id(scratch),
                segment: "curl -sS https://example.com",
                destination: .newNote(title: "curl", folderPath: "Commands", tags: [])
            )),
            .appendToNote(AppendToNoteAction(target: .id(auth), content: "TOKEN=abc")),
            .retitleNote(RetitleNoteAction(note: .id(auth), newTitle: "Auth API debug")),
            .tagNote(TagNoteAction(note: .id(auth), tags: ["auth"])),
        ], bodiesFor: ["Scratch.md"])

        let applied = try await harness.apply(plan)

        #expect(applied.outcomes.count == 5)
        #expect(applied.isComplete)
        #expect(harness.temp.allMarkdownPaths() == ["Auth API debug.md", "Commands/curl.md", "Scratch.md"])
        let auth2 = try await harness.note("Auth API debug.md")
        #expect(auth2.body.contains("TOKEN=abc"))
        #expect(auth2.tags == ["auth"])
        #expect(try await harness.body("Commands/curl.md").contains("curl -sS"))
        #expect(!applied.summary.isEmpty)
        #expect(harness.temp.strayEntries().isEmpty)
    }

    @Test("the library never grows a third folder level")
    func depthInvariantHolds() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("A/B/deep.md", "x\n")
        let id = try await harness.id(of: "A/B/deep.md")

        let plan = try await harness.plan([
            .createNote(CreateNoteAction(title: "ok", folderPath: "A/B", content: "y")),
            .tagNote(TagNoteAction(note: .id(id), tags: ["t"])),
        ])
        try await harness.apply(plan)

        for folder in harness.folders() {
            #expect(PathRules.depth(ofFolder: folder) <= PathRules.maxFolderDepth)
        }
        #expect(harness.temp.allMarkdownPaths().contains("A/B/ok.md"))
    }

    @Test("nothing but .md files ever lands in the user's tree")
    func noStrayFiles() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n\nrest\n")
        let id = try await harness.id(of: "Scratch.md")
        let plan = try await harness.plan([
            .createFolder(CreateFolderAction(path: "Commands")),
            .moveSegment(MoveSegmentAction(
                source: .id(id),
                segment: "curl -sS https://example.com",
                destination: .newNote(title: "curl", folderPath: "Commands", tags: [])
            )),
        ], bodiesFor: ["Scratch.md"])
        try await harness.apply(plan)
        #expect(harness.temp.strayEntries().isEmpty)
    }

    @Test("an empty plan is applied as nothing")
    func emptyPlan() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Scratch.md", "one\n")
        let before = harness.fingerprint()
        let applied = try await harness.apply(try await harness.plan([], summary: "Nothing to file."))
        #expect(applied.outcomes.isEmpty)
        #expect(harness.fingerprint() == before)
        #expect(applied.summary == "Nothing was changed.")
    }
}

/// The pure text rules an apply is built from.
@Suite("Apply text rules")
struct ApplyTextTests {
    @Test("appending to a non-empty body uses a divider and one blank line")
    func appendUsesDivider() {
        let out = ApplyText.appending("new text", to: "old\n", heading: nil, divider: nil)
        #expect(out == "old\n\n---\n\nnew text\n")
    }

    @Test("appending to an empty body writes no divider")
    func appendToEmptyBody() {
        #expect(ApplyText.appending("new", to: "   \n\n", heading: nil, divider: nil) == "new\n")
        #expect(ApplyText.appending("new", to: "", heading: "Heading", divider: true) == "## Heading\n\nnew\n")
    }

    @Test("a heading that already carries hashes is not double-marked")
    func headingHashes() {
        #expect(ApplyText.appending("x", to: "", heading: "### Deep") == "### Deep\n\nx\n")
    }

    @Test("removing a segment tidies the seam without touching the rest")
    func removeSegment() {
        #expect(ApplyText.removingSegment("b", from: "a\n\nb\n\nc\n") == "a\n\nc\n")
        #expect(ApplyText.removingSegment("a", from: "a\n\nb\n") == "b\n")
        #expect(ApplyText.removingSegment("b", from: "a\n\nb\n") == "a\n")
        #expect(ApplyText.removingSegment("only", from: "only\n") == "")
        #expect(ApplyText.removingSegment("missing", from: "a\n") == nil)
        #expect(ApplyText.removingSegment("", from: "a\n") == nil)
    }

    @Test("whitespace-only bodies count as empty")
    func emptiness() {
        #expect(ApplyText.isEffectivelyEmpty("  \n\t\n"))
        #expect(!ApplyText.isEffectivelyEmpty("  x\n"))
    }

    @Test("tag merging is additive and case-insensitively unique")
    func tagMerge() {
        #expect(ApplyText.mergedTags(["Mine"], adding: ["mine", "new", " "]) == ["Mine", "new"])
        #expect(ApplyText.mergedTags([], adding: ["a", "a"]) == ["a"])
    }
}
