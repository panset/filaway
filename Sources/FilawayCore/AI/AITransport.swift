import Foundation
import OSLog

/// The transport bits every HTTP-speaking ``AIProvider`` shares (P2-01).
///
/// Extracted from ``ClaudeProvider`` when ``OllamaProvider`` arrived: the
/// session configuration and the retry loop are policy, not vendor detail, and
/// having two copies of them would let the two providers drift apart on
/// privacy (a URL cache on disk) or on backoff.
public enum AITransport {
    /// Ephemeral session with no disk cache and no cookies — a prompt or a
    /// response must never be written to disk by the URL loading system
    /// (NFR-4).
    ///
    /// The TLS floor applies to `https` origins; a loopback `http` base URL
    /// (Ollama) simply never negotiates TLS.
    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Runs `operation`, retrying it per ``RetryPolicy`` — 429/5xx/network/
    /// timeout only, honouring `retry-after`, never a 4xx.
    ///
    /// - Parameters:
    ///   - label: provider identifier, for the log line (`"claude retry …"`).
    ///   - clock: injected so the backoff tests assert delays instead of
    ///     waiting them out.
    static func retrying<T>(
        policy: RetryPolicy,
        clock: any AIClock,
        log: Logger,
        label: String,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as AIError {
                guard policy.shouldRetry(error, attempt: attempt) else { throw error }
                let delay = policy.delay(
                    afterAttempt: attempt,
                    retryAfter: error.retryAfter,
                    randomFraction: clock.randomFraction()
                )
                log.info(
                    """
                    \(label, privacy: .public) retry attempt=\(attempt, privacy: .public) \
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
}
