import Foundation
import Testing

@testable import FilawayCore

/// The golden scenarios, run against a **local model** (P2-04).
///
/// Two suites live here and they are deliberately different in kind:
///
/// * **`Ollama goldens (replay)`** runs in every `swift test`. It replays the
///   committed `provider: "ollama"` fixtures and asserts the *pipeline*: the
///   daemon's JSON decodes, the plan decodes, and the organizer reaches a named
///   outcome — proposed, nothing-to-do, or rejected for a reason the validator
///   can name. Plan **quality** is not gated here; an 8B model is not Sonnet
///   and pinning its taste would make every model bump a red build. The numbers
///   are reported in `docs/verification/P2-ollama.md` instead. The one
///   exception is the smoke corpus (`OrganizeWiringTests`), which *must*
///   validate, because the `organize-ollama` smoke phase needs a card.
/// * **`Ollama goldens (live)`** is off unless `FILAWAY_TEST_OLLAMA=1`. It is
///   the measuring instrument: it calls the real daemon once per scenario and
///   prints a content-free table — outcome, action kinds, validator issue
///   kinds, latency, tokens — and, under `FILAWAY_AI_MODE=record`, writes the
///   fixtures the replay suite reads.
///
/// ```bash
/// # measure only
/// FILAWAY_TEST_OLLAMA=1 swift test --filter "Ollama goldens (live)"
/// # measure and re-record, into a scratch directory first (ADR-067)
/// FILAWAY_TEST_OLLAMA=1 FILAWAY_AI_MODE=record \
/// FILAWAY_AI_FIXTURES=/tmp/ollama-fixtures swift test --filter "Ollama goldens (live)"
/// ```
///
/// The fixture key hashes the model id among other things, so an Ollama
/// recording can never land on a Claude fixture — `llama3.1:8b` and
/// `claude-sonnet-5` are different keys for the same scenario (ADR-067).
enum OllamaGolden {
    static let kind = AIProviderKind.ollama
    static var model: AIModel { kind.defaultOrganizeModel }

    /// Where fixtures are read from and written to: `FILAWAY_AI_FIXTURES` when
    /// set, else the committed directory.
    static var store: AIRecordingStore {
        AIRecordingStore.fromEnvironment() ?? AITestPaths.recordingStore
    }

    static var isRecording: Bool { AIMode.current() == .record }

    /// A live provider with retries off — a retry would hide a slow first token
    /// behind a second cold load, and this suite is here to measure.
    static func liveProvider() -> OllamaProvider {
        OllamaProvider(retryPolicy: .none)
    }

    // MARK: - The measurement row

    /// One scenario's outcome, with **no note text in it** (NFR-4): action
    /// kinds, issue kinds, numbers.
    struct Row {
        var name: String
        var outcome: String
        var actions: [String]
        var errors: [String]
        var warnings: [String]
        var seconds: Double
        var inputTokens: Int
        var outputTokens: Int
        /// `true` when the pipeline produced something the user could accept,
        /// or correctly decided there was nothing to do.
        var isUsable: Bool

        var markdown: String {
            func list(_ values: [String]) -> String {
                values.isEmpty ? "—" : values.joined(separator: ", ")
            }
            return "| \(name) | \(isUsable ? "yes" : "no") | \(outcome) | \(list(actions)) "
                + "| \(list(errors)) | \(list(warnings)) | \(String(format: "%.1f", seconds)) "
                + "| \(inputTokens) | \(outputTokens) |"
        }

        static let header = """
        | scenario | usable | outcome | actions | validator errors | warnings | s | in | out |
        |---|---|---|---|---|---|---|---|---|
        """
    }

    static func issueKinds(_ issues: [PlanIssue]) -> [String] {
        var seen: [String] = []
        for issue in issues where !seen.contains(issue.kind.rawValue) { seen.append(issue.kind.rawValue) }
        return seen
    }

    static func actionKinds(_ plan: OrganizationPlan) -> [String] {
        plan.actions.map(\.kind.rawValue)
    }

    /// `FILAWAY_OLLAMA_VERBOSE=1` prints ``PlanValidation/summary`` under each
    /// row. Issue details name paths, titles and ids — never note text (that is
    /// the ``PlanIssue`` contract) — but they are noise in the table, so they
    /// are opt-in.
    static var isVerbose: Bool { ProcessInfo.processInfo.environment["FILAWAY_OLLAMA_VERBOSE"] == "1" }

    static func note(_ text: @autoclosure () -> String) {
        guard isVerbose else { return }
        print("    · \(text())")
    }
}

// MARK: - A provider that times and remembers one exchange

/// Wraps a provider, keeps the last request/response and how long it took.
///
/// It reports the *upstream's* identifier, so a ``RecordingProvider`` above it
/// still tags the fixture with the real wire format (ADR-067).
final class TimingProvider: AIProvider, @unchecked Sendable {
    struct Exchange {
        var request: AIRequest
        var response: AIResponse
        var seconds: Double
    }

    let identifier: String
    private let upstream: any AIProvider
    private let lock = NSLock()
    private var storage: [Exchange] = []

    init(upstream: any AIProvider) {
        self.upstream = upstream
        identifier = upstream.identifier
    }

    var exchanges: [Exchange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: Exchange? { exchanges.last }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let started = Date()
        let response = try await upstream.complete(request)
        record(Exchange(request: request, response: response, seconds: Date().timeIntervalSince(started)))
        return response
    }

    /// Not `async`: `NSLock` is unavailable from an async context, and this is
    /// the whole reason the append is its own method.
    private func record(_ exchange: Exchange) {
        lock.lock()
        storage.append(exchange)
        lock.unlock()
    }

    func validateKey() async throws -> [AIModelInfo] {
        try await upstream.validateKey()
    }
}

// MARK: - Live

@Suite(
    "Ollama goldens (live)",
    .enabled(if: ProcessInfo.processInfo.environment["FILAWAY_TEST_OLLAMA"] == "1"),
    .serialized
)
struct OllamaLiveGoldenTests {

    @Test("every organize golden, end to end against the daemon")
    func organizeScenarios() async throws {
        var rows: [OllamaGolden.Row] = []
        for scenario in OrganizeGolden.scenarios {
            rows.append(try await run(scenario))
        }

        print("\n### organize goldens — \(OllamaGolden.model.id)\n")
        print(OllamaGolden.Row.header)
        for row in rows { print(row.markdown) }
        let usable = rows.filter(\.isUsable).count
        print("\nusable: \(usable)/\(rows.count)\n")

        // The suite is a measurement, not a quality gate — but a run where
        // *nothing* came back is a broken daemon, not a weak model.
        #expect(rows.allSatisfy { $0.inputTokens > 0 }, "the daemon answered nothing at all")
    }

    /// Runs one scenario through the whole organizer against the live daemon.
    private func run(_ scenario: OrganizeGolden.Scenario) async throws -> OllamaGolden.Row {
        let timing = TimingProvider(upstream: OllamaGolden.liveProvider())
        let provider: any AIProvider = OllamaGolden.isRecording
            ? RecordingProvider(upstream: timing, store: OllamaGolden.store)
            : timing
        let run = await OrganizeGolden.makeRun(scenario, provider: provider, kind: OllamaGolden.kind)
        await run.organizer.sessionEnded(run.session)
        await run.organizer.drain()

        let exchange = timing.last
        var row = OllamaGolden.Row(
            name: scenario.name,
            outcome: run.recorder.kinds.joined(separator: "+"),
            actions: [],
            errors: [],
            warnings: [],
            seconds: exchange?.seconds ?? 0,
            inputTokens: exchange?.response.usage.inputTokens ?? 0,
            outputTokens: exchange?.response.usage.outputTokens ?? 0,
            isUsable: false
        )

        if let proposal = run.recorder.proposals.first {
            row.actions = OllamaGolden.actionKinds(proposal.plan)
            row.errors = OllamaGolden.issueKinds(proposal.droppedActions)
            row.warnings = OllamaGolden.issueKinds(proposal.validation.warnings)
            row.isUsable = true
        } else if run.recorder.kinds.contains("skipped(nothingToDo)") {
            row.isUsable = true
        }
        for failure in run.recorder.failures {
            switch failure {
            case let .invalidPlan(validation):
                row.errors = OllamaGolden.issueKinds(validation.errors)
                row.warnings = OllamaGolden.issueKinds(validation.warnings)
                OllamaGolden.note("\(scenario.name): \(validation.summary)")
            case let .decoding(reason):
                row.errors = ["decoding"]
                row.outcome += "(\(reason.prefix(40)))"
            default:
                row.errors = ["provider"]
            }
        }
        return row
    }

    @Test("every answer golden, end to end against the daemon")
    func answerScenarios() async throws {
        var rows: [String] = []
        var usable = 0
        for scenario in AnswerGolden.scenarios {
            let configuration = AnswerGolden.configuration(
                model: OllamaGolden.kind.defaultSearchModel, providerKind: OllamaGolden.kind
            )
            let request = try AnswerExtractor.request(
                query: scenario.query, chunks: scenario.results.promptChunks, configuration: configuration
            )
            let timing = TimingProvider(upstream: OllamaGolden.liveProvider())
            let provider: any AIProvider = OllamaGolden.isRecording
                ? RecordingProvider(upstream: timing, store: OllamaGolden.store)
                : timing

            var outcome = "ok"
            var decoded = false
            do {
                let response = try await provider.complete(request)
                let selection = try AnswerSelection.decode(
                    response: response, chunkCount: scenario.results.promptChunks.count
                )
                decoded = true
                usable += 1
                outcome = selection.bestChunk.map { "best=\($0)" } ?? "no card"
            } catch {
                outcome = String(describing: error).prefix(48).replacingOccurrences(of: "|", with: "/")
            }
            let exchange = timing.last
            rows.append("""
            | \(scenario.name) | \(decoded ? "yes" : "no") | \(outcome) \
            | \(String(format: "%.1f", exchange?.seconds ?? 0)) \
            | \(exchange?.response.usage.inputTokens ?? 0) | \(exchange?.response.usage.outputTokens ?? 0) |
            """)
        }
        print("\n### answer goldens — \(OllamaGolden.kind.defaultSearchModel.id)\n")
        print("| scenario | decoded | outcome | s | in | out |")
        print("|---|---|---|---|---|---|")
        for row in rows { print(row) }
        print("\ndecoded: \(usable)/\(AnswerGolden.scenarios.count)\n")
    }

    /// The corpus the `organize-ollama` smoke phase seeds, on the production
    /// objects. This one *is* a quality gate: the phase needs a card.
    @Test("the smoke corpus, end to end against the daemon", arguments: OrganizeMode.allCases)
    func smokeCorpus(mode: OrganizeMode) async throws {
        let timing = TimingProvider(upstream: OllamaGolden.liveProvider())
        let provider: any AIProvider = OllamaGolden.isRecording
            ? RecordingProvider(upstream: timing, store: OllamaGolden.store)
            : timing
        let wiring = try await AppWiringFixture.wire(provider: provider, mode: mode, kind: OllamaGolden.kind)
        await wiring.organizer.sessionEnded(wiring.session())
        await wiring.organizer.drain()

        let exchange = timing.last
        var row = OllamaGolden.Row(
            name: "smoke-corpus (\(mode.rawValue))",
            outcome: wiring.recorder.kinds.joined(separator: "+"),
            actions: [],
            errors: [],
            warnings: [],
            seconds: exchange?.seconds ?? 0,
            inputTokens: exchange?.response.usage.inputTokens ?? 0,
            outputTokens: exchange?.response.usage.outputTokens ?? 0,
            isUsable: false
        )
        if let proposal = wiring.recorder.proposals.first {
            row.actions = OllamaGolden.actionKinds(proposal.plan)
            row.warnings = OllamaGolden.issueKinds(proposal.validation.warnings)
            row.isUsable = true
        }
        if let applied = wiring.recorder.appliedPlans.first {
            row.actions = ["applied:\(applied.summary.isEmpty ? "none" : "yes")"]
            row.isUsable = true
        }
        for failure in wiring.recorder.failures {
            if case let .invalidPlan(validation) = failure {
                row.errors = OllamaGolden.issueKinds(validation.errors)
                row.warnings = OllamaGolden.issueKinds(validation.warnings)
                OllamaGolden.note("smoke-corpus: \(validation.summary)")
            } else {
                row.errors = [String(describing: failure).prefix(40).description]
            }
        }
        print("\n### smoke corpus (organize-ollama) — \(OllamaGolden.model.id)\n")
        print(OllamaGolden.Row.header)
        print(row.markdown)
        print("")
    }
}
