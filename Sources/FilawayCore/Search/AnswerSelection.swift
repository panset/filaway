import Foundation

/// The strict tool `answer.v1` is forced to call (M3-05, FR-5.2).
///
/// Four fields, all required, nothing free-form:
///
/// ```json
/// {"best_chunk_id": 3 | null,
///  "snippet": "curl -H …" | null,
///  "confidence": "low" | "medium" | "high",
///  "ranked_chunk_ids": [3, 1, 5]}
/// ```
///
/// `best_chunk_id` is a **1-based position in the list the prompt shows**, not a
/// database row id. Two reasons: the model counts short integers far more
/// reliably than 6-digit ones, and a fixture key must not move because a note
/// was reindexed and its chunk rows were renumbered.
public enum AnswerSelection {
    public static let toolName = "answer_selection"

    /// How many chunks the prompt ever shows.
    ///
    /// Follows ``SemanticResults/promptChunkLimit`` rather than pinning its own
    /// number: M3-07 measured that eight chunks lose the answer outright on
    /// paraphrased queries, and no amount of reranking inside eight can recover
    /// a chunk that was never in them (ADR-047).
    public static var maxChunks: Int { SemanticResults.promptChunkLimit }

    public static var tool: AITool {
        AITool(
            name: toolName,
            description: """
            Report which of the numbered chunks answers the question, the exact snippet to \
            show if the answer is a command or code, and the chunks in order of usefulness. \
            Call this tool exactly once.
            """,
            inputSchema: toolSchema,
            strict: true
        )
    }

    public static var toolSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "best_chunk_id": .object([
                    "type": .array(["integer", "null"]),
                    "description": .string(
                        "The number of the chunk that best answers the query, or null if none of "
                        + "them does. Never invent a number that is not in the list."
                    ),
                ]),
                "snippet": .object([
                    "type": .array(["string", "null"]),
                    "description": .string(
                        "The answer as it appears in that chunk, copied verbatim and trimmed to the "
                        + "lines that matter. Omit the code fences. null when the answer is not a "
                        + "command or snippet, or when best_chunk_id is null."
                    ),
                ]),
                "confidence": .object([
                    "type": "string",
                    "enum": .array(AnswerConfidence.allCases.map { .string($0.rawValue) }),
                    "description": "How well the chosen chunk actually answers the query.",
                ]),
                "ranked_chunk_ids": .object([
                    "type": "array",
                    "description": .string(
                        "Every chunk number worth showing, most useful first. May be empty. "
                        + "Do not repeat a number and do not invent one."
                    ),
                    "items": .object(["type": "integer"]),
                ]),
            ]),
            "required": .array(["best_chunk_id", "snippet", "confidence", "ranked_chunk_ids"]),
            "additionalProperties": .bool(false),
        ])
    }

    /// The tool call, read back.
    public struct Decoded: Sendable, Hashable {
        /// 1-based position in the prompt list, already range-checked.
        public var bestChunk: Int?
        public var snippet: String?
        public var confidence: AnswerConfidence
        /// 1-based positions, de-duplicated and range-checked.
        public var rankedChunks: [Int]

        public init(
            bestChunk: Int? = nil,
            snippet: String? = nil,
            confidence: AnswerConfidence = .low,
            rankedChunks: [Int] = []
        ) {
            self.bestChunk = bestChunk
            self.snippet = snippet
            self.confidence = confidence
            self.rankedChunks = rankedChunks
        }
    }

    public enum DecodingFailure: Error, Equatable, CustomStringConvertible {
        case unusableStopReason(AIStopReason)
        case noToolCall
        case badShape(String)

        public var description: String {
            switch self {
            case let .unusableStopReason(reason): "the model stopped with \(reason.rawValue)"
            case .noToolCall: "the model answered without calling \(AnswerSelection.toolName)"
            case let .badShape(detail): "\(AnswerSelection.toolName) input was unusable: \(detail)"
            }
        }
    }

    /// Reads the tool call out of a response.
    ///
    /// - Parameter chunkCount: how many chunks the prompt showed. Anything
    ///   outside `1...chunkCount` is dropped rather than trusted — a
    ///   hallucinated index must not become an answer card pointing at the
    ///   wrong note.
    public static func decode(response: AIResponse, chunkCount: Int) throws -> Decoded {
        guard response.stopReason.isUsable else {
            throw DecodingFailure.unusableStopReason(response.stopReason)
        }
        guard let call = response.toolUse(named: toolName) else { throw DecodingFailure.noToolCall }
        return try decode(input: call.input, chunkCount: chunkCount)
    }

    public static func decode(input: JSONValue, chunkCount: Int) throws -> Decoded {
        guard input.objectValue != nil else { throw DecodingFailure.badShape(input.typeName) }
        let valid = 1...max(chunkCount, 1)

        var decoded = Decoded()
        if let best = input["best_chunk_id"]?.intValue, valid.contains(best), chunkCount > 0 {
            decoded.bestChunk = best
        }
        if let snippet = input["snippet"]?.stringValue {
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            decoded.snippet = trimmed.isEmpty ? nil : trimmed
        }
        if let raw = input["confidence"]?.stringValue, let confidence = AnswerConfidence(rawValue: raw) {
            decoded.confidence = confidence
        }
        var seen: Set<Int> = []
        for value in input["ranked_chunk_ids"]?.arrayValue ?? [] {
            guard let index = value.intValue, valid.contains(index), chunkCount > 0,
                  seen.insert(index).inserted else { continue }
            decoded.rankedChunks.append(index)
        }
        return decoded
    }
}

/// Renders `SemanticResults.promptChunks` into the user message `answer.v1`
/// reads (M3-05).
///
/// The shape is fixed here rather than in the prompt file because the fixture
/// key is a hash of the rendered message: a change to either the wording or the
/// layout must move the key, which is exactly what makes a stale recording
/// impossible to reuse (plan §9).
public enum AnswerPrompt {
    /// The chunk body is capped so a full slice cannot blow past Haiku's budget
    /// on a note that is one enormous code block.
    public static let maxChunkCharacters = 1_400

    public static func userMessage(query: String, chunks: [RankedChunk]) -> String {
        var lines: [String] = ["Question: \(query.trimmingCharacters(in: .whitespacesAndNewlines))", ""]
        if chunks.isEmpty {
            lines.append("No chunks were retrieved.")
            return lines.joined(separator: "\n")
        }
        lines.append("Chunks:")
        for (offset, chunk) in chunks.enumerated() {
            lines.append("")
            lines.append("[\(offset + 1)] \(chunk.title) — \(chunk.relativePath)")
            lines.append("edited: \(ISO8601.string(from: chunk.modified))")
            if !chunk.headingPath.isEmpty {
                lines.append("section: \(chunk.headingBreadcrumb)")
            }
            let language = chunk.language.map { " (\($0))" } ?? ""
            lines.append("kind: \(chunk.kind.rawValue)\(language)")
            lines.append("---")
            lines.append(clip(chunk.text))
            lines.append("---")
        }
        return lines.joined(separator: "\n")
    }

    static func clip(_ text: String) -> String {
        guard text.count > maxChunkCharacters else { return text }
        return String(text.prefix(maxChunkCharacters)) + "\n…"
    }
}
