import Foundation

/// Applying a validated ``OrganizationPlan`` to the library.
///
/// The protocol exists so `Organizer` (M2-05) can be tested against an
/// in-memory double while the app wires up the real ``PlanApplier``.
public protocol PlanApplying: Sendable {
    /// Applies the plan, or changes nothing at all.
    ///
    /// - Throws: ``ApplyError/preconditionFailed(_:)`` when any note in
    ///   `plan.preconditions` has moved on since the plan was made (FR-3.2's
    ///   compare-and-swap) — the caller re-queues the session rather than
    ///   applying half a plan.
    func apply(_ plan: OrganizationPlan) async throws -> AppliedPlan
}

/// Why an apply refused.
public enum ApplyError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Compare-and-swap miss: these notes changed after the plan was made, or
    /// a `moveSegment` segment is no longer in its source verbatim. Nothing was
    /// written (FR-3.2, FR-4.4).
    case preconditionFailed([NoteID])
    /// The plan no longer validates against the library as it now stands.
    case invalidPlan([PlanIssue])
    /// A note the plan names has vanished between the snapshot and the write.
    case noteMissing(String)
    /// The failure hook fired: the applier stopped *and* rolled back.
    case injectedFailure(String)
    /// The failure hook simulated a power cut: the applier stopped and left the
    /// journal row `inProgress` for ``PlanApplier/recoverIncompleteEvents()``.
    case simulatedCrash(String)

    public var description: String {
        switch self {
        case let .preconditionFailed(ids):
            "\(ids.count) note(s) changed since the plan was made; nothing was applied."
        case let .invalidPlan(issues):
            "The plan no longer applies: \(issues.map(\.kind.rawValue).joined(separator: ", "))."
        case let .noteMissing(path):
            "'\(path)' is no longer in the library."
        case let .injectedFailure(step):
            "Injected failure at \(step)."
        case let .simulatedCrash(step):
            "Simulated crash at \(step)."
        }
    }
}

/// What one action ended up doing.
public struct ActionOutcome: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable {
        case applied
        /// The action could not run because an earlier action in the same plan
        /// removed its subject (a `moveSegment` that emptied the note). Never a
        /// silent loss: the segment already reached its destination.
        case skipped
    }

    /// Index into ``OrganizationPlan/actions``.
    public var index: Int
    public var kind: PlanAction.Kind
    public var status: Status
    /// The note the action ended up affecting, when there is one.
    public var noteID: NoteID?
    /// Where that note now lives (or where a created note landed).
    public var relativePath: String?
    /// The path the note had before, when the action moved or retitled it.
    public var previousPath: String?
    /// Content-free sentence for the card and the log (NFR-4).
    public var detail: String

    public var id: Int { index }

    public init(
        index: Int,
        kind: PlanAction.Kind,
        status: Status = .applied,
        noteID: NoteID? = nil,
        relativePath: String? = nil,
        previousPath: String? = nil,
        detail: String
    ) {
        self.index = index
        self.kind = kind
        self.status = status
        self.noteID = noteID
        self.relativePath = relativePath
        self.previousPath = previousPath
        self.detail = detail
    }
}

/// A note the apply moved to the Trash — only ever a `moveSegment` source left
/// empty (plan §1 amendment 1). Its full text is in the Activity event.
public struct TrashedNote: Sendable, Hashable, Codable {
    public var noteID: NoteID
    public var relativePath: String
    /// Where it went, so the card can say "in the Trash" and mean it.
    public var trashURL: String?

    public init(noteID: NoteID, relativePath: String, trashURL: String?) {
        self.noteID = noteID
        self.relativePath = relativePath
        self.trashURL = trashURL
    }
}

/// The result of a successful apply (FR-4.2's card, FR-4.3's Activity row).
public struct AppliedPlan: Sendable, Hashable, Codable, Identifiable {
    /// The Activity event, which is also the journal record.
    public var eventID: ActivityEventID
    /// One plain sentence, built from what actually happened rather than from
    /// what the model said it would do.
    public var summary: String
    public var outcomes: [ActionOutcome]
    /// Notes created, in the order they were created.
    public var createdNotes: [NoteID]
    /// Folders created (empty ones included).
    public var createdFolders: [String]
    public var trashedNotes: [TrashedNote]
    /// Every note whose bytes changed, with its final path.
    public var changedPaths: [NoteID: String]
    public var appliedAt: Date

    public var id: ActivityEventID { eventID }

    public init(
        eventID: ActivityEventID,
        summary: String,
        outcomes: [ActionOutcome] = [],
        createdNotes: [NoteID] = [],
        createdFolders: [String] = [],
        trashedNotes: [TrashedNote] = [],
        changedPaths: [NoteID: String] = [:],
        appliedAt: Date = Date()
    ) {
        self.eventID = eventID
        self.summary = summary
        self.outcomes = outcomes
        self.createdNotes = createdNotes
        self.createdFolders = createdFolders
        self.trashedNotes = trashedNotes
        self.changedPaths = changedPaths
        self.appliedAt = appliedAt
    }

    /// `true` when every action ran.
    public var isComplete: Bool { outcomes.allSatisfy { $0.status == .applied } }
}

/// A point in the apply where a test can inject a failure — the only way to
/// exercise NFR-3's "kill during apply" path without killing the process.
public enum ApplyStep: Sendable, Hashable, CustomStringConvertible {
    case createFolder(String)
    case createNote(index: Int, path: String)
    case appendToNote(index: Int, path: String)
    case removeSegment(index: Int, path: String)
    case trashEmptySource(index: Int, path: String)
    case retitleNote(index: Int, path: String)
    case moveNote(index: Int, path: String)
    case tagNote(index: Int, path: String)
    /// After every file operation, before the after-images are written.
    case beforeAfterImages
    /// After the after-images are durable, before the status flips to
    /// `applied`. A crash here is the one case recovery rolls *forward*.
    case beforeCommit

    public var description: String {
        switch self {
        case let .createFolder(path): "createFolder(\(path))"
        case let .createNote(index, path): "createNote(#\(index), \(path))"
        case let .appendToNote(index, path): "appendToNote(#\(index), \(path))"
        case let .removeSegment(index, path): "removeSegment(#\(index), \(path))"
        case let .trashEmptySource(index, path): "trashEmptySource(#\(index), \(path))"
        case let .retitleNote(index, path): "retitleNote(#\(index), \(path))"
        case let .moveNote(index, path): "moveNote(#\(index), \(path))"
        case let .tagNote(index, path): "tagNote(#\(index), \(path))"
        case .beforeAfterImages: "beforeAfterImages"
        case .beforeCommit: "beforeCommit"
        }
    }
}

/// Test seam: called before every file operation. Throw
/// ``ApplyError/simulatedCrash(_:)`` to model a power cut (no rollback, the
/// journal row stays `inProgress`), or any other error to model a failure the
/// applier must roll back from.
public struct ApplyFailureHook: Sendable {
    public let check: @Sendable (ApplyStep) throws -> Void

    public init(_ check: @escaping @Sendable (ApplyStep) throws -> Void) {
        self.check = check
    }

    /// Crashes at the first step that matches.
    public static func crash(at matches: @escaping @Sendable (ApplyStep) -> Bool) -> ApplyFailureHook {
        ApplyFailureHook { step in
            if matches(step) { throw ApplyError.simulatedCrash(step.description) }
        }
    }

    /// Fails (and so rolls back) at the first step that matches.
    public static func fail(at matches: @escaping @Sendable (ApplyStep) -> Bool) -> ApplyFailureHook {
        ApplyFailureHook { step in
            if matches(step) { throw ApplyError.injectedFailure(step.description) }
        }
    }
}

/// One durable line in the journal's progress list: something that *has*
/// happened to the filesystem.
///
/// Recovery reads these to undo work the before-images alone cannot describe —
/// chiefly "this file did not exist before the crash, so trash it".
public struct ApplyProgressEntry: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case createdFolder
        case createdNote
        case wrote
        case relocated
        case trashed
    }

    public var kind: Kind
    public var noteID: NoteID?
    public var path: String?
    public var previousPath: String?
    public var trashURL: String?
    public var step: String

    public init(
        kind: Kind,
        noteID: NoteID? = nil,
        path: String? = nil,
        previousPath: String? = nil,
        trashURL: String? = nil,
        step: String = ""
    ) {
        self.kind = kind
        self.noteID = noteID
        self.path = path
        self.previousPath = previousPath
        self.trashURL = trashURL
        self.step = step
    }
}

/// What ``PlanApplier/recoverIncompleteEvents()`` did with one journal row.
public struct RecoveryOutcome: Sendable, Hashable, Codable {
    public enum Resolution: String, Sendable, Hashable, Codable {
        /// Every after-image was already durable and matched the disk, so the
        /// event was simply marked applied.
        case rolledForward
        /// The before-images were restored; the plan counts as never applied.
        case rolledBack
        /// The rollback itself failed. The journal row says so and the detail
        /// names what could not be put back.
        case failed
    }

    public var eventID: ActivityEventID
    public var resolution: Resolution
    /// Paths restored from before-images.
    public var restoredPaths: [String]
    /// Library-relative paths trashed because the crashed apply had created
    /// them (or had left a file at an intermediate path).
    public var trashedPaths: [String]
    /// Where those files went — nothing is ever hard-deleted (FR-4.4).
    public var trashURLs: [String]
    public var detail: String

    public init(
        eventID: ActivityEventID,
        resolution: Resolution,
        restoredPaths: [String] = [],
        trashedPaths: [String] = [],
        trashURLs: [String] = [],
        detail: String = ""
    ) {
        self.eventID = eventID
        self.resolution = resolution
        self.restoredPaths = restoredPaths
        self.trashedPaths = trashedPaths
        self.trashURLs = trashURLs
        self.detail = detail
    }
}
