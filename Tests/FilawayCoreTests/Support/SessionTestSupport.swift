import Foundation

@testable import FilawayCore

/// A clock the test drives by hand.
///
/// `sleep(until:)` suspends until the test moves the clock past the deadline
/// (or the task is cancelled), so no test in the session or organizer suites
/// spends real time — the 3-minute idle interval and the 30 s grace are
/// advanced instantly.
final class ManualSessionClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var nextToken = 0
    private var waiters: [Int: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(now: Date = Date(timeIntervalSince1970: 1_756_000_000)) {
        current = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Moves time forward and wakes everything that was waiting for it.
    func advance(by interval: TimeInterval) {
        advance(to: now().addingTimeInterval(interval))
    }

    func advance(to instant: Date) {
        lock.lock()
        current = max(current, instant)
        let due = waiters.filter { $0.value.deadline <= current }
        for key in due.keys { waiters.removeValue(forKey: key) }
        lock.unlock()
        for (_, waiter) in due { waiter.continuation.resume() }
    }

    /// How many timers are armed — a tracker with no session must have none.
    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func sleep(until deadline: Date) async throws {
        let token: Int = {
            lock.lock()
            defer { lock.unlock() }
            nextToken += 1
            return nextToken
        }()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                // The task can already be cancelled by the time the body runs,
                // in which case `onCancel` has been and gone and nobody would
                // ever wake this waiter.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[token] = (deadline, continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: token)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Collects what a tracker or organizer published, synchronously.
///
/// The actors call their observer inline while they are still on their own
/// executor, so an assertion right after an awaited input sees a complete,
/// ordered history — no polling, no timeouts, no flakes.
final class EventRecorder<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { events.count }

    func record(_ event: Event) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    var observer: @Sendable (Event) -> Void {
        { [self] event in record(event) }
    }
}

extension EventRecorder where Event == SessionEvent {
    var endedSessions: [Session] {
        events.compactMap { if case let .ended(session) = $0 { return session } else { return nil } }
    }

    var kinds: [String] {
        events.map { event in
            switch event {
            case .started: return "started"
            case .endScheduled: return "endScheduled"
            case .endCancelled: return "endCancelled"
            case .ended: return "ended"
            }
        }
    }
}

/// Fixed note ids for the session and organizer suites.
enum SessionNotes {
    static let a = NoteID(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!)
    static let b = NoteID(UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!)
    static let c = NoteID(UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!)
}
