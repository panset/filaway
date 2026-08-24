import Foundation

/// Wall clock plus a cancellable wait, injected into ``SessionTracker`` so the
/// idle interval and the 30 s grace are testable without spending real minutes.
///
/// Deliberately *not* ``AIClock``: that one's test double returns from `sleep`
/// immediately (it only records the delay), which is right for retry backoff
/// and wrong for a timer whose whole job is to *not* fire yet.
public protocol SessionClock: Sendable {
    func now() -> Date
    /// Suspends until `deadline`. Throws `CancellationError` if the surrounding
    /// task is cancelled first.
    func sleep(until deadline: Date) async throws
}

/// The production clock.
public struct SystemSessionClock: SessionClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSince(Date())
        guard interval > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
