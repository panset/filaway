import Foundation

/// Identity of one writing session (FR-3.1).
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
    public let rawValue: UUID

    public init() { rawValue = UUID() }
    public init(_ uuid: UUID) { rawValue = uuid }

    public init?(_ description: String) {
        guard let uuid = UUID(uuidString: description.trimmingCharacters(in: .whitespaces)) else { return nil }
        rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { uuidString }

    public init(from decoder: Decoder) throws {
        rawValue = try UUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Why a session ended (FR-3.1 + plan §1 amendment 2).
public enum SessionEndReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// No keystroke, selection or scroll for the idle interval.
    case idle
    /// The app stopped being frontmost (⌘-Tab). Subject to the 30 s grace.
    case appResignedActive
    /// The window was closed. Subject to the 30 s grace.
    case windowClosed
    /// The app is quitting — the pipeline gets no grace because there may be no
    /// process left to run it.
    case appWillTerminate

    /// Plan §1 amendment 2: deactivation and window close *end* the session but
    /// delay the pipeline by a grace period, because the core loop is "write a
    /// command → ⌘-Tab to Terminal → come back".
    public var hasGracePeriod: Bool {
        switch self {
        case .appResignedActive, .windowClosed: return true
        case .idle, .appWillTerminate: return false
        }
    }
}

/// A finished writing session — the unit the organize pipeline consumes.
public struct Session: Sendable, Hashable, Codable, Identifiable {
    public let id: SessionID
    /// Notes the user *edited* during the session, in first-touch order. Notes
    /// that were merely opened, scrolled or selected are not here: FR-4.1
    /// organizes "the session's content", and a note nobody typed into has no
    /// session content.
    public let noteIDs: [NoteID]
    public let startedAt: Date
    public let endedAt: Date
    public let reason: SessionEndReason

    public init(
        id: SessionID = SessionID(),
        noteIDs: [NoteID],
        startedAt: Date,
        endedAt: Date,
        reason: SessionEndReason
    ) {
        self.id = id
        self.noteIDs = noteIDs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var isEmpty: Bool { noteIDs.isEmpty }
}

/// What ``SessionTracker`` publishes.
///
/// Everything but ``ended(_:)`` is informational — the app can show "session in
/// progress" or a "filing in 30 s…" affordance. ``ended(_:)`` is the one the
/// ``Organizer`` acts on, and it is emitted **after** the flush hook has run
/// (see ``SessionTracker/setFlushHook(_:)``).
public enum SessionEvent: Sendable, Hashable {
    case started(SessionID, at: Date)
    /// The session ended for a reason that carries a grace period; the pipeline
    /// will start at `fireAt` unless the user comes back to the keyboard.
    case endScheduled(SessionID, reason: SessionEndReason, fireAt: Date)
    /// Activity resumed inside the grace — plan §1 amendment 2's "supersedes
    /// silently". The same session carries on.
    case endCancelled(SessionID, at: Date)
    case ended(Session)
}

/// Session boundaries, as the user can configure them (FR-3.1, FR-8.1).
public struct SessionConfiguration: Sendable, Hashable, Codable {
    /// FR-3.1: default 3 minutes, range 1–15, clamped on the way in.
    public var idleInterval: TimeInterval
    /// Plan §1 amendment 2: 30 s between "the user switched away" and "start the
    /// pipeline". `[ASSUMPTION]` not user-visible in Settings.
    public var gracePeriod: TimeInterval

    public static let minimumIdleInterval: TimeInterval = 60
    public static let maximumIdleInterval: TimeInterval = 15 * 60
    public static let defaultIdleInterval: TimeInterval = 3 * 60
    public static let defaultGracePeriod: TimeInterval = 30

    public init(
        idleInterval: TimeInterval = SessionConfiguration.defaultIdleInterval,
        gracePeriod: TimeInterval = SessionConfiguration.defaultGracePeriod
    ) {
        self.idleInterval = Swift.min(
            Swift.max(idleInterval, Self.minimumIdleInterval), Self.maximumIdleInterval
        )
        self.gracePeriod = Swift.max(0, gracePeriod)
    }

    public static let `default` = SessionConfiguration()
}
