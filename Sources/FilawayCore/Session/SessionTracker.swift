import Foundation

/// FR-3.1 — when a writing session starts, what it contains, and when it ends.
///
/// The rules live in ``SessionMachine`` (a pure state machine, tested
/// synchronously). This actor adds the three things a state machine cannot do
/// for itself:
///
/// 1. **A timer.** After every input it re-arms a single task that sleeps until
///    ``SessionMachine/nextDeadline`` on the injected ``SessionClock`` and then
///    calls ``tick()``.
/// 2. **The flush hook.** Autosave is debounced 750 ms (plan §1), so the file on
///    disk can be a keystroke or two behind when the session ends. The hook is
///    awaited *before* ``SessionEvent/ended(_:)`` is published, which is what
///    makes the ordering contract below true.
/// 3. **Publication.** Events go to an `AsyncStream` for the app and, when
///    supplied, to a synchronous observer for tests.
///
/// ## Ordering contract (the app must not reorder these)
///
/// ```text
/// idle timer fires / ⌘-Tab grace expires
///        ↓
/// flushHook()                 — autosave writes the buffer to disk
///        ↓
/// SessionEvent.ended(Session) — published
///        ↓
/// Organizer.sessionEnded(_:)  — reads each touched note's *current* text and
///                               its organized baseline, then builds the prompt
/// ```
///
/// The organizer must take its baseline snapshot **after** the flush, or the
/// delta it computes will be missing the last keystrokes; and it must take it
/// **before** any apply, or a compare-and-swap precondition would be recorded
/// against text that has already been rewritten.
public actor SessionTracker {
    private var machine: SessionMachine
    private let clock: any SessionClock
    private var timer: Task<Void, Never>?
    private var flushHook: (@Sendable () async -> Void)?
    private let observer: (@Sendable (SessionEvent) -> Void)?
    private let continuation: AsyncStream<SessionEvent>.Continuation

    /// Every session event, in order. Buffered without limit, because dropping
    /// a `.ended` would silently lose a session.
    public nonisolated let events: AsyncStream<SessionEvent>

    private let log = Log.make("session")

    /// - Parameters:
    ///   - configuration: idle interval and grace (FR-3.1, amendment 2).
    ///   - clock: injected for tests.
    ///   - makeID: injected for tests that want predictable session ids.
    ///   - observer: called synchronously on the actor as each event is
    ///     published, before the stream sees it. The app uses ``events``; the
    ///     race-matrix tests use this so no assertion has to wait on a task.
    public init(
        configuration: SessionConfiguration = .default,
        clock: any SessionClock = SystemSessionClock(),
        makeID: @escaping @Sendable () -> SessionID = { SessionID() },
        observer: (@Sendable (SessionEvent) -> Void)? = nil
    ) {
        machine = SessionMachine(configuration: configuration, makeID: makeID)
        self.clock = clock
        self.observer = observer
        var escaped: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    deinit {
        timer?.cancel()
        continuation.finish()
    }

    // MARK: - Configuration

    public var configuration: SessionConfiguration { machine.configuration }

    /// Settings → idle interval (FR-8.1). Takes effect on the running session:
    /// the deadline is recomputed from the last activity, so shortening the
    /// interval can end the current session at the next tick.
    public func setConfiguration(_ configuration: SessionConfiguration) async {
        machine.configuration = configuration
        await armTimer()
    }

    /// The autosave flush, awaited before every ``SessionEvent/ended(_:)``.
    ///
    /// Must be idempotent and quick; it runs on the session end path, and a
    /// hook that throws or hangs would hold up filing.
    public func setFlushHook(_ hook: (@Sendable () async -> Void)?) {
        flushHook = hook
    }

    // MARK: - Inputs

    /// The text of `noteID` changed. This is what starts a session and what
    /// marks a note as *touched* (FR-3.1).
    public func noteEdited(_ noteID: NoteID, at now: Date? = nil) async {
        await apply(.edit(noteID), at: now)
    }

    /// A keystroke, selection change or scroll from the editor (FR-3.1's "not
    /// being actively scrolled/selected"). A `.keystroke` here is equivalent to
    /// ``noteEdited(_:at:)``.
    public func editorActivity(_ noteID: NoteID, kind: EditorActivityKind, at now: Date? = nil) async {
        await apply(kind.isEdit ? .edit(noteID) : .activity(noteID, kind), at: now)
    }

    public func record(_ activity: EditorActivity) async {
        await editorActivity(activity.noteID, kind: activity.kind, at: activity.at)
    }

    /// The user opened another note. Not an edit, but unambiguously activity, so
    /// it keeps the session alive.
    public func noteSwitched(to noteID: NoteID?, at now: Date? = nil) async {
        await apply(.noteSwitched(noteID), at: now)
    }

    /// ⌘-Tab away. Ends the session; the pipeline waits out the grace.
    public func appDidResignActive(at now: Date? = nil) async {
        await apply(.appDidResignActive, at: now)
    }

    /// Back in the app. Deliberately does *not* cancel a grace — only touching
    /// the editor does.
    public func appDidBecomeActive(at now: Date? = nil) async {
        await apply(.appDidBecomeActive, at: now)
    }

    public func windowClosed(at now: Date? = nil) async {
        await apply(.windowClosed, at: now)
    }

    /// Quitting: end and publish now, grace or no grace.
    public func appWillTerminate(at now: Date? = nil) async {
        await apply(.appWillTerminate, at: now)
    }

    /// Re-evaluates the deadlines at the clock's current time.
    ///
    /// Called by the internal timer; public because it makes the actor-level
    /// tests deterministic (advance a manual clock, then tick) and because the
    /// app can safely call it after a wake from sleep.
    public func tick() async {
        await apply(.tick, at: nil)
    }

    /// Cancels the timer. The app calls this on teardown; tests call it so no
    /// task is left suspended on a manual clock.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Observable state

    public var isSessionActive: Bool { machine.isSessionActive }
    public var isEndPending: Bool { machine.isEndPending }
    public var currentSessionID: SessionID? { machine.currentSessionID }
    public var touchedNoteIDs: [NoteID] { machine.touchedNoteIDs }
    public var nextDeadline: Date? { machine.nextDeadline }

    // MARK: - Engine

    private func apply(_ input: SessionMachine.Input, at now: Date?) async {
        let instant = now ?? clock.now()
        let outputs = machine.handle(input, at: instant)
        for output in outputs {
            await publish(output)
        }
        await armTimer()
    }

    private func publish(_ output: SessionMachine.Output) async {
        switch output {
        case let .started(id, at):
            log.debug("session \(id.uuidString, privacy: .public) started")
            emit(.started(id, at: at))

        case let .endScheduled(id, reason, fireAt):
            log.debug("session \(id.uuidString, privacy: .public) end scheduled (\(reason.rawValue, privacy: .public))")
            emit(.endScheduled(id, reason: reason, fireAt: fireAt))

        case let .endCancelled(id, at):
            log.debug("session \(id.uuidString, privacy: .public) end cancelled")
            emit(.endCancelled(id, at: at))

        case let .discarded(id, reason):
            log.debug("session \(id.uuidString, privacy: .public) discarded (\(reason.rawValue, privacy: .public))")

        case let .ended(session):
            // Ordering contract: flush, *then* publish.
            await flushHook?()
            log.info("""
            session \(session.id.uuidString, privacy: .public) ended \
            (\(session.reason.rawValue, privacy: .public), \(session.noteIDs.count, privacy: .public) notes)
            """)
            emit(.ended(session))
        }
    }

    private func emit(_ event: SessionEvent) {
        observer?(event)
        continuation.yield(event)
    }

    /// One timer at a time, always aimed at the machine's current deadline.
    private func armTimer() async {
        timer?.cancel()
        timer = nil
        guard let deadline = machine.nextDeadline else { return }
        timer = Task { [clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return  // cancelled — a newer input has re-armed the timer
            }
            guard !Task.isCancelled else { return }
            await self.tick()
        }
    }
}
