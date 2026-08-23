import Foundation
import Testing

@testable import FilawayCore

/// One example of every action, used by both the codec and the schema tests.
enum SampleActions {
    static let createNote = PlanAction.createNote(CreateNoteAction(
        title: "curl", folderPath: "Commands", content: "# curl\n", tags: ["shell", "http"]
    ))
    static let appendToNote = PlanAction.appendToNote(AppendToNoteAction(
        target: .id(SampleLibrary.curlID), content: "more\n", heading: "From 22 Aug", divider: true
    ))
    static let createFolder = PlanAction.createFolder(CreateFolderAction(path: "Commands/Docker"))
    static let moveNote = PlanAction.moveNote(MoveNoteAction(
        note: .id(SampleLibrary.scratchID), toFolderPath: "Commands"
    ))
    static let retitleNote = PlanAction.retitleNote(RetitleNoteAction(
        note: .id(SampleLibrary.untitledID), newTitle: "Auth notes"
    ))
    static let tagNote = PlanAction.tagNote(TagNoteAction(note: .path("Commands/curl.md"), tags: ["http"]))
    static let moveSegmentToExisting = PlanAction.moveSegment(MoveSegmentAction(
        source: .id(SampleLibrary.scratchID),
        segment: SampleLibrary.segment,
        segmentHash: Hashing.sha256Hex(SampleLibrary.segment),
        sourceRange: PlanTextRange(start: 30, length: SampleLibrary.segment.count),
        destination: .existingNote(.id(SampleLibrary.curlID)),
        heading: "Fetch documents",
        divider: true
    ))
    static let moveSegmentToNew = PlanAction.moveSegment(MoveSegmentAction(
        source: .id(SampleLibrary.scratchID),
        segment: SampleLibrary.segment,
        destination: .newNote(title: "documents", folderPath: "Commands", tags: ["shell"])
    ))

    static let all: [PlanAction] = [
        createNote, appendToNote, createFolder, moveNote, retitleNote, tagNote,
        moveSegmentToExisting, moveSegmentToNew,
    ]
}

@Suite("Organization plan codec")
struct OrganizationPlanCodecTests {
    @Test("every action round-trips through JSON")
    func actionRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for action in SampleActions.all {
            let data = try encoder.encode(action)
            #expect(try decoder.decode(PlanAction.self, from: data) == action)
            let json = try JSONValue.parse(data)
            #expect(json["action"] == .string(action.kind.rawValue), "the discriminator must survive")
        }
    }

    @Test("the whole plan round-trips, preconditions included")
    func planRoundTrip() throws {
        let plan = OrganizationPlan(
            summary: "Merge the curl snippet into Commands/curl",
            actions: SampleActions.all,
            preconditions: PlanPreconditions([
                SampleLibrary.scratchID: SampleLibrary.precondition(for: SampleLibrary.scratchID),
                SampleLibrary.curlID: SampleLibrary.precondition(for: SampleLibrary.curlID),
            ]),
            promptVersion: .organize,
            model: AIModel.defaultOrganize.id
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(OrganizationPlan.self, from: data)
        #expect(decoded == plan)

        // Preconditions must be a plain `{uuid: hash}` object, not the
        // alternating array Swift produces for non-string dictionary keys.
        let json = try JSONValue.parse(data)
        let raw = try #require(json["preconditions"]?.objectValue)
        #expect(raw.count == 2)
        #expect(raw[SampleLibrary.curlID.uuidString] == .string(SampleLibrary.precondition(for: SampleLibrary.curlID)))
    }

    @Test("prompt versions parse and print")
    func promptVersion() throws {
        #expect(PromptVersion("organize.v1") == .organize)
        #expect(PromptVersion.organize.description == "organize.v1")
        #expect(PromptVersion.organize.fileName == "organize.v1.txt")
        #expect(PromptVersion("organize") == nil)
        #expect(PromptVersion("organize.1") == nil)
        let data = try JSONEncoder().encode(PromptVersion.planFormat)
        #expect(String(decoding: data, as: UTF8.self) == "\"plan-format.v1\"")
        #expect(try JSONDecoder().decode(PromptVersion.self, from: data) == .planFormat)
    }

    @Test("the bundled prompt resource loads")
    func promptResource() throws {
        let text = try PromptLibrary.text(.planFormat)
        #expect(text.contains("organization_plan"))
        #expect(text.contains("byte-for-byte"))
        // M2-06 and M3-05 still owe theirs; the loader must say so clearly.
        #expect(throws: PromptError.self) {
            _ = try PromptLibrary.text(PromptVersion(id: "not-written-yet", version: 9), environment: [:])
        }
    }

    @Test("an explicit directory overrides the bundle")
    func promptDirectoryOverride() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "override".write(
            to: directory.appendingPathComponent("plan-format.v1.txt"), atomically: true, encoding: .utf8
        )
        #expect(try PromptLibrary.text(.planFormat, in: directory) == "override")
    }

    @Test("no action in the closed set can delete user text (FR-4.4)")
    func nothingDestructive() {
        // Exhaustive over `PlanAction.Kind`: adding a case makes this fail to
        // compile until someone decides on purpose.
        for kind in PlanAction.Kind.allCases {
            let action: PlanAction
            switch kind {
            case .createNote: action = SampleActions.createNote
            case .appendToNote: action = SampleActions.appendToNote
            case .createFolder: action = SampleActions.createFolder
            case .moveNote: action = SampleActions.moveNote
            case .retitleNote: action = SampleActions.retitleNote
            case .tagNote: action = SampleActions.tagNote
            case .moveSegment: action = SampleActions.moveSegmentToExisting
            }
            #expect(action.kind == kind)
            #expect(action.neverDeletesUserText)
        }
        #expect(OrganizationPlan(summary: "", actions: SampleActions.all).neverDeletesUserText)
    }

    @Test("a segment move carries the text so nothing can be lost")
    func segmentCarriesText() throws {
        guard case let .moveSegment(move) = SampleActions.moveSegmentToExisting else {
            Issue.record("expected a moveSegment")
            return
        }
        #expect(move.segment == SampleLibrary.segment)
        #expect(move.expectedSegmentHash == Hashing.sha256Hex(SampleLibrary.segment))
        #expect(SampleLibrary.scratchBody.contains(move.segment))
    }
}

@Suite("Plan tool schema")
struct PlanSchemaTests {
    @Test("the schema is a valid, strict-tool-shaped JSON Schema")
    func lint() {
        let problems = JSONSchemaChecker.lint(OrganizationPlan.toolSchema)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("the schema round-trips through JSON unchanged")
    func roundTrip() throws {
        let data = try OrganizationPlan.toolSchema.canonicalData()
        #expect(try JSONValue.parse(data) == OrganizationPlan.toolSchema)
        #expect(OrganizationPlan.toolSchema["type"] == .string("object"))
        #expect(OrganizationPlan.toolSchema["required"] == .array(["summary", "actions"]))
        #expect(OrganizationPlan.toolSchema["additionalProperties"] == .bool(false))
    }

    @Test("the tool definition is strict and forced by name")
    func toolDefinition() {
        let tool = OrganizationPlan.tool
        #expect(tool.name == OrganizationPlan.toolName)
        #expect(tool.strict)
        #expect(tool.inputSchema == OrganizationPlan.toolSchema)
        #expect(ClaudeWire.toolValue(tool)["strict"] == .bool(true))
    }

    @Test("the schema names exactly the closed action set")
    func closedSet() throws {
        let branches = try #require(
            OrganizationPlan.toolSchema["properties"]?["actions"]?["items"]?["anyOf"]?.arrayValue
        )
        let names = branches.compactMap { $0["properties"]?["action"]?["enum"]?[0]?.stringValue }.sorted()
        #expect(names == PlanAction.Kind.allCases.map(\.rawValue).sorted())
        #expect(branches.count == PlanAction.Kind.allCases.count)
    }

    @Test("every encoded action validates against the schema")
    func actionsValidate() throws {
        let input = try PlanDecoder.toolInput(for: OrganizationPlan(
            summary: "Everything at once", actions: SampleActions.all
        ))
        let problems = JSONSchemaChecker.validate(input, against: OrganizationPlan.toolSchema)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("the empty plan validates")
    func emptyValidates() throws {
        let input = try PlanDecoder.toolInput(for: OrganizationPlan(summary: "Nothing to file", actions: []))
        #expect(JSONSchemaChecker.validate(input, against: OrganizationPlan.toolSchema).isEmpty)
    }

    @Test("the schema rejects what the codec would reject")
    func schemaRejects() throws {
        let cases: [JSONValue] = [
            .object(["actions": .array([])]),                                        // no summary
            .object(["summary": "x"]),                                               // no actions
            .object(["summary": 3, "actions": .array([])]),                          // wrong type
            .object(["summary": "x", "actions": .array([]), "extra": true]),         // additional property
            .object(["summary": "x", "actions": .array([.object(["action": "deleteNote"])])]),
            .object(["summary": "x", "actions": .array([.object(["action": "createNote", "title": "t"])])]),
        ]
        for value in cases {
            #expect(
                !JSONSchemaChecker.validate(value, against: OrganizationPlan.toolSchema).isEmpty,
                "\(value) should not validate"
            )
        }
    }
}

@Suite("Plan decoding from tool input")
struct PlanDecoderTests {
    private func input(_ actions: [JSONValue], summary: String = "Do the thing") -> JSONValue {
        .object(["summary": .string(summary), "actions": .array(actions)])
    }

    @Test("a well-formed tool call becomes a plan")
    func happyPath() throws {
        let value = try PlanDecoder.toolInput(for: OrganizationPlan(summary: "s", actions: SampleActions.all))
        let result = try PlanDecoder.decode(toolInput: value, model: "claude-sonnet-5")
        #expect(result.plan.actions == SampleActions.all)
        #expect(result.plan.summary == "s")
        #expect(result.plan.model == "claude-sonnet-5")
        #expect(result.plan.promptVersion == .organize)
        #expect(result.unknownActions.isEmpty)
    }

    @Test("preconditions are attached from the library, not from the model")
    func preconditions() throws {
        let value = try PlanDecoder.toolInput(for: OrganizationPlan(
            summary: "s", actions: [SampleActions.appendToNote, SampleActions.moveSegmentToExisting]
        ))
        let result = try PlanDecoder.decode(toolInput: value, context: SampleLibrary.context)
        #expect(result.plan.preconditions.noteIDs == [SampleLibrary.curlID, SampleLibrary.scratchID])
        #expect(result.plan.preconditions[SampleLibrary.curlID] == SampleLibrary.precondition(for: SampleLibrary.curlID))
    }

    @Test("unknown and unreadable actions are reported, the rest survive")
    func toleratesUnknown() throws {
        let good = try PlanDecoder.toolInput(for: OrganizationPlan(summary: "s", actions: [SampleActions.createFolder]))
        let actions: [JSONValue] = [
            try #require(good["actions"]?[0]),
            .object(["action": "deleteEverything", "path": "Commands"]),
            .object(["action": "createNote"]),                       // missing fields
            .object(["title": "no discriminator"]),
            .string("not even an object"),
        ]
        let result = try PlanDecoder.decode(toolInput: input(actions))
        #expect(result.plan.actions == [SampleActions.createFolder])
        #expect(result.unknownActions.map(\.index) == [1, 2, 3, 4])
        #expect(result.unknownActions[0].name == "deleteEverything")
        #expect(result.unknownActions[0].reason.contains("closed action set"))
        #expect(result.unknownActions[1].name == "createNote")
        #expect(result.unknownActions[2].name == nil)
        #expect(result.unknownActions[3].reason.contains("expected an object"))
    }

    @Test("an empty plan decodes and is legal")
    func emptyPlan() throws {
        let result = try PlanDecoder.decode(toolInput: input([], summary: "Nothing needs filing"))
        #expect(result.plan.isEmpty)
        #expect(result.plan.summary == "Nothing needs filing")
    }

    @Test("structural nonsense throws instead of half-decoding")
    func structuralErrors() {
        #expect(throws: PlanDecodingError.notAnObject("array")) {
            try PlanDecoder.decode(toolInput: .array([]))
        }
        #expect(throws: PlanDecodingError.missingField("summary")) {
            try PlanDecoder.decode(toolInput: .object(["actions": .array([])]))
        }
        #expect(throws: PlanDecodingError.missingField("actions")) {
            try PlanDecoder.decode(toolInput: .object(["summary": "x"]))
        }
        #expect(throws: PlanDecodingError.wrongType(field: "actions", expected: "array", actual: "object")) {
            try PlanDecoder.decode(toolInput: .object(["summary": "x", "actions": .object([:])]))
        }
    }

    @Test("reading a response handles refusal, truncation and a missing tool call")
    func responseCases() throws {
        let planInput = try PlanDecoder.toolInput(for: OrganizationPlan(summary: "s", actions: []))

        let good = AIResponse.toolUse(name: OrganizationPlan.toolName, input: planInput)
        #expect(try PlanDecoder.decode(response: good).plan.summary == "s")

        let refusal = AIResponse(
            id: "m", model: "claude-sonnet-5", content: [], stopReason: .refusal,
            stopDetails: AIStopDetails(type: "refusal", category: "cyber")
        )
        #expect(throws: PlanDecodingError.refused(category: "cyber")) {
            try PlanDecoder.decode(response: refusal)
        }

        let truncated = AIResponse(
            id: "m", model: "claude-sonnet-5",
            content: [.toolUse(id: "t", name: OrganizationPlan.toolName, input: planInput)],
            stopReason: .maxTokens
        )
        #expect(throws: PlanDecodingError.truncated) { try PlanDecoder.decode(response: truncated) }

        let chatty = AIResponse.text("I would rather explain than call the tool.")
        #expect(throws: PlanDecodingError.noToolUse(expected: OrganizationPlan.toolName, stopReason: "end_turn")) {
            try PlanDecoder.decode(response: chatty)
        }
    }

    @Test("tool input is parsed, never string-matched")
    func escapingIsIrrelevant() throws {
        // Escaped solidi and unicode escapes are both legal JSON for the same
        // string; the decoder must not care which the model emitted.
        let raw = """
        {"summary":"Move it","actions":[{"action":"createFolder","path":"Commands\\/Docker"}]}
        """
        let result = try PlanDecoder.decode(toolInput: try JSONValue.parse(raw))
        #expect(result.plan.actions == [SampleActions.createFolder])
    }
}
