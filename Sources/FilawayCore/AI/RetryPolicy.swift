import Foundation

/// Wall clock plus sleeping, injectable so retry/backoff is testable without
/// spending real seconds.
public protocol AIClock: Sendable {
    func now() -> Date
    func sleep(for duration: TimeInterval) async throws
    /// Uniform random value in `0..<1`, used for backoff jitter.
    func randomFraction() -> Double
}

/// The production clock.
public struct SystemClock: AIClock {
    public init() {}
    public func now() -> Date { Date() }

    public func sleep(for duration: TimeInterval) async throws {
        guard duration > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    public func randomFraction() -> Double { Double.random(in: 0 ..< 1) }
}

/// Exponential backoff with full jitter, capped, and always deferring to a
/// server-supplied `retry-after`.
///
/// Retries happen only for ``AIError/isRetryable`` cases — 429, 5xx/529,
/// network and timeout. A 4xx is never retried: the key is wrong, the model
/// name is wrong, or the request is malformed, and repeating it just burns the
/// user's rate limit.
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts, the first one included.
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// Fraction of the computed delay that is randomised (0 = none, 1 = full).
    public var jitter: Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 30,
        jitter: Double = 0.5
    ) {
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = Swift.min(Swift.max(jitter, 0), 1)
    }

    /// No retries at all — what the replay harness and unit tests use.
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Whether another attempt should be made after `error` on `attempt`
    /// (1-based).
    public func shouldRetry(_ error: AIError, attempt: Int) -> Bool {
        attempt < maxAttempts && error.isRetryable
    }

    /// Delay before the attempt following `attempt` (1-based).
    ///
    /// A server `retry-after` wins outright — it is the only number that knows
    /// when the limit actually resets — clamped to ``maxDelay``.
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, randomFraction: Double) -> TimeInterval {
        if let retryAfter { return Swift.min(Swift.max(retryAfter, 0), maxDelay) }
        let exponential = baseDelay * pow(multiplier, Double(Swift.max(0, attempt - 1)))
        let capped = Swift.min(exponential, maxDelay)
        let jittered = capped * (1 - jitter) + capped * jitter * Swift.min(Swift.max(randomFraction, 0), 1)
        return Swift.max(0, jittered)
    }
}
