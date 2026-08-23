import Foundation
import Testing

@testable import FilawayCore

@Suite("Session deltas")
struct TextDeltaTests {
    @Test("a note the AI has never seen is entirely new material")
    func newNote() {
        #expect(TextDelta.added(from: "", to: "hello\nworld") == "hello\nworld")
    }

    @Test("appending reports only what was appended")
    func append() {
        let old = "one\ntwo\n"
        let new = "one\ntwo\nthree\nfour\n"
        #expect(TextDelta.added(from: old, to: new) == "three\nfour")
    }

    @Test("an insert in the middle reports the inserted lines")
    func insert() {
        #expect(TextDelta.added(from: "a\nb\nc", to: "a\nNEW\nb\nc") == "NEW")
    }

    @Test("a pure deletion has nothing to file")
    func deletion() {
        #expect(TextDelta.added(from: "a\nb\nc", to: "a\nc") == "")
        #expect(TextDelta.added(from: "a", to: "a") == "")
    }

    @Test("whitespace-only changes are not an effective change")
    func whitespaceOnly() {
        let delta = SessionDelta(
            noteID: SessionNotes.a,
            title: "Scratch",
            relativePath: "Scratch.md",
            baselineText: "hello\n",
            currentText: "hello\n\n   \n"
        )
        #expect(!delta.hasEffectiveChange)
    }

    @Test("real new text is an effective change, and an untitled note is flagged")
    func effectiveChange() {
        let delta = SessionDelta(
            noteID: SessionNotes.a,
            title: PathRules.untitled,
            relativePath: "Untitled note.md",
            baselineText: "",
            currentText: "curl https://example.test\n"
        )
        #expect(delta.hasEffectiveChange)
        #expect(delta.isNewNote)
        #expect(delta.isUntitled)
    }
}

@Suite("Candidate finding (FR-4.6)")
struct CandidateFinderTests {
    private func context() -> OrganizeContext {
        let notes = [
            note(SessionNotes.a, "Scratch.md"),
            note(SessionNotes.b, "Commands/curl.md", tags: ["shell", "http"]),
            note(SessionNotes.c, "Meetings/Standup.md"),
        ]
        return OrganizeContext(notes: notes, folderPaths: ["Commands", "Meetings"])
    }

    private func note(_ id: NoteID, _ path: String, tags: [String] = []) -> NoteSummary {
        NoteSummary(
            id: id,
            relativePath: path,
            title: PathRules.title(of: path),
            folderPath: PathRules.folderPath(of: path),
            tags: tags,
            created: Date(timeIntervalSince1970: 1_750_000_000),
            modified: Date(timeIntervalSince1970: 1_755_000_000),
            size: 0,
            contentHash: "hash-\(path)"
        )
    }

    @Test("the note whose title matches the session text ranks first")
    func titleMatchWins() async throws {
        let finder = TitleOverlapCandidateFinder()
        let query = CandidateQuery(
            text: "curl command for the staging docs endpoint",
            titles: ["Scratch"],
            excluding: [SessionNotes.a],
            limit: 6
        )
        let ranked = try await finder.candidates(for: query, in: context())
        #expect(ranked.first?.noteID == SessionNotes.b)
        #expect(!ranked.contains { $0.noteID == SessionNotes.a }, "a session note is never its own merge target")
    }

    @Test("a session about something else finds no candidates")
    func noMatch() async throws {
        let finder = TitleOverlapCandidateFinder()
        let query = CandidateQuery(text: "photographs of the lighthouse", excluding: [], limit: 6)
        #expect(try await finder.candidates(for: query, in: context()).isEmpty)
    }

    @Test("tags and folder names count, less than titles")
    func tagsAndFolders() async throws {
        let finder = TitleOverlapCandidateFinder()
        let query = CandidateQuery(text: "shell snippets", excluding: [], limit: 6)
        let ranked = try await finder.candidates(for: query, in: context())
        #expect(ranked.first?.noteID == SessionNotes.b)
    }
}

@Suite("Organize context builder (M2-06)")
struct OrganizeContextBuilderTests {
    static let scratch = SessionNotes.a
    static let curl = SessionNotes.b
    static let secret = SessionNotes.c

    static let scratchBody = """
    curl to fetch docs from staging:

    ```sh
    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs
    ```
    """

    private func library() async -> FakeLibrary {
        let library = FakeLibrary()
        await library.add(id: Self.scratch, path: "Scratch.md", body: Self.scratchBody)
        await library.add(
            id: Self.curl,
            path: "Commands/curl.md",
            body: "# curl\n\nHandy invocations.\n" + String(repeating: "line\n", count: 60),
            tags: ["shell"]
        )
        await library.add(id: Self.secret, path: "Private/Pay review.md", body: "the figure is 88888\n")
        return library
    }

    private func build(
        excluded: [String] = ["Private"],
        budget: Int = 6_000,
        library: FakeLibrary
    ) async throws -> OrganizeRequestContext {
        let snapshot = try await library.snapshot()
        let delta = SessionDelta(
            noteID: Self.scratch,
            title: "Scratch",
            relativePath: "Scratch.md",
            baselineText: "",
            currentText: Self.scratchBody
        )
        let builder = OrganizeContextBuilder(excludedFolders: excluded, tokenBudget: budget)
        return try await builder.build(
            sessionID: SessionID(UUID(uuidString: "5E551000-0000-4000-8000-00000000000A")!),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .idle,
            deltas: [delta],
            snapshot: snapshot,
            mode: .ask,
            source: library,
            candidateFinder: TitleOverlapCandidateFinder()
        )
    }

    @Test("the prompt carries the session, the library and the candidates")
    func promptContents() async throws {
        let library = await library()
        let built = try await build(library: library)

        #expect(built.promptText.contains("Prompt: organize.v1"), "the request must say which prompt made it")
        #expect(built.promptText.contains(Self.scratch.uuidString))
        #expect(built.promptText.contains("curl -H \"Auth: Bearer $TOK\""))
        #expect(built.promptText.contains("Commands"))
        #expect(built.promptText.contains("Commands/curl.md"))
        #expect(built.candidateIDs == [Self.curl])
        #expect(built.promptText.contains("Handy invocations."), "the candidate's first lines are shown")
        #expect(built.truncations.isEmpty)
        #expect(built.estimatedPromptTokens <= 6_000)
        #expect(built.snapshotTexts[Self.scratch] == Self.scratchBody)
    }

    @Test("an excluded folder is not named, let alone quoted (FR-4.5)")
    func exclusionsAreInvisible() async throws {
        let library = await library()
        let built = try await build(library: library)

        #expect(!built.promptText.contains("Private"))
        #expect(!built.promptText.contains("Pay review"))
        #expect(!built.promptText.contains("88888"))
        #expect(!built.promptText.contains(Self.secret.uuidString))
        #expect(built.context.note(id: Self.secret) == nil)
        #expect(built.context.excludedFolders == ["Private"], "the validator still needs to know it exists")
    }

    @Test("the candidate preview is capped at the configured number of lines")
    func previewCap() async throws {
        let library = await library()
        let built = try await build(library: library)
        #expect(built.promptText.contains("First 20 lines:"))
        #expect(built.promptText.contains("more lines not shown"))
    }

    @Test("over budget, candidates are given up before session text")
    func budgetLadder() async throws {
        let library = await library()
        let built = try await build(budget: 220, library: library)

        #expect(!built.truncations.isEmpty)
        #expect(built.truncations.first == "candidate previews trimmed to 10 lines")
        #expect(built.truncations.contains("dropped all candidates"))
        #expect(built.candidateIDs.isEmpty)
        #expect(
            built.promptText.contains("curl -H \"Auth: Bearer $TOK\""),
            "the session's new material is the one thing that is never dropped"
        )
    }

    @Test("a note that only lost text is never sent")
    func noDeltaMeansNoRequest() async throws {
        let delta = SessionDelta(
            noteID: Self.scratch,
            title: "Scratch",
            relativePath: "Scratch.md",
            baselineText: Self.scratchBody,
            currentText: Self.scratchBody
        )
        #expect(!delta.hasEffectiveChange)
    }
}

@Suite("Organize request (M2-06)")
struct OrganizeRequestBuilderTests {
    @Test("organize.v1 exists, splices in plan-format.v1, and says the important things")
    func systemPrompt() throws {
        let system = try OrganizeRequestBuilder.systemPrompt()
        #expect(!system.contains(OrganizeRequestBuilder.includeMarker), "the include must be expanded")
        #expect(system.contains("organization_plan"))
        #expect(system.contains("moveSegment"))
        #expect(system.contains("byte-for-byte"))
        #expect(system.contains("retitleNote"))
        #expect(system.contains("two levels"))
        #expect(system.contains("Code block merged into Commands / curl."), "the Figure 2a summary style")
        #expect(system.contains("five tags") || system.contains("at most five"))
    }

    @Test("the request is the one the fixture key was designed around")
    func requestShape() async throws {
        let library = FakeLibrary()
        await library.add(id: SessionNotes.a, path: "Scratch.md", body: "curl something\n")
        let snapshot = try await library.snapshot()
        let built = try await OrganizeContextBuilder().build(
            sessionID: SessionID(),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .idle,
            deltas: [SessionDelta(
                noteID: SessionNotes.a, title: "Scratch", relativePath: "Scratch.md",
                baselineText: "", currentText: "curl something\n"
            )],
            snapshot: snapshot,
            mode: .ask,
            source: library,
            candidateFinder: TitleOverlapCandidateFinder()
        )
        let request = try OrganizeRequestBuilder.request(for: built, settings: OrganizerSettings())

        #expect(request.model == .defaultOrganize)
        #expect(request.model.id == "claude-sonnet-5")
        #expect(request.purpose == .organize)
        #expect(request.tools.count == 1)
        #expect(request.tools[0].name == OrganizationPlan.toolName)
        #expect(request.tools[0].strict)
        #expect(request.toolChoice == .tool(name: OrganizationPlan.toolName))
        #expect(request.thinking == .adaptive())
        #expect(request.effort == .low)
        #expect(request.timeout == 60)
        #expect(request.maxTokens == 4_096)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].role == .user)

        // The wire body is what the fixtures store and what FR-4.5 is asserted
        // against, so it must be complete.
        let body = ClaudeWire.body(for: request)
        #expect(body["model"]?.stringValue == "claude-sonnet-5")
        #expect(body["tool_choice"]?["name"]?.stringValue == OrganizationPlan.toolName)
        #expect(body["output_config"]?["effort"]?.stringValue == "low")
        #expect(body.allStrings.contains { $0.contains("Prompt: organize.v1") })
    }

    @Test("the advanced model override reaches the request")
    func modelOverride() async throws {
        let library = FakeLibrary()
        await library.add(id: SessionNotes.a, path: "Scratch.md", body: "text\n")
        let built = try await OrganizeContextBuilder().build(
            sessionID: SessionID(),
            endedAt: Date(timeIntervalSince1970: 1_756_000_200),
            reason: .idle,
            deltas: [SessionDelta(
                noteID: SessionNotes.a, title: "Scratch", relativePath: "Scratch.md",
                baselineText: "", currentText: "text\n"
            )],
            snapshot: try await library.snapshot(),
            mode: .auto,
            source: library,
            candidateFinder: TitleOverlapCandidateFinder()
        )
        var settings = OrganizerSettings()
        settings.model = .advancedOrganize
        let request = try OrganizeRequestBuilder.request(for: built, settings: settings)
        #expect(request.model.id == "claude-opus-5")
    }
}
