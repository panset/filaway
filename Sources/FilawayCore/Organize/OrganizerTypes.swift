import Foundation

// MARK: - Settings

/// FR-4.2's two operating modes.
public enum OrganizeMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Default. The plan is proposed on a non-blocking card; nothing changes
    /// until the user accepts.
    case ask
    /// The plan is applied immediately and then summarised, with Undo.
    case auto
}

/// Everything Settings → AI feeds the organizer (FR-6.2, FR-8.1).
public struct OrganizerSettings: Sendable, Equatable {
    public var mode: OrganizeMode
    /// plan §1 "Default models": Sonnet 5, with Opus 5 as the advanced override.
    public var model: AIModel
    /// FR-4.5. Applied structurally, before any prompt is built.
    public var excludedFolders: [String]
    /// Different notes may be organized concurrently; the same note never is.
    public var maxConcurrentRequests: Int
    /// Estimated input tokens per request (M2-06's budget).
    public var tokenBudget: Int
    public var maxCandidates: Int
    public var candidatePreviewLines: Int
    /// Plans are short; the thinking does the work (FR-6.2 cost).
    public var effort: AIEffort
    public var promptVersion: PromptVersion
    /// Backoff for the offline queue (FR-6.4).
    public var retryPolicy: RetryPolicy
    /// Cap on queued-session retries before the session is dropped from the
    /// queue and reported as failed.
    public var maxQueueAttempts: Int

    public init(
        mode: OrganizeMode = .ask,
        model: AIModel = .defaultOrganize,
        excludedFolders: [String] = [],
        maxConcurrentRequests: Int = 2,
        tokenBudget: Int = 6_000,
        maxCandidates: Int = 6,
        candidatePreviewLines: Int = 20,
        effort: AIEffort = .low,
        promptVersion: PromptVersion = .organize,
        retryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 5, baseDelay: 30, multiplier: 2, maxDelay: 900, jitter: 0.2),
        maxQueueAttempts: Int = 8
    ) {
        self.mode = mode
        self.model = model
        self.excludedFolders = excludedFolders
        self.maxConcurrentRequests = Swift.max(1, maxConcurrentRequests)
        self.tokenBudget = tokenBudget
        self.maxCandidates = maxCandidates
        self.candidatePreviewLines = candidatePreviewLines
        self.effort = effort
        self.promptVersion = promptVersion
        self.retryPolicy = retryPolicy
        self.maxQueueAttempts = Swift.max(1, maxQueueAttempts)
    }

    var contextBuilder: OrganizeContextBuilder {
        OrganizeContextBuilder(
            excludedFolders: excludedFolders,
            maxCandidates: maxCandidates,
            candidatePreviewLines: candidatePreviewLines,
            tokenBudget: tokenBudget,
            promptVersion: promptVersion
        )
    }
}

// MARK: - Proposals

/// Identity of one proposed plan — what Accept, Edit and Dismiss refer to.
public struct ProposalID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(_ uuid: UUID) { rawValue = uuid }
    public var description: String { rawValue.uuidString }
}

/// A plan waiting for the user in *ask* mode (FR-4.2).
public struct ProposedPlan: Sendable, Hashable, Identifiable {
    public var id: ProposalID
    public var sessionID: SessionID
    public var plan: OrganizationPlan
    /// The validation that let it through — its warnings are worth showing.
    public var validation: PlanValidation
    /// Actions the validator rejected and the organizer dropped.
    public var droppedActions: [PlanIssue]
    public var proposedAt: Date
    /// Session notes plus every note the plan touches — the set an edit
    /// supersedes.
    public var noteIDs: [NoteID]
    /// Text of each session note when the plan was made. Dismissing advances
    /// the baseline to exactly this (the user said "no" to *this* content).
    public var snapshotTexts: [NoteID: String]

    public init(
        id: ProposalID = ProposalID(),
        sessionID: SessionID,
        plan: OrganizationPlan,
        validation: PlanValidation,
        droppedActions: [PlanIssue] = [],
        proposedAt: Date,
        noteIDs: [NoteID],
        snapshotTexts: [NoteID: String]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.plan = plan
        self.validation = validation
        self.droppedActions = droppedActions
        self.proposedAt = proposedAt
        self.noteIDs = noteIDs
        self.snapshotTexts = snapshotTexts
    }
}

// MARK: - Apply
//
// ``PlanApplying``, ``AppliedPlan`` and ``ApplyError`` live with the applier
// itself, in `Organize/ApplyModel.swift` (ADR-033): one contract, defined by the
// side that implements it, named by the side that calls it.

// MARK: - The offline queue (FR-6.4)

/// A session that could not reach the provider.
public struct PendingSession: Sendable, Hashable, Codable, Identifiable {
    public var id: SessionID
    public var noteIDs: [NoteID]
    public var startedAt: Date
    public var endedAt: Date
    public var reason: SessionEndReason
    /// How many times the provider has been tried for this session.
    public var attempts: Int
    /// Content-free description of the last failure, for the status pill.
    public var lastError: String?
    public var nextAttemptAt: Date?

    public init(
        id: SessionID,
        noteIDs: [NoteID],
        startedAt: Date,
        endedAt: Date,
        reason: SessionEndReason,
        attempts: Int = 0,
        lastError: String? = nil,
        nextAttemptAt: Date? = nil
    ) {
        self.id = id
        self.noteIDs = noteIDs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
        self.attempts = attempts
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
    }

    public init(session: Session, attempts: Int = 0, lastError: String? = nil, nextAttemptAt: Date? = nil) {
        self.init(
            id: session.id,
            noteIDs: session.noteIDs,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            reason: session.reason,
            attempts: attempts,
            lastError: lastError,
            nextAttemptAt: nextAttemptAt
        )
    }

    public var session: Session {
        Session(id: id, noteIDs: noteIDs, startedAt: startedAt, endedAt: endedAt, reason: reason)
    }
}

/// Where sessions wait out an outage (FR-6.4, plan M2-09).
///
/// A protocol for the same reason as ``BaselineStore``: the durable
/// implementation is a database table that another milestone owns, and nothing
/// in the pipeline may block on it existing. Losing the queue costs a filing
/// pass, never a keystroke.
public protocol PendingSessionStore: Sendable {
    func enqueue(_ session: PendingSession) async throws
    func remove(_ id: SessionID) async throws
    /// Everything queued, oldest first.
    func all() async throws -> [PendingSession]
}

public actor InMemoryPendingSessionStore: PendingSessionStore {
    private var sessions: [SessionID: PendingSession] = [:]

    public init(_ sessions: [PendingSession] = []) {
        for session in sessions { self.sessions[session.id] = session }
    }

    public func enqueue(_ session: PendingSession) async throws {
        sessions[session.id] = session
    }

    public func remove(_ id: SessionID) async throws {
        sessions.removeValue(forKey: id)
    }

    public func all() async throws -> [PendingSession] {
        sessions.values.sorted { $0.endedAt < $1.endedAt }
    }

    public var count: Int { sessions.count }
}

// MARK: - Events

/// Why a proposal went away without being applied.
public enum WithdrawalReason: String, Sendable, Hashable, Codable {
    /// The user resumed typing in one of the plan's notes (FR-3.2 supersede).
    case supersededByEdit
    /// A newer session covering the same notes ended.
    case supersededBySession
    /// The user pressed Dismiss.
    case dismissed
}

/// Why a session produced no plan.
public enum OrganizeSkipReason: String, Sendable, Hashable, Codable {
    /// Nothing new since the organized baseline — deletions and reflows only.
    case noEffectiveDelta
    /// Every touched note has since disappeared.
    case noNotes
    /// The model answered "nothing needs filing" (FR-4.6).
    case nothingToDo
}

/// Why a session produced nothing usable. Never content-bearing.
public enum OrganizeFailure: Sendable, Equatable {
    /// A provider error that is not worth queueing (a 400, a refusal).
    case provider(AIError)
    /// The reply could not be read as a plan.
    case decoding(String)
    /// The plan did not survive validation. Carries the issues, for the log.
    case invalidPlan(PlanValidation)
    /// The applier refused or failed.
    case apply(ApplyError)
    /// The queue gave up after ``OrganizerSettings/maxQueueAttempts``.
    case abandoned(String)

    /// Content-free sentence for the status pill and the log.
    public var label: String {
        switch self {
        case let .provider(error): return error.description
        case let .decoding(detail): return "The reply was not a usable plan (\(detail))."
        case let .invalidPlan(validation): return "The plan was rejected: \(validation.summary)"
        case let .apply(error): return "The plan could not be applied (\(error))."
        case let .abandoned(detail): return "Gave up on this session (\(detail))."
        }
    }
}

/// What the organizer publishes. The card in FR-4.2 / Figure 2a is driven
/// entirely by ``proposed(_:)`` and ``applied(_:)``; everything else is state
/// the shell reflects in the status pill or simply logs.
public enum OrganizerEvent: Sendable, Equatable {
    /// *Ask* mode: a plan is waiting for Accept / Edit / Dismiss.
    case proposed(ProposedPlan)
    /// *Auto* mode, or an accepted proposal: it is done, with Undo available.
    case applied(AppliedPlan)
    /// A proposal is gone. The card must be taken down.
    case withdrawn(ProposalID, reason: WithdrawalReason)
    /// Accept lost a race with the user's own typing: the note changed since
    /// the plan was made, so the plan was discarded untouched (FR-3.2).
    case stale(ProposalID, noteIDs: [NoteID])
    /// A request in flight was cancelled because the user resumed typing.
    case cancelled(SessionID, noteID: NoteID)
    case skipped(SessionID, reason: OrganizeSkipReason)
    case failed(SessionID, failure: OrganizeFailure)
    /// FR-6.4: the session is waiting for the provider to come back.
    case queued(SessionID, attempt: Int, retryAt: Date?)
    /// A queued session is being retried.
    case retrying(SessionID, attempt: Int)
}
