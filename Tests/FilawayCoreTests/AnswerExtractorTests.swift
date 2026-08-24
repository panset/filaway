import Foundation
import Testing

@testable import FilawayCore

/// M3-05 — the request `answer.v1` is asked with, and the tool it is forced to
/// call.
@Suite("Answer request encoding (M3-05)")
struct AnswerRequestTests {

    @Test("the prompt resource ships and is the system string")
    func promptShips() throws {
        #expect(PromptLibrary.exists(.answer, in: AITestPaths.prompts))
        let request = try AnswerGolden.request(for: AnswerGolden.scenario("curl-code-card"))
        let system = try #require(request.system)
        #expect(system.contains("`answer_selection`"))
        #expect(system.contains("verbatim"))
    }

    @Test("Haiku gets no thinking and no effort")
    func haikuContract() throws {
        let request = try AnswerGolden.request(for: AnswerGolden.scenario("curl-code-card"))
        #expect(request.model == .haiku45)
        #expect(request.model == .defaultSearch)
        #expect(request.thinking == nil, "Haiku 4.5 is on the pre-4.6 budget_tokens contract")
        #expect(request.effort == nil)

        let body = ClaudeWire.body(for: request)
        #expect(body["thinking"] == nil)
        #expect(body["output_config"] == nil)
        #expect(body["max_tokens"]?.intValue == 600)
        #expect(body["tool_choice"]?["name"]?.stringValue == AnswerSelection.toolName)
    }

    @Test("a model that does take adaptive thinking gets it")
    func adaptiveModel() throws {
        let request = try AnswerExtractor.request(
            query: "q",
            chunks: AnswerGolden.scenario("curl-code-card").results.promptChunks,
            configuration: AnswerGolden.configuration(model: .sonnet5)
        )
        #expect(request.thinking == .adaptive())
        #expect(request.effort == .low)
    }

    @Test("the search purpose sets the budget and the ledger bucket")
    func purpose() throws {
        let request = try AnswerGolden.request(for: AnswerGolden.scenario("no-answer"))
        #expect(request.purpose == .search)
        // The *provider's* budget is the kind's (P2-03); NFR-1's 5 s answer
        // race is enforced inside the actor, not on the wire (ADR-069).
        #expect(request.timeout == AIProviderKind.claude.timeout(for: .search))
    }

    @Test("the tool is strict and closed")
    func strictTool() throws {
        let tool = AnswerSelection.tool
        #expect(tool.strict)
        #expect(tool.name == "answer_selection")
        let schema = tool.inputSchema
        #expect(schema["additionalProperties"]?.boolValue == false)
        let requiredValues = try #require(schema["required"]?.arrayValue)
        let required = requiredValues.compactMap(\.stringValue)
        #expect(Set(required) == ["best_chunk_id", "snippet", "confidence", "ranked_chunk_ids"])
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(Set(properties.keys) == Set(required))
        #expect(properties["best_chunk_id"]?["type"]?.arrayValue?.compactMap(\.stringValue) == ["integer", "null"])
        #expect(properties["snippet"]?["type"]?.arrayValue?.compactMap(\.stringValue) == ["string", "null"])
        #expect(
            properties["confidence"]?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["low", "medium", "high"]
        )
    }

    @Test("chunks are numbered from one, in retrieval order, with their metadata")
    func userMessage() {
        let scenario = AnswerGolden.scenario("curl-code-card")
        let message = AnswerPrompt.userMessage(query: scenario.query, chunks: scenario.results.promptChunks)
        #expect(message.hasPrefix("Question: curl command to fetch documents"))
        #expect(message.contains("[1] curl — Commands/curl.md"))
        #expect(message.contains("[2] curl — Commands/curl.md"))
        #expect(message.contains("[3] Docker cheats — Docker cheats.md"))
        #expect(message.contains("kind: code (bash)"))
        #expect(message.contains("section: curl › Fetch documents"))
        #expect(message.contains("edited: 2025-08-22T00:00:00Z"))
        #expect(message.contains(AnswerGolden.curlCommand))
    }

    @Test("the prompt never shows more chunks than retrieval hands over")
    func promptChunkCap() {
        let many = (0..<(SemanticResults.promptChunkLimit + 12)).map { index in
            AnswerGolden.chunk(
                id: Int64(1_000 + index), noteID: AnswerGolden.curlID, title: "n\(index)",
                path: "n\(index).md", modified: AnswerGolden.curlModified, kind: .prose,
                headingPath: [], language: nil, text: "body \(index)", score: 0.02
            )
        }
        let results = AnswerGolden.results(query: "q", chunks: many)
        #expect(results.promptChunks.count == AnswerSelection.maxChunks)
        let message = AnswerPrompt.userMessage(query: "q", chunks: results.promptChunks)
        #expect(message.contains("[\(AnswerSelection.maxChunks)] "))
        #expect(!message.contains("[\(AnswerSelection.maxChunks + 1)] "))
    }

    @Test("a runaway chunk is clipped rather than sent whole")
    func clipping() {
        let long = String(repeating: "x", count: AnswerPrompt.maxChunkCharacters * 2)
        #expect(AnswerPrompt.clip(long).count <= AnswerPrompt.maxChunkCharacters + 2)
        #expect(AnswerPrompt.clip("short") == "short")
    }
}

/// M3-05 — `answer_selection`, read back.
@Suite("answer_selection decoding")
struct AnswerSelectionTests {

    @Test("a well-formed call round-trips")
    func happyPath() throws {
        let decoded = try AnswerSelection.decode(
            input: .object([
                "best_chunk_id": 2,
                "snippet": "  curl -sS x  ",
                "confidence": "high",
                "ranked_chunk_ids": .array([2, 1, 4]),
            ]),
            chunkCount: 4
        )
        #expect(decoded.bestChunk == 2)
        #expect(decoded.snippet == "curl -sS x")
        #expect(decoded.confidence == .high)
        #expect(decoded.rankedChunks == [2, 1, 4])
    }

    @Test("a chunk number outside the list is dropped, not trusted")
    func hallucinatedIndex() throws {
        let decoded = try AnswerSelection.decode(
            input: .object([
                "best_chunk_id": 9,
                "snippet": .null,
                "confidence": "high",
                "ranked_chunk_ids": .array([9, 0, -3, 2, 2]),
            ]),
            chunkCount: 3
        )
        #expect(decoded.bestChunk == nil)
        #expect(decoded.rankedChunks == [2], "out of range and duplicates both go")
    }

    @Test("null is a real answer")
    func nullAnswer() throws {
        let decoded = try AnswerSelection.decode(
            input: .object([
                "best_chunk_id": .null, "snippet": .null,
                "confidence": "low", "ranked_chunk_ids": .array([]),
            ]),
            chunkCount: 4
        )
        #expect(decoded.bestChunk == nil)
        #expect(decoded.snippet == nil)
        #expect(decoded.rankedChunks.isEmpty)
    }

    @Test("a refusal or a truncation is never read as an answer")
    func unusableStopReasons() {
        for reason in [AIStopReason.refusal, .maxTokens] {
            let response = AIResponse(
                id: "m", model: AIModel.defaultSearch.id,
                content: [.toolUse(id: "t", name: AnswerSelection.toolName, input: .object([:]))],
                stopReason: reason, usage: AIUsage()
            )
            #expect(throws: AnswerSelection.DecodingFailure.unusableStopReason(reason)) {
                try AnswerSelection.decode(response: response, chunkCount: 3)
            }
        }
    }

    @Test("prose instead of a tool call is a failure, not an empty answer")
    func noToolCall() {
        let response = AIResponse(
            id: "m", model: AIModel.defaultSearch.id,
            content: [.text("It is the curl one.")], stopReason: .endTurn, usage: AIUsage()
        )
        #expect(throws: AnswerSelection.DecodingFailure.noToolCall) {
            try AnswerSelection.decode(response: response, chunkCount: 3)
        }
    }
}

/// M3-05 — the offline arm (FR-5.5).
@Suite("Local answer heuristic")
struct AnswerHeuristicTests {
    let heuristic = AnswerHeuristic()

    @Test("a clearly winning code chunk becomes the card")
    func codeChunkWins() throws {
        let chunks = [AnswerGolden.curlCode, AnswerGolden.authProse]
        let card = try #require(
            heuristic.card(query: "curl command to fetch documents", chunks: chunks)
        )
        #expect(card.isCode)
        #expect(card.language == "bash")
        #expect(card.snippetText == AnswerGolden.curlCommand, "the fence body only")
        #expect(!card.snippetText.contains("```"))
        #expect(!card.snippetText.contains("curl to fetch docs from staging"), "no context line")
        #expect(card.chunkRange == AnswerGolden.curlCode.range)
        #expect(card.sourceLabel == "Commands / curl")
    }

    @Test("a code chunk that barely wins is not a card")
    func narrowMarginIsNoCard() {
        // Two near-identical scores and a query with nothing in common.
        let close = AnswerGolden.chunk(
            id: 999, noteID: AnswerGolden.dockerID, title: "Docker cheats", path: "Docker cheats.md",
            modified: AnswerGolden.dockerModified, kind: .code, headingPath: [], language: "bash",
            text: "```bash\ndocker compose up\n```", score: 0.0311
        )
        let chunks = [AnswerGolden.curlCode, close]
        #expect(heuristic.margin(of: chunks) < heuristic.scoreMargin)
        #expect(heuristic.card(query: "wibble frobnicate", chunks: chunks) == nil)
    }

    @Test("a prose chunk carrying most of the query's words is a card")
    func wordCoverageWins() throws {
        let chunks = [AnswerGolden.authProse, AnswerGolden.dockerCode]
        #expect(heuristic.coverage(of: "bearer token rotates", in: AnswerGolden.authText) >= 1)
        let card = try #require(heuristic.card(query: "bearer token rotates", chunks: chunks))
        #expect(!card.isCode)
        #expect(card.noteID == AnswerGolden.authID)
    }

    @Test("a query about something else gets no card at all")
    func noCardWhenNothingFits() {
        let chunks = [AnswerGolden.authProse, AnswerGolden.dockerCode]
        #expect(heuristic.card(query: "how do I renew my passport", chunks: chunks) == nil)
    }

    @Test("an empty result set is not a card")
    func emptyResults() {
        #expect(heuristic.card(query: "anything", chunks: []) == nil)
    }

    @Test("a lone chunk has an unbeatable margin")
    func loneChunk() {
        #expect(heuristic.margin(of: [AnswerGolden.curlCode]) == 1)
        #expect(heuristic.margin(of: []) == 0)
    }

    @Test("snippets are capped at a readable number of lines")
    func snippetCap() {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let limited = AnswerSnippet.limit(long, lines: 5)
        #expect(limited.components(separatedBy: "\n").count == 6)
        #expect(limited.hasSuffix("…"))
    }

    @Test("fenced bodies come out without their fences, tildes included")
    func fenceParsing() {
        #expect(AnswerSnippet.fencedBody(in: "intro\n```sh\na\nb\n```\ntail") == "a\nb")
        #expect(AnswerSnippet.fencedBody(in: "intro\n~~~\na\n~~~") == "a")
        #expect(AnswerSnippet.fencedBody(in: "no fence here") == nil)
        #expect(AnswerSnippet.fencedBody(in: "```\n```") == nil, "an empty fence is not a snippet")
    }

    @Test("verbatim comparison ignores indentation but not content")
    func verbatimCheck() {
        #expect(AnswerSnippet.isVerbatim("curl -sS x", in: "```sh\n  curl -sS x\n```"))
        #expect(AnswerSnippet.isVerbatim("a\nb", in: "x\n  a\n  b\ny"))
        #expect(!AnswerSnippet.isVerbatim("curl -sS y", in: "```sh\ncurl -sS x\n```"))
        #expect(!AnswerSnippet.isVerbatim("", in: "anything"))
    }
}

/// M3-05 — the goldens, replayed end to end.
@Suite("Answer goldens (M3-05)")
struct AnswerGoldenTests {
    static let store = AITestPaths.recordingStore

    @Test(
        "regenerate the answer goldens",
        .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_WRITE_AI_FIXTURES"] == "1")
    )
    func regenerate() throws {
        for scenario in AnswerGolden.scenarios {
            let request = try AnswerGolden.request(for: scenario)
            let url = try Self.store.save(AIRecording(
                purpose: .search,
                key: request.fixtureKey,
                model: request.model.id,
                recordedAt: nil,
                note: "hand-authored (M3-05) — \(scenario.name): \(scenario.note)",
                request: request,
                requestBody: ClaudeWire.body(for: request),
                responseBody: scenario.response
            ))
            print("wrote \(scenario.name) → \(url.lastPathComponent)")
        }
    }

    @Test("every answer scenario has a committed fixture")
    func fixturesExist() throws {
        for scenario in AnswerGolden.scenarios {
            let request = try AnswerGolden.request(for: scenario)
            let recording = try Self.store.load(for: request)
            #expect(recording != nil, "\(scenario.name): no fixture for key \(request.fixtureKey)")
        }
    }

    @Test("curl command to fetch documents → the code card of Figure 2b")
    func curlCard() async throws {
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: Self.store))
        let scenario = AnswerGolden.scenario("curl-code-card")
        let answer = await extractor.extract(query: scenario.query, results: scenario.results)

        #expect(answer.source == .model)
        #expect(answer.confidence == .high)
        #expect(answer.promptVersion == .answer)
        #expect(answer.model == .haiku45)
        let card = try #require(answer.card)
        #expect(card.snippetText == AnswerGolden.curlCommand)
        #expect(card.isCode)
        #expect(card.language == "bash")
        #expect(card.title == "curl")
        #expect(card.chunkRange == AnswerGolden.curlCode.range, "clicking the card scrolls here (FR-5.2)")
        // The card's own note never repeats underneath it.
        #expect(!answer.rankedNotes.contains { $0.id == AnswerGolden.curlID })
        #expect(answer.rankedNotes.map(\.title) == ["Docker cheats", "Auth API debug"],
                "the model's ranking, not retrieval's")
    }

    @Test("a temporal query keeps its filter and comes back as a note list")
    func temporalCard() async throws {
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: Self.store))
        let scenario = AnswerGolden.scenario("temporal-auth")
        #expect(scenario.results.dateRange != nil, "FR-5.3: retrieval filtered by time")
        #expect(scenario.results.strippedQuery == "the thing I edited about auth")

        let answer = await extractor.extract(query: scenario.query, results: scenario.results)
        #expect(answer.source == .model)
        let card = try #require(answer.card)
        #expect(!card.isCode, "prose answers are not code blocks")
        #expect(card.noteID == AnswerGolden.authID)
        #expect(card.snippetText.hasPrefix("Auth API debug"))
        #expect(answer.rankedNotes.isEmpty, "both chunks are the same note, and it is the card")
    }

    @Test("nothing fits → no card, and the list still stands")
    func noAnswer() async throws {
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: Self.store))
        let scenario = AnswerGolden.scenario("no-answer")
        let answer = await extractor.extract(query: scenario.query, results: scenario.results)

        #expect(answer.card == nil)
        #expect(answer.source == .none)
        #expect(answer.confidence == .low)
        #expect(answer.unavailable == nil, "a null answer is not an outage")
        #expect(answer.rankedNotes.count == 2, "retrieval's order survives an empty ranking")
    }

    @Test("a fence is trimmed to the line that was asked about")
    func trimmedSnippet() async throws {
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: Self.store))
        let scenario = AnswerGolden.scenario("trimmed-snippet")
        let answer = await extractor.extract(query: scenario.query, results: scenario.results)

        let card = try #require(answer.card)
        #expect(card.snippetText == AnswerGolden.exportLine)
        #expect(!card.snippetText.contains("op signin"))
    }

    @Test("an invented command never reaches the card")
    func inventedSnippet() async throws {
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: Self.store))
        let scenario = AnswerGolden.scenario("invented-snippet")
        let answer = await extractor.extract(query: scenario.query, results: scenario.results)

        let card = try #require(answer.card)
        #expect(card.snippetText == AnswerGolden.curlCommand, "the chunk's own command, not the model's")
        #expect(!card.snippetText.contains("--fail"))
        #expect(answer.source == .model)
    }

    @Test("no committed answer fixture carries excluded text (FR-4.5)")
    func noExcludedLeak() throws {
        let recordings = try Self.store.all().filter { $0.purpose == .search }
        #expect(!recordings.isEmpty)
        for recording in recordings {
            let body = try recording.requestBody.canonicalData()
            let text = String(decoding: body, as: UTF8.self)
            #expect(!text.contains("88888"), "\(recording.key) leaked excluded text")
            #expect(!text.contains("Private/"), "\(recording.key) named an excluded folder")
        }
    }
}

/// M3-05 — what happens when the provider does not answer (FR-5.5, FR-6.4,
/// NFR-1).
@Suite("Answer fallbacks")
struct AnswerFallbackTests {

    static let scenario = AnswerGolden.scenario("curl-code-card")

    @Test("a call that overruns the budget falls back locally and still returns")
    func timeout() async throws {
        let provider = MockProvider { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .text("never", model: .defaultSearch)
        }
        let extractor = AnswerGolden.extractor(provider: provider, timeout: 0.2)
        let started = Date()
        let answer = await extractor.extract(query: Self.scenario.query, results: Self.scenario.results)
        let elapsed = Date().timeIntervalSince(started)

        // The hung provider takes ≥ 5 s; anything well under that proves the race
        // decided. 4 s (not 2) tolerates a saturated parallel test run (M4-08).
        #expect(elapsed < 4, "the 5 s call must not decide how long the search takes")
        #expect(answer.source == .localHeuristic)
        #expect(answer.unavailable == .timedOut)
        let card = try #require(answer.card)
        #expect(card.snippetText == AnswerGolden.curlCommand, "the offline card is still the right one")
    }

    @Test("offline falls back locally and says so", arguments: [
        (AIError.network(code: -1009, description: "offline"), SemanticUnavailable.network),
        (AIError.notConfigured, .notConfigured),
        (AIError.invalidKey(), .notConfigured),
        (AIError.rateLimited(retryAfter: 30), .rateLimited),
        (AIError.serverOverloaded(status: 529), .providerError),
    ])
    func providerFailures(error: AIError, expected: SemanticUnavailable) async throws {
        let extractor = AnswerGolden.extractor(provider: MockProvider { _ in throw error })
        let answer = await extractor.extract(query: Self.scenario.query, results: Self.scenario.results)

        #expect(answer.source == .localHeuristic)
        #expect(answer.unavailable == expected)
        #expect(answer.card?.snippetText == AnswerGolden.curlCommand)
        #expect(answer.rankedNotes.count == 3, "the local list is untouched")
    }

    @Test("a missing recording degrades instead of failing the search")
    func missingRecording() async throws {
        let empty = AIRecordingStore(directory: URL(fileURLWithPath: "/nonexistent-filaway-fixtures"))
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: empty))
        let answer = await extractor.extract(query: Self.scenario.query, results: Self.scenario.results)
        #expect(answer.source == .localHeuristic)
        #expect(answer.unavailable == .noProvider)
    }

    @Test("a refusal is a degradation, not a card")
    func refusal() async throws {
        let provider = MockProvider { _ in
            AIResponse(
                id: "m", model: AIModel.defaultSearch.id, content: [],
                stopReason: .refusal,
                stopDetails: AIStopDetails(type: "refusal", category: "cyber"),
                usage: AIUsage()
            )
        }
        let extractor = AnswerGolden.extractor(provider: provider)
        let answer = await extractor.extract(query: Self.scenario.query, results: Self.scenario.results)
        #expect(answer.unavailable == .providerError)
        #expect(answer.source == .localHeuristic)
    }

    @Test("no chunks means no request at all")
    func noChunks() async throws {
        let provider = MockProvider { _ in
            Issue.record("the provider must not be called with nothing to rank")
            return .text("", model: .defaultSearch)
        }
        let extractor = AnswerGolden.extractor(provider: provider)
        let answer = await extractor.extract(query: "anything", results: .empty(query: "anything"))
        #expect(answer.source == .none)
        #expect(answer.card == nil)
    }

    @Test("usage is recorded against the search bucket (FR-6.6)")
    func ledgerRecords() async throws {
        let ledger = try AIUsageLedger(inMemory: true)
        let extractor = AnswerGolden.extractor(provider: ReplayProvider(store: AITestPaths.recordingStore), ledger: ledger)
        _ = await extractor.extract(query: Self.scenario.query, results: Self.scenario.results)

        let records = try await ledger.allRecords()
        #expect(records.count == 1)
        #expect(records.first?.purpose == .search)
        #expect(records.first?.model == AIModel.defaultSearch.id)
        #expect(records.first?.provider == "replay", "a replayed call is never billed")
    }

    @Test("a cancelled search returns nothing rather than a stale card")
    func cancellation() async throws {
        let extractor = AnswerGolden.extractor(provider: MockProvider { _ in throw AIError.cancelled })
        let answer = await extractor.extract(query: Self.scenario.query, results: Self.scenario.results)
        #expect(answer.source == .none)
        #expect(answer.unavailable == nil)
    }
}

/// M3-05 — the façade the ⌘K panel actually calls.
@Suite("SemanticSearchService")
struct SemanticSearchServiceTests {

    /// A hybrid search over a real (tiny) index, so the façade is exercised
    /// against the same object the app builds.
    struct Fixture {
        let temp: TempLibrary
        let metadata: MetadataStore
        let embedder: HashedEmbedder
        let vectors: VectorStore
        let indexer: Indexer
        let hybrid: HybridSearch

        init(excluding exclusions: ExclusionFilter = .none) throws {
            temp = try TempLibrary()
            metadata = try temp.metadataStore()
            embedder = HashedEmbedder(dimension: 256)
            vectors = VectorStore(
                reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
            )
            indexer = Indexer(
                metadata: metadata, embedder: embedder, vectorStore: vectors,
                configuration: .init(debounce: .zero),
                isExcluded: { exclusions.isExcluded(path: $0) }
            )
            hybrid = HybridSearch(metadata: metadata, embedder: embedder, vectorStore: vectors)
        }

        func add(_ path: String, _ body: String) async throws {
            try temp.writeExternal(body, to: path)
        }

        func index() async throws {
            let snapshot = try await temp.store.scan()
            try await metadata.upsert(snapshot.notes)
            _ = try await indexer.catchUp()
            try await vectors.reload()
            await hybrid.invalidate()
        }
    }

    static let curlNote = """
    # curl

    curl to fetch docs from staging:

    ```bash
    \(AnswerGolden.curlCommand)
    ```

    remember: the token expires hourly
    """

    static let salaryNote = """
    # Salary

    compensation figure is 88888 and the curl command to fetch documents is here too
    """

    @Test("an excluded folder never reaches promptChunks (FR-4.5)")
    func exclusionsNeverReachThePrompt() async throws {
        let fixture = try Fixture(excluding: ExclusionFilter(excludedFolders: ["Private"]))
        try await fixture.add("Commands/curl.md", Self.curlNote)
        try await fixture.add("Private/Salary.md", Self.salaryNote)
        try await fixture.index()

        let results = await fixture.hybrid.semanticCandidates("curl command to fetch documents")
        #expect(!results.chunks.isEmpty)
        #expect(!results.promptChunks.contains { $0.relativePath.hasPrefix("Private/") })
        #expect(!results.promptChunks.contains { $0.text.contains("88888") })
        #expect(results.notes.allSatisfy { $0.relativePath == "Commands/curl.md" })

        // …and therefore nothing excluded can be in the request either.
        let request = try AnswerExtractor.request(
            query: "curl command to fetch documents",
            chunks: results.promptChunks,
            configuration: AnswerGolden.configuration()
        )
        let body = String(decoding: try ClaudeWire.body(for: request).canonicalData(), as: UTF8.self)
        #expect(!body.contains("88888"))
        #expect(!body.contains("Private/"))
    }

    @Test("semantic search off → the local card, and a reason to show the user")
    func disabled() async throws {
        let fixture = try Fixture()
        try await fixture.add("Commands/curl.md", Self.curlNote)
        try await fixture.index()

        let provider = MockProvider { _ in
            Issue.record("the provider must not be reached when semantic search is off")
            return .text("", model: .defaultSearch)
        }
        let service = SemanticSearchService(
            hybrid: fixture.hybrid,
            extractor: AnswerGolden.extractor(provider: provider),
            gate: .init(isEnabled: { false })
        )
        let outcome = await service.search("curl command to fetch documents")
        #expect(outcome.availability == .offline(.semanticSearchDisabled))
        #expect(outcome.answer.source == .localHeuristic)
        #expect(outcome.card?.noteID == outcome.results.notes.first?.id)
        #expect(outcome.card?.snippetText.contains("curl") == true)
        #expect(outcome.availability.notice == "Semantic answers are off — showing local matches")
    }

    @Test("no key → the Settings notice, and retrieval still answers")
    func notConfigured() async throws {
        let fixture = try Fixture()
        try await fixture.add("Commands/curl.md", Self.curlNote)
        try await fixture.index()

        let service = SemanticSearchService(
            hybrid: fixture.hybrid,
            extractor: AnswerGolden.extractor(provider: MockProvider { _ in throw AIError.notConfigured }),
            gate: .init(isProviderReady: { false })
        )
        let outcome = await service.search("curl command to fetch documents")
        #expect(outcome.availability == .offline(.notConfigured))
        #expect(outcome.availability.notice == "Connect your AI in Settings to get answers")
        #expect(outcome.card != nil)
    }

    @Test("with no extractor at all the service is still a search")
    func noExtractor() async throws {
        let fixture = try Fixture()
        try await fixture.add("Commands/curl.md", Self.curlNote)
        try await fixture.index()

        let service = SemanticSearchService(hybrid: fixture.hybrid, extractor: nil)
        let outcome = await service.search("curl command to fetch documents")
        #expect(outcome.availability == .offline(.noProvider))
        #expect(outcome.answer.source == .localHeuristic)
        #expect(!outcome.isEmpty)
    }

    @Test("an empty query is not a search")
    func emptyQuery() async throws {
        let fixture = try Fixture()
        let service = SemanticSearchService(hybrid: fixture.hybrid, extractor: nil)
        let outcome = await service.search("   ")
        #expect(outcome.isEmpty)
        #expect(outcome.results.chunks.isEmpty)
    }

    @Test("the two halves can be run separately, so the list paints first")
    func twoPhase() async throws {
        let fixture = try Fixture()
        try await fixture.add("Commands/curl.md", Self.curlNote)
        try await fixture.index()

        let service = SemanticSearchService(hybrid: fixture.hybrid, extractor: nil)
        let candidates = await service.candidates("curl command to fetch documents")
        #expect(!candidates.notes.isEmpty, "the panel has something to draw immediately")
        let (answer, availability) = await service.answer(
            for: "curl command to fetch documents", results: candidates
        )
        #expect(availability == .offline(.noProvider))
        #expect(answer.card != nil)
    }
}
