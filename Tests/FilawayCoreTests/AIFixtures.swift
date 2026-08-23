import Foundation

@testable import FilawayCore

/// The hand-authored replay fixtures.
///
/// M2-02 builds the harness *before* the first prompt exists (plan §4), so these
/// stand in until M2-06 records real ones: a valid plan, a plan the validator
/// must reject, a refusal, and "nothing to do", plus the key-validation
/// response. Rate limiting is not a fixture — it is a transport behaviour, and
/// lives in the stub-server suite instead.
///
/// The request text is deliberately small and fixed: a fixture's filename is a
/// hash of the request, so a fixture whose prompt drifts stops being found,
/// which is the behaviour we want for real prompts and a nuisance for these.
///
/// Regenerate with:
/// ```
/// FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "AI recording fixtures"
/// ```
enum AIFixtures {
    /// A stand-in system prompt. `organize.v1` (M2-06) will replace it.
    static let system = """
    You file notes. Call the organization_plan tool exactly once. Never delete or \
    rewrite existing text. Folders are at most two levels deep. Copy any moved \
    segment byte-for-byte.
    """

    /// The rendered library context. Note what is *not* here: `Private/Salary.md`
    /// is excluded (FR-4.5), so neither its title nor its text can appear.
    static var libraryContext: String {
        let filter = ExclusionFilter(excludedFolders: ["Private"])
        let notes = filter.allowed(SampleLibrary.notes)
        let folders = filter.allowed(folderPaths: SampleLibrary.folderPaths)
        var lines = ["Folders: \(folders.joined(separator: ", "))", "Notes:"]
        for note in notes {
            lines.append("- id=\(note.id.uuidString) path=\(note.relativePath)")
        }
        lines.append("")
        lines.append("Session notes:")
        for note in notes where note.id == SampleLibrary.scratchID || note.id == SampleLibrary.curlID {
            lines.append("--- \(note.relativePath) ---")
            lines.append(SampleLibrary.bodies[note.id] ?? "")
        }
        return lines.joined(separator: "\n")
    }

    static func organizeRequest(_ instruction: String) -> AIRequest {
        AIRequest(
            model: .defaultOrganize,
            purpose: .organize,
            system: system,
            messages: [.user("\(libraryContext)\n\n\(instruction)")],
            tools: [OrganizationPlan.tool],
            toolChoice: .tool(name: OrganizationPlan.toolName),
            maxTokens: 4096,
            thinking: .adaptive(),
            effort: .medium
        )
    }

    // MARK: - The scenarios

    static var validPlanRequest: AIRequest { organizeRequest("File this session.") }

    static var invalidPlanRequest: AIRequest { organizeRequest("File this session, and be careless about it.") }

    static var refusalRequest: AIRequest { organizeRequest("File this session. It is about something objectionable.") }

    static var nothingToDoRequest: AIRequest { organizeRequest("File this session, which is already tidy.") }

    private static func toolUseResponse(
        _ input: JSONValue,
        id: String,
        inputTokens: Int = 1_840,
        outputTokens: Int = 320
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "type": "message",
            "role": "assistant",
            "model": .string(AIModel.defaultOrganize.id),
            "content": .array([
                .object([
                    "type": "tool_use",
                    "id": .string("toolu_\(id)"),
                    "name": .string(OrganizationPlan.toolName),
                    "input": input,
                ]),
            ]),
            "stop_reason": "tool_use",
            "usage": .object([
                "input_tokens": .integer(inputTokens),
                "output_tokens": .integer(outputTokens),
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
            ]),
        ])
    }

    /// A plan the validator accepts: merge the snippet, name the untitled note.
    static var validPlanResponse: JSONValue {
        toolUseResponse(
            .object([
                "summary": "Move the curl snippet into Commands/curl and name the untitled note",
                "actions": .array([
                    .object([
                        "action": "moveSegment",
                        "source": .object(["id": .string(SampleLibrary.scratchID.uuidString)]),
                        "segment": .string(SampleLibrary.segment),
                        "segmentHash": .string(Hashing.sha256Hex(SampleLibrary.segment)),
                        "destination": .object([
                            "kind": "existingNote",
                            "note": .object(["id": .string(SampleLibrary.curlID.uuidString)]),
                        ]),
                        "heading": "Fetch documents",
                        "divider": .bool(true),
                    ]),
                    .object([
                        "action": "retitleNote",
                        "note": .object(["id": .string(SampleLibrary.untitledID.uuidString)]),
                        "newTitle": "Auth notes",
                    ]),
                ]),
            ]),
            id: "plan_ok"
        )
    }

    /// A plan the validator must reject: a folder three levels deep, a note id
    /// that does not exist, and a segment that was paraphrased rather than
    /// copied.
    static var invalidPlanResponse: JSONValue {
        toolUseResponse(
            .object([
                "summary": "File everything into a deep folder",
                "actions": .array([
                    .object(["action": "createFolder", "path": "Commands/Docker/Compose"]),
                    .object([
                        "action": "createNote",
                        "title": "notes/with/slashes",
                        "folderPath": "Commands/Docker/Compose",
                        "content": "…",
                        "tags": .array([]),
                    ]),
                    .object([
                        "action": "appendToNote",
                        "target": .object(["id": "00000000-0000-4000-8000-000000000000"]),
                        "content": "orphan",
                    ]),
                    .object([
                        "action": "moveSegment",
                        "source": .object(["id": .string(SampleLibrary.scratchID.uuidString)]),
                        "segment": "curl https://example.test/documents",
                        "destination": .object([
                            "kind": "existingNote",
                            "note": .object(["id": .string(SampleLibrary.curlID.uuidString)]),
                        ]),
                    ]),
                    .object(["action": "deleteNote", "note": .object(["id": .string(SampleLibrary.scratchID.uuidString)])]),
                ]),
            ]),
            id: "plan_bad"
        )
    }

    /// FR-4.6: leaving the taxonomy alone is a good answer.
    static var nothingToDoResponse: JSONValue {
        toolUseResponse(
            .object(["summary": "Nothing needs filing", "actions": .array([])]),
            id: "plan_none",
            outputTokens: 42
        )
    }

    /// `stop_reason: "refusal"` with `stop_details`.
    static var refusalResponse: JSONValue {
        .object([
            "id": "msg_refusal",
            "type": "message",
            "role": "assistant",
            "model": .string(AIModel.defaultOrganize.id),
            "content": .array([]),
            "stop_reason": "refusal",
            "stop_details": .object([
                "type": "refusal",
                "category": "cyber",
                "explanation": "The request was declined by a safety classifier.",
            ]),
            "usage": .object(["input_tokens": 1_840, "output_tokens": 0]),
        ])
    }

    /// `GET /v1/models` (plan §1 amendment 4: validation is free).
    static var modelsListResponse: JSONValue {
        .object([
            "data": .array([
                model("claude-opus-5", "Claude Opus 5", input: 1_000_000, output: 128_000, adaptive: true),
                model("claude-sonnet-5", "Claude Sonnet 5", input: 1_000_000, output: 128_000, adaptive: true),
                model("claude-haiku-4-5", "Claude Haiku 4.5", input: 200_000, output: 64_000, adaptive: false),
            ]),
            "has_more": .bool(false),
        ])
    }

    private static func model(
        _ id: String, _ name: String, input: Int, output: Int, adaptive: Bool
    ) -> JSONValue {
        .object([
            "type": "model",
            "id": .string(id),
            "display_name": .string(name),
            "created_at": "2026-02-01T00:00:00Z",
            "max_input_tokens": .integer(input),
            "max_tokens": .integer(output),
            "capabilities": .object([
                "thinking": .object(["types": .object(["adaptive": .object(["supported": .bool(adaptive)])])]),
            ]),
        ])
    }

    // MARK: - Catalogue

    struct Scenario {
        var name: String
        var request: AIRequest
        var response: JSONValue
    }

    static var scenarios: [Scenario] {
        [
            Scenario(name: "organize: a valid plan", request: validPlanRequest, response: validPlanResponse),
            Scenario(name: "organize: a plan the validator rejects", request: invalidPlanRequest, response: invalidPlanResponse),
            Scenario(name: "organize: nothing to do", request: nothingToDoRequest, response: nothingToDoResponse),
            Scenario(name: "organize: the model refused", request: refusalRequest, response: refusalResponse),
        ]
    }

    static func recordings() -> [AIRecording] {
        var out = scenarios.map { scenario in
            AIRecording(
                purpose: scenario.request.purpose,
                key: scenario.request.fixtureKey,
                model: scenario.request.model.id,
                recordedAt: nil,
                note: "hand-authored (M2-02) — \(scenario.name)",
                request: scenario.request,
                requestBody: ClaudeWire.body(for: scenario.request),
                responseBody: scenario.response
            )
        }
        out.append(AIRecording(
            purpose: .validate,
            key: ReplayProvider.validateKeyFixtureKey,
            model: "",
            recordedAt: nil,
            note: "hand-authored (M2-02) — GET /v1/models, key validation",
            request: AIRequest(model: AIModel(""), purpose: .validate, messages: []),
            requestBody: .object(["method": "GET", "path": "/v1/models?limit=100"]),
            responseBody: modelsListResponse
        ))
        return out
    }
}
