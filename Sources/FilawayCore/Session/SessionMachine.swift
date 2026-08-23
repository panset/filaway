import Foundation

/// The session rules of FR-3.1, as a pure state machine.
///
/// Kept separate from ``SessionTracker`` on purpose: every rule below is
/// testable synchronously, with an explicit `now`, no actor and no timer. The
/// actor's only extra job is to *schedule* a call to ``handle(_:at:)`` with
/// ``Input/tick`` at ``nextDeadline``.
///
/// ## The rules
///
/// | Input | idle | active | pendingEnd (grace) |
/// |---|---|---|---|
/// | `edit` | starts a session, touches the note | touches the note, resets the idle timer | **cancels the grace**, session resumes, note touched |
/// | `activity` | ignored (a session starts on an *edit*) | resets the idle timer | cancels the grace, session resumes |
/// | `noteSwitched` | ignored | resets the idle timer | cancels the grace |
/// | `resignActive` / `windowClosed` | ignored | ends the session, pipeline scheduled at `now + grace` | keeps the earlier deadline |
/// | `becomeActive` | ignored | ignored | **ignored** — coming back is not activity; only touching the editor is |
/// | `terminate` | ignored | ends immediately, no grace | ends immediately, no grace |
/// | `tick` | — | ends with `.idle` once `lastActivity + idleInterval` passes | fires the pipeline once `fireAt` passes |
///
/// A session with no touched notes never ends into a ``Session``: there is
/// nothing to organize, so it is simply discarded.
public struct SessionMachine: Sendable {
    public enum Input: Sendable, Hashable {
        /// The text of `noteID` changed.
        case edit(NoteID)
        /// The editor reported activity that is not a text change.
        case activity(NoteID, EditorActivityKind)
        /// The user moved to another note (or to none).
        case noteSwitched(NoteID?)
        case appDidResignActive
        case appDidBecomeActive
        case windowClosed
        case appWillTerminate
        /// Time passed; re-evaluate the deadlines.
        case tick
    }

    public enum Output: Sendable, Hashable {
        case started(SessionID, at: Date)
        case endScheduled(SessionID, reason: SessionEndReason, fireAt: Date)
        case endCancelled(SessionID, at: Date)
        case ended(Session)
        /// The session ended with nothing typed in it — no pipeline, no event
        /// for the app, but useful in tests and logs.
        case discarded(SessionID, reason: SessionEndReason)
    }

    /// A session being accumulated.
    struct Draft: Sendable {
        var id: SessionID
        var startedAt: Date
        var lastActivity: Date
        var touched: [NoteID]

        mutating func touch(_ id: NoteID) {
            if !touched.contains(id) { touched.append(id) }
        }
    }

    enum Phase: Sendable {
        case idle
        case active(Draft)
        case pendingEnd(Draft, reason: SessionEndReason, endedAt: Date, fireAt: Date)
    }

    public var configuration: SessionConfiguration
    var phase: Phase = .idle
    /// Injectable so tests get predictable session ids.
    private let makeID: @Sendable () -> SessionID

    public init(
        configuration: SessionConfiguration = .default,
        makeID: @escaping @Sendable () -> SessionID = { SessionID() }
    ) {
        self.configuration = configuration
        self.makeID = makeID
    }

    // MARK: - Observable state

    public var isSessionActive: Bool {
        if case .active = phase { return true }
        return false
    }

    /// `true` between "the user switched away" and the end of the grace.
    public var isEndPending: Bool {
        if case .pendingEnd = phase { return true }
        return false
    }

    public var currentSessionID: SessionID? {
        switch phase {
        case .idle: return nil
        case let .active(draft): return draft.id
        case let .pendingEnd(draft, _, _, _): return draft.id
        }
    }

    /// Notes edited so far in the current session.
    public var touchedNoteIDs: [NoteID] {
        switch phase {
        case .idle: return []
        case let .active(draft): return draft.touched
        case let .pendingEnd(draft, _, _, _): return draft.touched
        }
    }

    /// When ``Input/tick`` next needs to be delivered, or `nil` when no timer is
    /// running.
    public var nextDeadline: Date? {
        switch phase {
        case .idle:
            return nil
        case let .active(draft):
            return draft.lastActivity.addingTimeInterval(configuration.idleInterval)
        case let .pendingEnd(_, _, _, fireAt):
            return fireAt
        }
    }

    // MARK: - Transitions

    public mutating func handle(_ input: Input, at now: Date) -> [Output] {
        switch input {
        case let .edit(noteID):
            return touch(noteID, at: now)

        case .activity, .noteSwitched:
            return sustain(at: now)

        case .appDidResignActive:
            return end(reason: .appResignedActive, at: now)

        case .windowClosed:
            return end(reason: .windowClosed, at: now)

        case .appWillTerminate:
            return end(reason: .appWillTerminate, at: now)

        case .appDidBecomeActive:
            // Deliberately inert. Returning to the app is not editing, and
            // amendment 2 cancels the grace only when the user actually comes
            // back to the keyboard — otherwise a ⌘-Tab round trip would keep
            // postponing filing forever.
            return []

        case .tick:
            return tick(at: now)
        }
    }

    /// Convenience for the common case.
    public mutating func handle(_ activity: EditorActivity) -> [Output] {
        activity.kind.isEdit
            ? handle(.edit(activity.noteID), at: activity.at)
            : handle(.activity(activity.noteID, activity.kind), at: activity.at)
    }

    // MARK: - Pieces

    private mutating func touch(_ noteID: NoteID, at now: Date) -> [Output] {
        switch phase {
        case .idle:
            let draft = Draft(id: makeID(), startedAt: now, lastActivity: now, touched: [noteID])
            phase = .active(draft)
            return [.started(draft.id, at: now)]

        case var .active(draft):
            draft.touch(noteID)
            draft.lastActivity = now
            phase = .active(draft)
            return []

        case .pendingEnd(var draft, _, _, _):
            // Amendment 2: typing inside the grace supersedes the end silently.
            draft.touch(noteID)
            draft.lastActivity = now
            phase = .active(draft)
            return [.endCancelled(draft.id, at: now)]
        }
    }

    private mutating func sustain(at now: Date) -> [Output] {
        switch phase {
        case .idle:
            return []

        case var .active(draft):
            draft.lastActivity = now
            phase = .active(draft)
            return []

        case .pendingEnd(var draft, _, _, _):
            draft.lastActivity = now
            phase = .active(draft)
            return [.endCancelled(draft.id, at: now)]
        }
    }

    private mutating func end(reason: SessionEndReason, at now: Date) -> [Output] {
        switch phase {
        case .idle:
            return []

        case let .active(draft):
            guard !draft.touched.isEmpty else {
                phase = .idle
                return [.discarded(draft.id, reason: reason)]
            }
            guard reason.hasGracePeriod, configuration.gracePeriod > 0 else {
                phase = .idle
                return [.ended(session(from: draft, endedAt: now, reason: reason))]
            }
            let fireAt = now.addingTimeInterval(configuration.gracePeriod)
            phase = .pendingEnd(draft, reason: reason, endedAt: now, fireAt: fireAt)
            return [.endScheduled(draft.id, reason: reason, fireAt: fireAt)]

        case let .pendingEnd(draft, existingReason, endedAt, fireAt):
            guard reason.hasGracePeriod else {
                // Quitting: no time left to be polite about it. The session
                // still ended when the user switched away, so its end time and
                // reason are the ones already recorded — terminate only cuts
                // the grace short.
                phase = .idle
                return [.ended(session(from: draft, endedAt: endedAt, reason: existingReason))]
            }
            // Already counting down — a second ⌘-Tab must not push the deadline
            // further out.
            phase = .pendingEnd(draft, reason: existingReason, endedAt: endedAt, fireAt: fireAt)
            return []
        }
    }

    private mutating func tick(at now: Date) -> [Output] {
        switch phase {
        case .idle:
            return []

        case let .active(draft):
            let deadline = draft.lastActivity.addingTimeInterval(configuration.idleInterval)
            guard now >= deadline else { return [] }
            phase = .idle
            guard !draft.touched.isEmpty else { return [.discarded(draft.id, reason: .idle)] }
            return [.ended(session(from: draft, endedAt: deadline, reason: .idle))]

        case let .pendingEnd(draft, reason, endedAt, fireAt):
            guard now >= fireAt else { return [] }
            phase = .idle
            return [.ended(session(from: draft, endedAt: endedAt, reason: reason))]
        }
    }

    private func session(from draft: Draft, endedAt: Date, reason: SessionEndReason) -> Session {
        Session(
            id: draft.id,
            noteIDs: draft.touched,
            startedAt: draft.startedAt,
            endedAt: endedAt,
            reason: reason
        )
    }
}
