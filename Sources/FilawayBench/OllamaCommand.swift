import ArgumentParser
import FilawayCore
import Foundation

/// `filaway-bench ollama probe` — is the local daemon usable, and how fast is
/// it on Filaway's *own* prompts (P2-04, FR-6.5, NFR-5)?
///
/// Everything it sends is a **committed recording's request**, replayed live:
/// the real rendered `organize.v1` with the real `organization_plan` schema as
/// `format`, and the real `answer.v1` with `answer_selection`. Nothing here is
/// a synthetic stand-in, so the numbers are the ones the app pays.
///
/// ```
/// make bench ARGS="ollama probe"
/// make bench ARGS="ollama probe --model llama3.2:3b"
/// ```
struct OllamaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ollama",
        abstract: "Probe the local Ollama daemon (P2-04).",
        subcommands: [Probe.self],
        defaultSubcommand: Probe.self
    )

    struct Probe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "probe",
            abstract: "Reachability, pulled models, cold vs warm latency, prompt size vs context length."
        )

        @Option(help: "Daemon base URL.")
        var url = OllamaConfiguration.defaultBaseURL.absoluteString

        @Option(help: "Model tag to time (default: the house local tag).")
        var model = AIModel.defaultOllama.id

        @Flag(help: "Skip the unload, and report warm numbers only.")
        var warmOnly = false

        @Option(help: "Fixture directory (default: Tests/Fixtures/ai-recordings).")
        var fixtures: String?

        mutating func run() async throws {
            let base = URL(string: url) ?? OllamaConfiguration.defaultBaseURL
            guard OllamaConfiguration.isValidBaseURL(base) else {
                throw ValidationError("--url must be https, or http to loopback (NFR-4)")
            }
            let configuration = OllamaConfiguration(baseURL: base, model: AIModel(model))
            let provider = OllamaProvider(configuration: configuration, retryPolicy: .none)

            print("# filaway-bench ollama probe")
            print("")
            print("daemon:   \(base.absoluteString)")

            // 1. Reachability and what has been pulled.
            let started = Date()
            let models: [AIModelInfo]
            do {
                models = try await provider.validateKey()
            } catch {
                print("status:   UNREACHABLE — \(error)")
                print("          start it with `ollama serve`, then `ollama pull \(model)`")
                throw ExitCode.failure
            }
            print(String(format: "tags:     %d model(s) in %.0f ms", models.count, Date().timeIntervalSince(started) * 1000))
            let catalogue = await Self.catalogue(base: base)
            for info in models {
                let detail = catalogue[info.id]
                print("          \(info.id)"
                    + (detail.map { " · \($0.parameters) · \($0.quantization) · ctx \($0.contextLength)" } ?? ""))
            }
            guard models.contains(where: { $0.id == model }) else {
                print("status:   MODEL NOT PULLED — run `ollama pull \(model)`")
                throw ExitCode.failure
            }
            let contextLength = catalogue[model]?.contextLength

            // 2. The two shapes, from the committed recordings.
            let store = AIRecordingStore(
                directory: fixtures.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? DevCorpus.repositoryRoot.appendingPathComponent(
                        "Tests/Fixtures/ai-recordings", isDirectory: true
                    )
            )
            let recordings = (try? store.all()) ?? []
            print("")
            print("| shape | load | s | prompt tokens | output tokens | stop |")
            print("|---|---|---|---|---|---|")

            var promptTokens: [AIPurpose: Int] = [:]
            for purpose in [AIPurpose.search, .organize] {
                guard var request = Self.request(for: purpose, in: recordings) else {
                    print("| \(purpose.rawValue) | — | — | no committed local recording | — | — |")
                    continue
                }
                request.model = AIModel(model)
                request.timeout = max(AIProviderKind.ollama.timeout(for: purpose), 180)

                if !warmOnly {
                    await Self.unload(provider: provider, model: model, base: base)
                    if let row = await Self.time(request, provider: provider, load: "cold") {
                        print(row.line)
                        promptTokens[purpose] = row.promptTokens
                    }
                }
                if let row = await Self.time(request, provider: provider, load: "warm") {
                    print(row.line)
                    promptTokens[purpose] = row.promptTokens
                }
            }

            // 3. Does the real organize prompt fit?
            print("")
            if let organize = promptTokens[.organize] {
                if let contextLength {
                    let share = Double(organize) / Double(contextLength) * 100
                    print(String(
                        format: "context:  organize prompt %d tokens of %d (%.1f%%) — %d tokens of headroom",
                        organize, contextLength, share, contextLength - organize
                    ))
                } else {
                    print("context:  organize prompt \(organize) tokens; the daemon did not report a context length")
                }
            }
            if let search = promptTokens[.search] {
                print("          answer prompt \(search) tokens")
            }
            print("cost:     $0 — nothing left this machine (FR-6.5, NFR-5)")
        }

        // MARK: - Pieces

        struct Row {
            var shape: String
            var load: String
            var seconds: Double
            var promptTokens: Int
            var outputTokens: Int
            var stop: String

            var line: String {
                String(
                    format: "| %@ | %@ | %.1f | %d | %d | %@ |",
                    shape, load, seconds, promptTokens, outputTokens, stop
                )
            }
        }

        /// The committed *local* recording for this shape — its request is the
        /// real prompt, tool schema included.
        static func request(for purpose: AIPurpose, in recordings: [AIRecording]) -> AIRequest? {
            recordings
                .filter { $0.purpose == purpose && $0.provider == AIProviderKind.ollama.rawValue }
                // Largest prompt first: the worst case is the interesting one.
                .max { $0.request.promptByteCount < $1.request.promptByteCount }?
                .request
        }

        static func time(_ request: AIRequest, provider: OllamaProvider, load: String) async -> Row? {
            let started = Date()
            do {
                let response = try await provider.complete(request)
                return Row(
                    shape: request.purpose.rawValue,
                    load: load,
                    seconds: Date().timeIntervalSince(started),
                    promptTokens: response.usage.inputTokens,
                    outputTokens: response.usage.outputTokens,
                    stop: response.stopReason.rawValue
                )
            } catch {
                print("| \(request.purpose.rawValue) | \(load) | — | — | — | \(error) |")
                return nil
            }
        }

        /// `keep_alive: 0` on an empty chat is Ollama's documented unload, and
        /// it is the only way to measure a cold load honestly.
        static func unload(provider: OllamaProvider, model: String, base: URL) async {
            var request = URLRequest(url: base.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONValue.object([
                "model": .string(model),
                "messages": .array([]),
                "keep_alive": .integer(0),
            ]).canonicalData()
            _ = try? await URLSession.shared.data(for: request)
        }

        struct ModelDetail {
            var parameters: String
            var quantization: String
            var contextLength: Int
        }

        /// `GET /api/tags`, read raw: `details.context_length` and the
        /// quantization are not part of ``AIModelInfo``, which is Anthropic's
        /// shape, but they are exactly what decides whether a model is worth
        /// pointing Filaway at.
        static func catalogue(base: URL) async -> [String: ModelDetail] {
            guard let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("api/tags")),
                  let value = try? JSONValue.parse(data),
                  let models = value["models"]?.arrayValue
            else { return [:] }
            var out: [String: ModelDetail] = [:]
            for model in models {
                guard let name = model["name"]?.stringValue else { continue }
                let details = model["details"]
                out[name] = ModelDetail(
                    parameters: details?["parameter_size"]?.stringValue ?? "?",
                    quantization: details?["quantization_level"]?.stringValue ?? "?",
                    contextLength: details?["context_length"]?.intValue ?? 0
                )
            }
            return out
        }
    }
}
