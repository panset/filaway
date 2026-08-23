import Foundation

@testable import FilawayCore

/// The M3-05 answer-extraction goldens.
///
/// Each scenario is a query plus a fixed ``SemanticResults`` — the *output* of
/// retrieval, built by hand rather than by indexing a corpus. That is
/// deliberate: the fixture filename is a hash of the request, and a request
/// built from a live index would move whenever the embedder, the chunker or a
/// note's mtime moved. Retrieval has its own end-to-end suites
/// (`HybridSearchTests`, `RetrievalTests`); this one is about the *answer*.
///
/// The requests are captured from the real builder and the responses are
/// hand-authored, because this machine has no API key:
///
/// ```
/// FILAWAY_WRITE_AI_FIXTURES=1 swift test --filter "regenerate the answer goldens"
/// ```
///
/// Re-record against the live API once a key exists (plan M4-09):
///
/// ```
/// FILAWAY_AI_MODE=record swift test --filter "Answer goldens"
/// ```
enum AnswerGolden {

    // MARK: - The library every scenario retrieves from

    static let curlID = NoteID(UUID(uuidString: "70111111-1111-4111-8111-000000000001")!)
    static let authID = NoteID(UUID(uuidString: "70222222-2222-4222-8222-000000000002")!)
    static let dockerID = NoteID(UUID(uuidString: "70333333-3333-4333-8333-000000000003")!)
    static let privateID = NoteID(UUID(uuidString: "70444444-4444-4444-8444-000000000004")!)

    /// Fixed instants, so the rendered `edited:` lines — and therefore the
    /// fixture keys — never move.
    static let curlModified = Date(timeIntervalSince1970: 1_755_820_800) // 2025-08-22T00:00:00Z
    static let authModified = Date(timeIntervalSince1970: 1_755_907_200)
    static let dockerModified = Date(timeIntervalSince1970: 1_755_648_000)

    /// The command Figure 2b puts on the card.
    static let curlCommand = #"curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs"#

    static let curlProseText = """
    curl › Fetch documents

    The documents endpoint is paginated and wants a bearer token. The token is the
    staging one, not the production one.
    """

    static let curlCodeText = """
    curl › Fetch documents
    curl to fetch docs from staging:
    ```bash
    \(curlCommand)
    ```
    """

    static let authText = """
    Auth API debug

    The 401 only happens after the bearer token rotates. Rotate the staging token,
    then check the refresh window before blaming the gateway.
    """

    static let dockerCodeText = """
    Docker cheats › Health
    the container health check:
    ```bash
    curl -fsS http://localhost:8080/healthz
    ```
    """

    /// A three-line fence, so "trim it to the lines that matter" is assertable.
    static let tokenCodeText = """
    Auth API debug › Rotating
    rotate and re-export:
    ```bash
    op signin
    export TOK=$(op read "op://staging/api/token")
    curl -sS -H "Auth: Bearer $TOK" https://api.st.app/v2/whoami
    ```
    """

    static let exportLine = #"export TOK=$(op read "op://staging/api/token")"#

    // MARK: - Chunk construction

    static func chunk(
        id: Int64,
        noteID: NoteID,
        title: String,
        path: String,
        modified: Date,
        kind: ChunkKind,
        headingPath: [String],
        language: String?,
        text: String,
        score: Double,
        location: Int = 0
    ) -> RankedChunk {
        RankedChunk(
            id: id,
            noteID: noteID,
            title: title,
            relativePath: path,
            modified: modified,
            kind: kind,
            headingPath: headingPath,
            range: MatchRange(location: location, length: (text as NSString).length),
            language: language,
            text: text,
            score: score,
            vectorRank: 1,
            vectorScore: 0.72,
            keywordRank: kind == .code ? 1 : nil
        )
    }

    static var curlProse: RankedChunk {
        chunk(id: 101, noteID: curlID, title: "curl", path: "Commands/curl.md",
              modified: curlModified, kind: .prose, headingPath: ["curl", "Fetch documents"],
              language: nil, text: curlProseText, score: 0.0198, location: 40)
    }

    static var curlCode: RankedChunk {
        chunk(id: 102, noteID: curlID, title: "curl", path: "Commands/curl.md",
              modified: curlModified, kind: .code, headingPath: ["curl", "Fetch documents"],
              language: "bash", text: curlCodeText, score: 0.0312, location: 220)
    }

    static var authProse: RankedChunk {
        chunk(id: 201, noteID: authID, title: "Auth API debug", path: "Auth API debug.md",
              modified: authModified, kind: .prose, headingPath: ["Auth API debug"],
              language: nil, text: authText, score: 0.0176, location: 0)
    }

    static var tokenCode: RankedChunk {
        chunk(id: 202, noteID: authID, title: "Auth API debug", path: "Auth API debug.md",
              modified: authModified, kind: .code, headingPath: ["Auth API debug", "Rotating"],
              language: "bash", text: tokenCodeText, score: 0.0161, location: 300)
    }

    static var dockerCode: RankedChunk {
        chunk(id: 301, noteID: dockerID, title: "Docker cheats", path: "Docker cheats.md",
              modified: dockerModified, kind: .code, headingPath: ["Docker cheats", "Health"],
              language: "bash", text: dockerCodeText, score: 0.0154, location: 60)
    }

    /// Never in any scenario's chunk list — `Private` is excluded (FR-4.5), so
    /// it is not indexed and cannot be retrieved. Kept here so the leak
    /// assertion has a distinctive string to grep every committed fixture for.
    static let privateText = "compensation figure is 88888 and must never leave this machine"

    static func results(
        query: String,
        strippedQuery: String? = nil,
        dateRange: DateRange? = nil,
        chunks: [RankedChunk]
    ) -> SemanticResults {
        var byNote: [NoteID: (chunk: RankedChunk, count: Int)] = [:]
        var order: [NoteID] = []
        for chunk in chunks {
            if let existing = byNote[chunk.noteID] {
                byNote[chunk.noteID] = (existing.chunk, existing.count + 1)
            } else {
                byNote[chunk.noteID] = (chunk, 1)
                order.append(chunk.noteID)
            }
        }
        let notes = order.compactMap { id -> RankedNote? in
            guard let entry = byNote[id] else { return nil }
            return RankedNote(
                id: id,
                title: entry.chunk.title,
                relativePath: entry.chunk.relativePath,
                modified: entry.chunk.modified,
                score: entry.chunk.score,
                bestChunk: entry.chunk,
                matchingChunks: entry.count
            )
        }
        return SemanticResults(
            query: query,
            strippedQuery: strippedQuery ?? query,
            dateRange: dateRange,
            chunks: chunks,
            notes: notes,
            usedVectors: true,
            usedKeywords: true
        )
    }

    // MARK: - Scenarios

    struct Scenario: Sendable, CustomStringConvertible {
        var name: String
        /// What the fixture file is *for*, in one line.
        var note: String
        var query: String
        var results: SemanticResults
        /// The hand-authored wire response.
        var response: JSONValue

        var description: String { name }
    }

    static let scenarios: [Scenario] = [
        Scenario(
            name: "curl-code-card",
            note: "FR-5.2 Figure 2b — the command comes back as the card's snippet",
            query: "curl command to fetch documents",
            results: results(
                query: "curl command to fetch documents",
                chunks: [curlCode, curlProse, dockerCode, authProse]
            ),
            response: selection(
                best: 1, snippet: curlCommand, confidence: "high", ranked: [1, 3, 4],
                inputTokens: 1_190, outputTokens: 96
            )
        ),
        Scenario(
            name: "temporal-auth",
            note: "FR-5.3 — a date-filtered query with no snippet to copy: prose card + ranking",
            query: "the thing I edited two days ago about auth",
            results: results(
                query: "the thing I edited two days ago about auth",
                strippedQuery: "the thing I edited about auth",
                dateRange: DateRange(
                    start: Date(timeIntervalSince1970: 1_755_820_800),
                    end: Date(timeIntervalSince1970: 1_755_993_600)
                ),
                chunks: [authProse, tokenCode]
            ),
            response: selection(
                best: 1, snippet: nil, confidence: "medium", ranked: [1, 2],
                inputTokens: 640, outputTokens: 58
            )
        ),
        Scenario(
            name: "no-answer",
            note: "nothing in the list answers the question — best_chunk_id is null (FR-5.2)",
            query: "how do I renew my passport",
            results: results(
                query: "how do I renew my passport",
                chunks: [curlProse, dockerCode]
            ),
            response: selection(
                best: nil, snippet: nil, confidence: "low", ranked: [],
                inputTokens: 590, outputTokens: 34
            )
        ),
        Scenario(
            name: "trimmed-snippet",
            note: "a three-line fence trimmed to the one line that was asked about",
            query: "how do I export the staging token",
            results: results(
                query: "how do I export the staging token",
                chunks: [tokenCode, authProse]
            ),
            response: selection(
                best: 1, snippet: exportLine, confidence: "high", ranked: [1, 2],
                inputTokens: 680, outputTokens: 71
            )
        ),
        Scenario(
            name: "invented-snippet",
            note: "the model returns a command that is not in the chunk — it must never reach the card",
            query: "curl the documents endpoint with a token",
            results: results(
                query: "curl the documents endpoint with a token",
                chunks: [curlCode, curlProse]
            ),
            response: selection(
                best: 1,
                snippet: #"curl -H "Authorization: Bearer $TOKEN" https://api.st.app/v2/documents --fail"#,
                confidence: "high", ranked: [1, 2],
                inputTokens: 610, outputTokens: 88
            )
        ),
    ]

    static func scenario(_ name: String) -> Scenario {
        scenarios.first { $0.name == name }!
    }

    // MARK: - Wire responses

    static func selection(
        best: Int?,
        snippet: String?,
        confidence: String,
        ranked: [Int],
        inputTokens: Int,
        outputTokens: Int
    ) -> JSONValue {
        let input: JSONValue = .object([
            "best_chunk_id": best.map { JSONValue.integer($0) } ?? .null,
            "snippet": snippet.map { JSONValue.string($0) } ?? .null,
            "confidence": .string(confidence),
            "ranked_chunk_ids": .array(ranked.map { .integer($0) }),
        ])
        return .object([
            "id": "msg_answer",
            "type": "message",
            "role": "assistant",
            "model": .string(AIModel.defaultSearch.id),
            "content": .array([
                .object([
                    "type": "tool_use",
                    "id": "toolu_answer",
                    "name": .string(AnswerSelection.toolName),
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

    // MARK: - Wiring

    /// The extractor every scenario uses: the bundled `answer.v1`, Haiku, the
    /// house 5 s budget.
    static func configuration(
        timeout: TimeInterval = 5,
        model: AIModel = .defaultSearch
    ) -> AnswerExtractor.Configuration {
        AnswerExtractor.Configuration(
            model: model, timeout: timeout, promptsDirectory: AITestPaths.prompts
        )
    }

    static func extractor(
        provider: any AIProvider,
        ledger: AIUsageLedger? = nil,
        timeout: TimeInterval = 5
    ) -> AnswerExtractor {
        AnswerExtractor(provider: provider, ledger: ledger, configuration: configuration(timeout: timeout))
    }

    static func request(for scenario: Scenario) throws -> AIRequest {
        try AnswerExtractor.request(
            query: scenario.query,
            chunks: scenario.results.promptChunks,
            configuration: configuration()
        )
    }
}
