import Foundation
import OSLog

/// The Anthropic Claude provider: raw Messages API over `URLSession`
/// (FR-6.1, FR-6.4, NFR-4, NFR-5).
///
/// ```swift
/// let provider = ClaudeProvider(keySource: .storeThenEnvironment(KeychainStore()))
/// let models = try await provider.validateKey()          // GET /v1/models, free
/// let response = try await provider.complete(request)    // POST /v1/messages
/// ```
///
/// Design notes:
///
/// * **The session configuration is injectable**, which is how the tests install
///   a `URLProtocol` stub and drive every branch of the error taxonomy without a
///   network or a key.
/// * **TLS only.** A non-`https` base URL is rejected at construction time, and
///   the session floor is TLS 1.2.
/// * **Nothing about the prompt is logged** beyond byte counts and the model id
///   (NFR-4). Note text never reaches `OSLog`, at any level.
/// * **Retries** follow ``RetryPolicy``: 429/5xx/network only, honouring
///   `retry-after`, never a 4xx.
public struct ClaudeProvider: AIProvider {
    public let identifier = "claude"

    public let baseURL: URL
    public let keySource: APIKeySource
    public let retryPolicy: RetryPolicy
    private let session: URLSession
    private let clock: any AIClock
    private let log: Logger

    /// - Parameters:
    ///   - keySource: where the API key comes from; ``AIError/notConfigured`` is
    ///     thrown when it yields nothing.
    ///   - configuration: injected by tests to install a `URLProtocol` stub.
    ///   - baseURL: must be `https`.
    public init(
        keySource: APIKeySource,
        configuration: URLSessionConfiguration = ClaudeProvider.defaultConfiguration(),
        baseURL: URL = ClaudeWire.defaultBaseURL,
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: any AIClock = SystemClock()
    ) {
        precondition(baseURL.scheme?.lowercased() == "https", "NFR-4: the provider speaks TLS only")
        self.baseURL = baseURL
        self.keySource = keySource
        self.retryPolicy = retryPolicy
        self.clock = clock
        session = URLSession(configuration: configuration)
        log = Log.ai
    }

    /// Ephemeral session with no disk cache and no cookies — a prompt or a
    /// response must never be written to disk by the URL loading system.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.waitsForConnectivity = false
        return configuration
    }

    // MARK: - AIProvider

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let body = ClaudeWire.body(for: request)
        let data = try body.canonicalData()
        log.debug(
            """
            claude request model=\(request.model.id, privacy: .public) \
            purpose=\(request.purpose.rawValue, privacy: .public) \
            promptBytes=\(request.promptByteCount, privacy: .public) \
            tools=\(request.tools.count, privacy: .public)
            """
        )

        let (payload, requestID) = try await send(
            path: "/v1/messages",
            method: "POST",
            body: data,
            timeout: request.timeout,
            model: request.model.id
        )
        let response = try ClaudeWire.response(from: payload, requestID: requestID)
        log.debug(
            """
            claude response model=\(response.model, privacy: .public) \
            stop=\(response.stopReason.rawValue, privacy: .public) \
            in=\(response.usage.inputTokens, privacy: .public) \
            out=\(response.usage.outputTokens, privacy: .public)
            """
        )
        return response
    }

    public func validateKey() async throws -> [AIModelInfo] {
        let (payload, _) = try await send(
            path: "/v1/models?limit=100",
            method: "GET",
            body: nil,
            timeout: AIPurpose.validate.defaultTimeout,
            model: ""
        )
        return try ClaudeWire.models(from: payload)
    }

    // MARK: - Transport

    private func send(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        model: String
    ) async throws -> (JSONValue, String?) {
        guard let key = try keySource.key() else { throw AIError.notConfigured }

        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await perform(
                    path: path, method: method, body: body, timeout: timeout, key: key, model: model
                )
            } catch let error as AIError {
                guard retryPolicy.shouldRetry(error, attempt: attempt) else { throw error }
                let delay = retryPolicy.delay(
                    afterAttempt: attempt,
                    retryAfter: error.retryAfter,
                    randomFraction: clock.randomFraction()
                )
                log.info(
                    """
                    claude retry attempt=\(attempt, privacy: .public) \
                    in=\(delay, privacy: .public)s reason=\(String(describing: error), privacy: .public)
                    """
                )
                try await clock.sleep(for: delay)
                attempt += 1
            } catch is CancellationError {
                throw AIError.cancelled
            }
        }
    }

    private func perform(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        key: String,
        model: String
    ) async throws -> (JSONValue, String?) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AIError.badRequest(message: "bad URL \(path)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(ClaudeWire.version, forHTTPHeaderField: "anthropic-version")
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
        let requestID = http.value(forHTTPHeaderField: "request-id")

        guard (200 ..< 300).contains(http.statusCode) else {
            throw AIError.from(
                status: http.statusCode,
                message: ClaudeWire.errorMessage(from: data),
                retryAfter: ClaudeWire.retryAfter(http.value(forHTTPHeaderField: "retry-after"), now: clock.now()),
                model: model
            )
        }

        do {
            return (try JSONValue.parse(data), requestID)
        } catch {
            throw AIError.malformedResponse("response body is not JSON (\(data.count) bytes)")
        }
    }
}
