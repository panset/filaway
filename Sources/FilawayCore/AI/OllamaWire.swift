import Foundation

/// The exact JSON a local Ollama daemon speaks, in both directions (P2-01).
///
/// The same shape as ``ClaudeWire``: a pure encoder/decoder with no transport,
/// so every branch is unit testable offline and the record/replay harness can
/// store *wire* bodies for this provider too.
///
/// API surface as of Ollama 0.32.15:
///
/// * `POST <base>/api/chat`, `content-type: application/json`, no credential.
/// * `"stream": false` — Filaway wants one complete message, never a token
///   stream; the answer card and the plan are both all-or-nothing.
/// * **Structured output is `"format": <JSON schema>`, not tool calling.**
///   Ollama accepts `tools` and will emit `message.tool_calls`, but it has no
///   `tool_choice`: a tool is a suggestion, and an 8B model routinely answers in
///   prose instead. `format` is a hard grammar constraint on the decoder, so the
///   content *is* the JSON. Filaway only ever forces exactly one tool, so the
///   mapping is total: the forced tool's `inputSchema` becomes `format`, and the
///   response is turned back into the `tool_use` block every caller above
///   already reads (ADR-066).
/// * `"options": {"temperature": 0, "num_predict": …}` — determinism, and the
///   output cap under the name Ollama uses for it.
/// * `"keep_alive": "30m"` — a cold model load costs seconds, and the next
///   session or search is usually minutes away, not hours.
///
/// Never sent: `thinking`, `output_config`, `tool_choice`. The first two are
/// Anthropic fields; the third does not exist here.
public enum OllamaWire {
    public static let defaultBaseURL = OllamaConfiguration.defaultBaseURL
    /// How long the daemon should keep the model resident after a call.
    public static let keepAlive = "30m"
    public static let chatPath = "/api/chat"
    public static let tagsPath = "/api/tags"

    // MARK: - Request

    /// Builds the `POST /api/chat` body.
    ///
    /// The forced tool's description is appended to the system text **here, at
    /// wire time only**: ``AIRequest``, the prompt files and
    /// ``AIRequest/fixtureKey`` are all untouched, so the same request hashes to
    /// the same fixture whichever provider serves it.
    public static func body(for request: AIRequest) -> JSONValue {
        var messages: [JSONValue] = []
        let system = systemText(for: request)
        if !system.isEmpty {
            messages.append(.object(["role": "system", "content": .string(system)]))
        }
        messages.append(contentsOf: request.messages.map(messageValue))

        var object: [String: JSONValue] = [
            "model": .string(request.model.id),
            "stream": .bool(false),
            "messages": .array(messages),
            "options": .object([
                "temperature": .integer(0),
                "num_predict": .integer(request.maxTokens),
            ]),
            "keep_alive": .string(keepAlive),
        ]

        if let tool = request.forcedTool {
            // A forced tool becomes a grammar, not a tool.
            object["format"] = tool.inputSchema
        } else if !request.tools.isEmpty {
            // `.auto`/`.any`/`.none` — unused by Filaway today, but a caller
            // that offers tools without forcing one gets Ollama's own shape.
            object["tools"] = .array(request.tools.map(toolValue))
        }
        return .object(object)
    }

    /// The system message's text: the request's own system prompt, plus the
    /// forced tool's instructions when there is one.
    public static func systemText(for request: AIRequest) -> String {
        var parts: [String] = []
        if let system = request.system, !system.isEmpty { parts.append(system) }
        if let tool = request.forcedTool { parts.append(instructions(for: tool)) }
        return parts.joined(separator: "\n\n")
    }

    /// What replaces `tool_choice` for a model that has none: the tool's own
    /// description, plus the two sentences that keep an 8B model from wrapping
    /// its JSON in prose or a code fence, plus — for the tools that have one —
    /// the short list of rules a small model actually breaks.
    public static func instructions(for tool: AITool) -> String {
        var parts = [
            """
            Respond with a single JSON object for the tool "\(tool.name)": \(tool.description)
            Return only that JSON object. No prose, no explanation, no code fences.
            """,
        ]
        if let rules = smallModelRules[tool.name] { parts.append(rules) }
        return parts.joined(separator: "\n\n")
    }

    /// Per-tool restatement of the rules an 8B model breaks, appended **at wire
    /// time** (P2-04, ADR-070).
    ///
    /// It does not live in `organize.v1.txt` for two reasons, and both matter:
    ///
    /// * The prompt files are frozen (`docs/prompts.md`) and shared by every
    ///   provider. Sonnet does not need to be told twice, and paying for a
    ///   restatement on every Claude call to help a local model would be the
    ///   wrong trade.
    /// * ``AIRequest/fixtureKey`` hashes ``AIRequest/system``, not the rendered
    ///   wire body. Adding this here leaves every committed fixture — Claude's
    ///   and Ollama's — on the key it already has.
    ///
    /// The wording is deliberately *negative and specific*: each line names an
    /// error ``PlanValidator`` actually rejected on this corpus
    /// (`titleCollision`, `segmentNotFound`, `unknownFolder`, `unknownNote`),
    /// and the rules are last in the system message, where a small model weighs
    /// them most. See `docs/verification/P2-ollama.md` for the before/after.
    static let smallModelRules: [String: String] = [
        OrganizationPlan.toolName: """
        Before you answer, check your plan against each of these. A plan that \
        breaks any of them is thrown away and the person gets nothing:

        - Never use "createNote" whose "title" and "folderPath" together name a \
        note that is already in the library above. That note exists. Append to \
        it with "appendToNote" and its id instead.
        - "segment" in "moveSegment" must be copied character for character out \
        of the session text above, opening and closing code fences included. If \
        you cannot copy it exactly, use "appendToNote" instead.
        - Every "folderPath" must be a folder listed above, or one a \
        "createFolder" action in this same plan creates. Never name a folder \
        that does not exist.
        - A "folderPath" has at most two levels, like "Projects/Cinegram" or \
        "Commands" — never a deeper path like "Home/Projects/Cinegram/Skills", \
        and never an invented top folder to hold it.
        - Copy every "id" exactly as it is written above. Never invent one, and \
        never use an id that is not listed.
        - "actions": [] is a correct and welcome answer when the session is \
        already where it belongs.
        - Keep the plan short. Prefer "moveNote", "retitleNote" and "tagNote", \
        which name a note by id. Never copy a note\'s existing text into a \
        "content" field — "content" is only for NEW material quoted from the \
        session text. A long plan is cut off and thrown away.
        """,
    ]

    static func messageValue(_ message: AIMessage) -> JSONValue {
        .object(["role": .string(message.role.rawValue), "content": .string(message.text)])
    }

    /// Ollama's OpenAI-flavoured tool shape, for the unforced case.
    static func toolValue(_ tool: AITool) -> JSONValue {
        .object([
            "type": "function",
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
            ]),
        ])
    }

    // MARK: - Response

    /// Decodes `POST /api/chat` for `request`.
    ///
    /// The request is what says whether a tool was forced — and therefore
    /// whether `message.content` is JSON to be lifted into a `tool_use` block,
    /// or prose to be kept as text.
    public static func response(
        from value: JSONValue,
        for request: AIRequest,
        requestID: String? = nil
    ) throws -> AIResponse {
        try response(from: value, requestID: requestID, forcedToolName: request.forcedToolName)
    }

    /// Decodes `POST /api/chat`.
    ///
    /// - Parameter forcedToolName: the tool whose schema was sent as `format`.
    ///   When it is set, `message.content` **must** parse as JSON — anything
    ///   else is ``AIError/malformedResponse(_:)``, never a silently empty plan.
    public static func response(
        from value: JSONValue,
        requestID: String? = nil,
        forcedToolName: String? = nil
    ) throws -> AIResponse {
        guard let object = value.objectValue else {
            throw AIError.malformedResponse("response is \(value.typeName), expected an object")
        }
        // `{"error": "…"}` — the daemon's whole error envelope.
        if let message = errorMessage(from: value) {
            throw AIError.badRequest(message: message)
        }
        guard let model = object["model"]?.stringValue else {
            throw AIError.malformedResponse("missing \"model\"")
        }
        guard let message = object["message"]?.objectValue else {
            throw AIError.malformedResponse("missing \"message\" object")
        }

        let text = message["content"]?.stringValue ?? ""
        let doneReason = object["done_reason"]?.stringValue
        var content: [AIContentBlock] = []
        var stopReason: AIStopReason

        if doneReason == "length" {
            // `num_predict` ran out. Whatever is in `content` is truncated —
            // half a JSON object at best — so it is never parsed as a tool call.
            // Callers check `isTruncated` before trusting anything.
            stopReason = .maxTokens
            if !text.isEmpty { content.append(.text(text)) }
        } else if let forcedToolName {
            guard let input = try? JSONValue.parse(text), input.objectValue != nil else {
                throw AIError.malformedResponse(
                    "\"format\" was set for \(forcedToolName) but the content is not a JSON object "
                        + "(\(text.utf8.count) bytes)"
                )
            }
            content.append(.toolUse(id: "ollama-1", name: forcedToolName, input: input))
            stopReason = .toolUse
        } else if let calls = message["tool_calls"]?.arrayValue, !calls.isEmpty {
            // Ollama-native tool calling, for a caller that did not force one.
            if !text.isEmpty { content.append(.text(text)) }
            for (index, call) in calls.enumerated() {
                guard let function = call["function"]?.objectValue,
                      let name = function["name"]?.stringValue
                else {
                    throw AIError.malformedResponse("tool call without \"function\".\"name\"")
                }
                content.append(.toolUse(
                    id: call["id"]?.stringValue ?? "ollama-\(index + 1)",
                    name: name,
                    input: function["arguments"] ?? .object([:])
                ))
            }
            stopReason = .toolUse
        } else {
            content.append(.text(text))
            stopReason = .endTurn
        }

        if let doneReason, doneReason != "length", doneReason != "stop" {
            stopReason = .other(doneReason)
        }

        return AIResponse(
            id: identifier(from: object),
            model: model,
            content: content,
            stopReason: stopReason,
            stopDetails: nil,
            usage: AIUsage(
                inputTokens: object["prompt_eval_count"]?.intValue ?? 0,
                outputTokens: object["eval_count"]?.intValue ?? 0
            ),
            requestID: requestID
        )
    }

    /// Ollama has no message id. One is synthesised from `created_at`, which
    /// makes a recorded exchange round-trip byte for byte; ``value(for:)``
    /// writes the id back out under `"id"` so a re-recorded fixture keeps it.
    static func identifier(from object: [String: JSONValue]) -> String {
        if let id = object["id"]?.stringValue, !id.isEmpty { return id }
        if let created = object["created_at"]?.stringValue, !created.isEmpty { return "ollama-\(created)" }
        return "ollama-\(UUID().uuidString)"
    }

    /// Re-encodes a response into wire form, for ``RecordingProvider``.
    ///
    /// A synthesised `tool_use` block goes back where it came from — the JSON
    /// text of `message.content` — so replaying a fixture runs the very same
    /// decoder a live call does.
    public static func value(for response: AIResponse) -> JSONValue {
        var text = ""
        var toolCalls: [JSONValue] = []
        var wroteFormatContent = false

        for block in response.content {
            switch block {
            case let .text(value):
                text += text.isEmpty ? value : "\n" + value
            case let .toolUse(_, name, input):
                if response.stopReason == .toolUse, !wroteFormatContent, text.isEmpty {
                    // The `format` path: the content *was* this JSON.
                    text = String(decoding: (try? input.canonicalData()) ?? Data(), as: UTF8.self)
                    wroteFormatContent = true
                } else {
                    toolCalls.append(.object([
                        "function": .object(["name": .string(name), "arguments": input]),
                    ]))
                }
            case let .thinking(value):
                text += text.isEmpty ? value : "\n" + value
            case let .other(_, payload):
                toolCalls.append(payload)
            }
        }

        var message: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
        if !toolCalls.isEmpty { message["tool_calls"] = .array(toolCalls) }

        return .object([
            "id": .string(response.id),
            "model": .string(response.model),
            "message": .object(message),
            "done": .bool(true),
            "done_reason": .string(doneReason(for: response.stopReason)),
            "prompt_eval_count": .integer(response.usage.inputTokens),
            "eval_count": .integer(response.usage.outputTokens),
        ])
    }

    static func doneReason(for stopReason: AIStopReason) -> String {
        switch stopReason {
        case .maxTokens: return "length"
        case .endTurn, .toolUse: return "stop"
        default: return stopReason.rawValue
        }
    }

    // MARK: - Models

    /// Decodes `GET /api/tags`.
    ///
    /// A pulled model has no display name and no token limits of its own, so
    /// only ``AIModelInfo/id``, ``AIModelInfo/displayName`` and
    /// ``AIModelInfo/createdAt`` are populated; `supportsAdaptiveThinking` is
    /// `false`, because adaptive thinking is an Anthropic field.
    public static func models(from value: JSONValue) throws -> [AIModelInfo] {
        guard let models = value["models"]?.arrayValue else {
            throw AIError.malformedResponse("missing \"models\" array in the tag list")
        }
        return models.compactMap { entry in
            guard let object = entry.objectValue,
                  let name = object["name"]?.stringValue ?? object["model"]?.stringValue
            else { return nil }
            return AIModelInfo(
                id: name,
                displayName: name,
                createdAt: object["modified_at"]?.stringValue.flatMap(ISO8601.date(from:)),
                supportsAdaptiveThinking: false
            )
        }
    }

    /// Re-encodes a model list into `GET /api/tags` form, for
    /// ``RecordingProvider``.
    public static func modelsValue(for models: [AIModelInfo]) -> JSONValue {
        .object(["models": .array(models.map { model in
            var object: [String: JSONValue] = ["name": .string(model.id), "model": .string(model.id)]
            if let modified = model.createdAt { object["modified_at"] = .string(ISO8601.string(from: modified)) }
            return .object(object)
        })])
    }

    // MARK: - Errors

    /// Pulls the message out of `{"error": "…"}` (or `{"error": {"message": …}}`,
    /// which some proxies in front of Ollama produce).
    public static func errorMessage(from value: JSONValue) -> String? {
        guard let error = value["error"] else { return nil }
        return error.stringValue ?? error["message"]?.stringValue ?? "unknown error"
    }

    public static func errorMessage(from data: Data) -> String? {
        guard let value = try? JSONValue.parse(data) else { return nil }
        return errorMessage(from: value)
    }
}
