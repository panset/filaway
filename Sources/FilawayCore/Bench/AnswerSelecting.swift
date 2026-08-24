import Foundation

/// The M3-05 answer step, as the benchmark sees it.
///
/// `HybridSearch` hands the top eight chunks to an extractor, which picks the
/// one that actually answers the question — or says there isn't one. That step
/// is a Claude call in the app; here it is a protocol, so the benchmark can
/// measure retrieval alone (``LocalHeuristicSelector``), a recorded Claude
/// (``ReplaySelector``) or, later, the real `AnswerExtractor`, without the
/// bench module depending on any of them.
///
/// Returning `nil` means "none of these answers it", which is what
/// ``RetrievalReport/negativeRejectionRate`` measures.
public protocol AnswerSelecting: Sendable {
    /// - Parameter chunks: `SemanticResults.promptChunks` — top 8, best first.
    /// - Returns: the chosen chunk's id, or `nil` to abstain.
    func selectChunk(query: String, chunks: [RankedChunk]) async -> Int64?

    /// Shown in the report's header.
    var label: String { get }
}

/// The offline answer card FR-5.5 promises when there is no Claude: take the
/// best chunk, but prefer a code block that is nearly as good, and abstain when
/// nothing is similar enough to be worth showing.
///
/// Plan §3 M3-05 describes this as "top chunk is code + score margin"; this is
/// that rule, isolated so M3-07 can measure the floor the Claude step has to
/// beat.
public struct LocalHeuristicSelector: AnswerSelecting {
    /// A code chunk scoring within this fraction of the leader wins the card.
    /// FR-5.2's unit is the command, and a prose chunk two positions above it
    /// is usually the paragraph that introduces the very same fence.
    public var codeMargin: Double
    /// Below this cosine, nothing is shown. `nil` never abstains, which is the
    /// right setting for a BM25-only run (there is no cosine to test).
    public var minimumVectorScore: Float?

    public init(codeMargin: Double = 0.25, minimumVectorScore: Float? = nil) {
        self.codeMargin = codeMargin
        self.minimumVectorScore = minimumVectorScore
    }

    public var label: String { "local heuristic (top chunk, code preferred)" }

    public func selectChunk(query: String, chunks: [RankedChunk]) async -> Int64? {
        guard let best = chunks.first else { return nil }
        if let floor = minimumVectorScore {
            let bestCosine = chunks.compactMap(\.vectorScore).max() ?? 0
            guard bestCosine >= floor else { return nil }
        }
        guard best.kind != .code else { return best.id }

        // The winning *note* is the answer; within it, the fenced block is what
        // the card shows. A short note splits into one prose chunk (which is
        // what a paraphrase matches — it is written in outcome language) and
        // one code chunk (which carries the command but shares almost no
        // vocabulary with the question). M3-07 measured the gap: preferring a
        // globally high-scoring code chunk picks another note's command 58% of
        // the time; preferring the *same note's* code chunk does not.
        if let sibling = chunks.first(where: { $0.kind == .code && $0.noteID == best.noteID }) {
            return sibling.id
        }
        let cutoff = best.score * (1 - codeMargin)
        if let code = chunks.first(where: { $0.kind == .code && $0.score >= cutoff }) {
            return code.id
        }
        return best.id
    }
}

/// The **real** answer step, against a live provider (P2-04).
///
/// It builds exactly the request ``AnswerExtractor`` builds — same `answer.v1`,
/// same strict `answer_selection` tool, same budget — and reads the reply back
/// through ``AnswerSelection/decode(response:chunkCount:)``. So
/// `filaway-bench retrieval --answer ollama` measures the card the app would
/// actually show, not an approximation of it.
///
/// Two things it does *not* do, both on purpose:
///
/// * **No local fallback.** ``AnswerExtractor`` races the model against
///   ``AnswerHeuristic`` and shows whichever arrives; folding that in here
///   would measure the race, not the model. A failed or timed-out call
///   abstains and is counted in ``stats``.
/// * **No retries.** A retry hides a cold model load behind a warm one.
///
/// It is a class rather than a struct because it accumulates the per-query
/// latencies the report prints; ``AnswerSelecting`` is `Sendable`, hence the
/// lock.
public final class LiveAnswerSelector: AnswerSelecting, @unchecked Sendable {
    /// What the run cost, for the line the benchmark prints under the table.
    public struct Stats: Sendable {
        public var attempts = 0
        public var answered = 0
        public var abstained = 0
        public var failed = 0
        /// Calls that came back inside the app's own 5 s race (NFR-1) — the
        /// rest would have been overtaken by the offline card (FR-5.5).
        public var withinAppBudget = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var seconds: [Double] = []

        public var p50: Double { Self.percentile(seconds, 0.50) }
        public var p95: Double { Self.percentile(seconds, 0.95) }

        static func percentile(_ values: [Double], _ q: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * q).rounded())
            return sorted[index]
        }

        /// Two lines for the report and the verification document.
        public var line: String {
            String(
                format: """
                answers:  %d/%d answered, %d abstained, %d failed · p50 %.1fs p95 %.1fs · %d in / %d out tokens
                          %d of %d inside the app's 5 s race (NFR-1); the rest would show the offline card
                """,
                answered, attempts, abstained, failed, p50, p95, inputTokens, outputTokens,
                withinAppBudget, attempts
            )
        }
    }

    private let provider: any AIProvider
    private let configuration: AnswerExtractor.Configuration
    /// The *benchmark's* budget, not the app's. See ``init``.
    private let timeout: TimeInterval
    /// The app's race, kept only to count how many calls would have won it.
    private let appBudget: TimeInterval
    private let lock = NSLock()
    private var storage = Stats()

    public let label: String

    /// - Parameter timeout: how long one call may take **here**. It is
    ///   deliberately generous and unrelated to NFR-1: the app races the model
    ///   against the offline card at 5 s and shows whichever arrives, so a
    ///   benchmark that cut the call off at 5 s would measure a stopwatch
    ///   rather than a model. ``Stats/withinAppBudget`` is the NFR-1 number.
    public init(
        provider: any AIProvider,
        kind: AIProviderKind,
        model: AIModel? = nil,
        timeout: TimeInterval = 60,
        promptsDirectory: URL? = nil
    ) {
        let model = model ?? kind.defaultSearchModel
        self.provider = provider
        self.timeout = timeout
        configuration = AnswerExtractor.Configuration(
            model: model, providerKind: kind, promptsDirectory: promptsDirectory
        )
        appBudget = configuration.timeout
        label = "live \(kind.rawValue) · \(model.id)"
    }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func selectChunk(query: String, chunks: [RankedChunk]) async -> Int64? {
        let shown = Array(chunks.prefix(AnswerSelection.maxChunks))
        guard !shown.isEmpty,
              var request = try? AnswerExtractor.request(
                  query: query, chunks: shown, configuration: configuration
              )
        else { return nil }
        request.timeout = timeout

        let started = Date()
        do {
            let response = try await provider.complete(request)
            let decoded = try AnswerSelection.decode(response: response, chunkCount: shown.count)
            let elapsed = Date().timeIntervalSince(started)
            // `best_chunk_id` is the 1-based position in the prompt, never a
            // database rowid — the prompt is the only numbering the model sees.
            let inBudget = elapsed <= appBudget
            guard let best = decoded.bestChunk, best >= 1, best <= shown.count else {
                record {
                    $0.abstained += 1
                    $0.seconds.append(elapsed)
                    if inBudget { $0.withinAppBudget += 1 }
                    $0.add(response.usage)
                }
                return nil
            }
            record {
                $0.answered += 1
                $0.seconds.append(elapsed)
                if inBudget { $0.withinAppBudget += 1 }
                $0.add(response.usage)
            }
            return shown[best - 1].id
        } catch {
            record { $0.failed += 1; $0.seconds.append(Date().timeIntervalSince(started)) }
            return nil
        }
    }

    private func record(_ mutate: (inout Stats) -> Void) {
        lock.lock()
        storage.attempts += 1
        mutate(&storage)
        lock.unlock()
    }
}

private extension LiveAnswerSelector.Stats {
    mutating func add(_ usage: AIUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
    }
}

/// Replays a recorded answer step from `Tests/Fixtures/ai-recordings/answer/`.
///
/// The M3-05 agent owns that directory; until it exists this selector reports
/// itself unavailable and the benchmark falls back to the local heuristic, so
/// nothing here blocks on that task landing. The format it reads is
/// deliberately minimal and keyed on the **query text**, because a chunk id is
/// a database rowid and changes every time the corpus is rebuilt:
///
/// ```json
/// { "query": "the jq one-liner that pulled the ids",
///   "snippet": "jq -r '.data.items[]",
///   "answered": true }
/// ```
///
/// `answered: false` (or a missing snippet) replays an extractor that said
/// "none of these", which is what the negative queries want.
public struct ReplaySelector: AnswerSelecting {
    public struct Record: Codable, Sendable, Equatable {
        public var query: String
        public var snippet: String?
        public var answered: Bool?

        public init(query: String, snippet: String?, answered: Bool? = nil) {
            self.query = query
            self.snippet = snippet
            self.answered = answered
        }
    }

    private let records: [String: Record]
    /// Used for a query with no recording, so a partial fixture set still runs.
    private let fallback: LocalHeuristicSelector

    public var label: String { "replay (\(records.count) recorded answers)" }

    /// `Tests/Fixtures/ai-recordings/answer`.
    public static var defaultDirectory: URL {
        DevCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/ai-recordings/answer", isDirectory: true)
    }

    public static var isAvailable: Bool {
        (try? FileManager.default.contentsOfDirectory(
            at: defaultDirectory, includingPropertiesForKeys: nil
        ).contains { $0.pathExtension == "json" }) ?? false
    }

    /// Loads every `*.json` in `directory`; files that do not decode as a
    /// ``Record`` are skipped rather than failing the run.
    public init(directory: URL = ReplaySelector.defaultDirectory, fallback: LocalHeuristicSelector = .init()) {
        var loaded: [String: Record] = [:]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data)
            else { continue }
            loaded[Self.key(record.query)] = record
        }
        records = loaded
        self.fallback = fallback
    }

    public func selectChunk(query: String, chunks: [RankedChunk]) async -> Int64? {
        guard let record = records[Self.key(query)] else {
            return await fallback.selectChunk(query: query, chunks: chunks)
        }
        if record.answered == false { return nil }
        guard let snippet = record.snippet, !snippet.isEmpty else { return nil }
        let needle = RetrievalBenchmark.collapse(snippet)
        return chunks.first { RetrievalBenchmark.collapse($0.text).contains(needle) }?.id
    }

    private static func key(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
