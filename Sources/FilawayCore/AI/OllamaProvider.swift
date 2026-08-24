import Foundation
import OSLog

/// The local Ollama provider: `POST /api/chat` over `URLSession`, no key, no
/// network (FR-6.5, NFR-5, P2-01).
///
/// ```swift
/// let provider = OllamaProvider()                          // http://localhost:11434
/// let models = try await provider.validateKey()            // GET /api/tags
/// let response = try await provider.complete(request)      // POST /api/chat
/// ```
///
/// It is deliberately the same shape as ``ClaudeProvider`` — injectable session
/// configuration, the shared ``AITransport`` retry loop, the same ``AIError``
/// taxonomy — with three differences that matter:
///
/// * **No credential at all.** It never consults an ``APIKeySource``, so
///   ``AIError/notConfigured`` is not reachable from here. That is the point of
///   FR-6.5: a user with no API key still gets organization and answer cards.
/// * **A forced tool becomes `format`.** Ollama has no `tool_choice`; the
///   forced tool's schema constrains the decoder instead, and ``OllamaWire``
///   turns the JSON that comes back into the `tool_use` block every caller
///   above already reads (ADR-066).
/// * **`http` is allowed, but only to loopback.** A remote daemon must be
///   `https` — otherwise the "your notes never leave the machine" argument for
///   running locally would be quietly false.
public struct OllamaProvider: AIProvider {
    public let identifier = AIProviderKind.ollama.rawValue

    public let configuration: OllamaConfiguration
    public let retryPolicy: RetryPolicy
    private let session: URLSession
    private let clock: any AIClock
    private let log: Logger

    public var baseURL: URL { configuration.baseURL }

    /// - Parameters:
    ///   - configuration: where the daemon is and which model it defaults to.
    ///   - sessionConfiguration: injected by tests to install a `URLProtocol`
    ///     stub.
    public init(
        configuration: OllamaConfiguration = OllamaConfiguration(),
        sessionConfiguration: URLSessionConfiguration = AITransport.defaultSessionConfiguration(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: any AIClock = SystemClock()
    ) {
        precondition(
            configuration.validate(),
            "NFR-4: plaintext http is allowed only to loopback; a remote Ollama must be https"
        )
        self.configuration = configuration
        self.retryPolicy = retryPolicy
        self.clock = clock
        session = URLSession(configuration: sessionConfiguration)
        log = Log.ai
    }

    // MARK: - AIProvider

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let data = try OllamaWire.body(for: request).canonicalData()
        log.debug(
            """
            ollama request model=\(request.model.id, privacy: .public) \
            purpose=\(request.purpose.rawValue, privacy: .public) \
            promptBytes=\(request.promptByteCount, privacy: .public) \
            tools=\(request.tools.count, privacy: .public)
            """
        )

        let payload = try await send(
            path: OllamaWire.chatPath,
            method: "POST",
            body: data,
            timeout: request.timeout,
            model: request.model.id
        )
        let response = try OllamaWire.response(from: payload, for: request)
        log.debug(
            """
            ollama response model=\(response.model, privacy: .public) \
            stop=\(response.stopReason.rawValue, privacy: .public) \
            in=\(response.usage.inputTokens, privacy: .public) \
            out=\(response.usage.outputTokens, privacy: .public)
            """
        )
        return response
    }

    /// There is no key to validate, so this answers the question that actually
    /// matters for a local daemon: *is it running, and what has been pulled?*
    ///
    /// A daemon that is not running surfaces as ``AIError/network(code:description:)``
    /// through `URLError`, which is exactly what the status pill wants to say.
    public func validateKey() async throws -> [AIModelInfo] {
        let payload = try await send(
            path: OllamaWire.tagsPath,
            method: "GET",
            body: nil,
            timeout: AIProviderKind.ollama.timeout(for: .validate),
            model: ""
        )
        return try OllamaWire.models(from: payload)
    }

    // MARK: - Transport

    private func send(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        model: String
    ) async throws -> JSONValue {
        try await AITransport.retrying(policy: retryPolicy, clock: clock, log: log, label: identifier) {
            try await perform(path: path, method: method, body: body, timeout: timeout, model: model)
        }
    }

    private func perform(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        model: String
    ) async throws -> JSONValue {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw AIError.badRequest(message: "bad URL \(path)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("filaway/\(FilawayCore.version)", forHTTPHeaderField: "user-agent")
        urlRequest.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw AIError.from(urlError: error)
        } catch is CancellationError {
            throw AIError.cancelled
        } catch {
            throw AIError.network(code: (error as NSError).code, description: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.malformedResponse("not an HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AIError.from(
                status: http.statusCode,
                message: OllamaWire.errorMessage(from: data),
                retryAfter: AITransport.retryAfter(http.value(forHTTPHeaderField: "retry-after"), now: clock.now()),
                model: model
            )
        }

        do {
            return try JSONValue.parse(data)
        } catch {
            throw AIError.malformedResponse("response body is not JSON (\(data.count) bytes)")
        }
    }
}
