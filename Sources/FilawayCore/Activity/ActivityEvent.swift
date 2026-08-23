import Foundation

/// Stable identity of an Activity event (FR-4.3).
///
/// The same value identifies the **apply journal** row, because the journal and
/// the Activity log are one table: an event exists from the moment before the
/// first file is touched, and its status says how far it got.
public struct ActivityEventID: Hashable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
    public let rawValue: UUID

    public init() { rawValue = UUID() }
    public init(_ uuid: UUID) { rawValue = uuid }

    public init?(_ description: String) {
        guard let uuid = UUID(uuidString: description.trimmingCharacters(in: .whitespaces)) else { return nil }
        rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { uuidString }

    public init(from decoder: Decoder) throws { rawValue = try UUID(from: decoder) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
}

/// What an Activity row *is*.
public enum ActivityEventKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// An organization plan the applier ran (FR-4.2, both modes).
    case applied
    /// The reversal of an ``applied`` event (FR-4.3).
    case undone
    /// A plan the user rejected in ask mode. Nothing touched the disk.
    case proposedDismissed
    /// A change Filaway recorded but did not make — reserved for external
    /// edits the app wants to show in the log.
    case external
}

/// How far an event got. This is the journal half of the row (NFR-3).
public enum ActivityEventStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// The journal row is written; files may be half-changed. A row left in
    /// this state is what ``PlanApplier/recoverIncompleteEvents()`` repairs.
    case inProgress
    /// Every operation finished and every after-image is durable.
    case applied
    /// The apply failed or crashed and the before-images were restored.
    case rolledBack
    /// The apply failed *and* the rollback could not finish. Never seen in
    /// practice; kept so recovery can say so rather than lie.
    case failed
    /// An ``applied`` event that Undo has since reversed.
    case undone
    /// Nothing was applied (a dismissed proposal).
    case none
}

/// One side of a note's before/after pair: the note's **raw file text**,
/// front-matter included, at the path it had at that moment.
///
/// Raw rather than body text on purpose — Undo restores it with
/// ``NoteStore/writeRaw(_:to:)``, which makes the restore byte-identical
/// (FR-4.3's "fully reversible"). The diff view strips front matter for display.
public struct NoteImageSide: Sendable, Hashable, Codable {
    public var relativePath: String
    public var text: String
    public var contentHash: String

    public init(relativePath: String, text: String, contentHash: String? = nil) {
        self.relativePath = relativePath
        self.text = text
        self.contentHash = contentHash ?? Hashing.sha256Hex(text)
    }
}

/// What an event did to one note.
///
/// * `before == nil` — the event created the note.
/// * `after == nil` — the event moved the note to the Trash (a `moveSegment`
///   that emptied its source, plan §1 amendment 1), or crashed before the
///   after-image was taken.
public struct NoteImage: Sendable, Hashable, Codable, Identifiable {
    public var noteID: NoteID
    /// Title at the time of the event, for the Activity list.
    public var title: String
    public var before: NoteImageSide?
    public var after: NoteImageSide?
    /// Where a trashed note went, so the user can find it in the Finder.
    public var trashedURL: String?
    /// `true` when this event brought the note into existence.
    public var created: Bool

    public var id: NoteID { noteID }

    public init(
        noteID: NoteID,
        title: String,
        before: NoteImageSide? = nil,
        after: NoteImageSide? = nil,
        trashedURL: String? = nil,
        created: Bool = false
    ) {
        self.noteID = noteID
        self.title = title
        self.before = before
        self.after = after
        self.trashedURL = trashedURL
        self.created = created
    }

    /// The path the note ended up at, or the one it started from.
    public var relativePath: String { after?.relativePath ?? before?.relativePath ?? "" }

    /// `true` when the event trashed the note.
    public var wasTrashed: Bool { after == nil && before != nil }
}

/// A cursor for newest-first paging. `(timestamp, id)` rather than a bare
/// timestamp so two events written in the same millisecond cannot hide each
/// other.
public struct ActivityCursor: Sendable, Hashable, Codable {
    public var timestamp: Date
    public var id: ActivityEventID

    public init(timestamp: Date, id: ActivityEventID) {
        self.timestamp = timestamp
        self.id = id
    }
}

/// One row of the Activity log (FR-4.3).
public struct ActivityEvent: Sendable, Hashable, Codable, Identifiable {
    public var id: ActivityEventID
    public var timestamp: Date
    public var kind: ActivityEventKind
    public var status: ActivityEventStatus
    /// The plan's one-sentence summary, or what Undo did.
    public var summary: String
    public var promptVersion: PromptVersion?
    public var model: String?
    /// The plan as the model produced it, for "View changes" and for recovery.
    public var plan: OrganizationPlan?
    /// Whether Undo will still take this event (FR-4.3 asks for ≥10 deep).
    public var isUndoable: Bool
    /// The undo event that reversed this one.
    public var undoneBy: ActivityEventID?
    /// Free-text note from recovery or a partial undo. Content-free (NFR-4).
    public var detail: String
    /// Before/after images. **Empty in list queries** — call
    /// ``ActivityLog/event(_:)`` or ``ActivityLog/images(for:)`` for a single
    /// event rather than dragging every note's text through a paged list.
    public var images: [NoteImage]
    /// How many notes the event touched, populated even in list queries.
    public var affectedNoteCount: Int
    /// `true` while the raw session text is still retained (FR-4.4, ≥30 days).
    public var hasSessionText: Bool

    public init(
        id: ActivityEventID,
        timestamp: Date,
        kind: ActivityEventKind,
        status: ActivityEventStatus,
        summary: String,
        promptVersion: PromptVersion? = nil,
        model: String? = nil,
        plan: OrganizationPlan? = nil,
        isUndoable: Bool = false,
        undoneBy: ActivityEventID? = nil,
        detail: String = "",
        images: [NoteImage] = [],
        affectedNoteCount: Int = 0,
        hasSessionText: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.status = status
        self.summary = summary
        self.promptVersion = promptVersion
        self.model = model
        self.plan = plan
        self.isUndoable = isUndoable
        self.undoneBy = undoneBy
        self.detail = detail
        self.images = images
        self.affectedNoteCount = affectedNoteCount
        self.hasSessionText = hasSessionText
    }

    public var cursor: ActivityCursor { ActivityCursor(timestamp: timestamp, id: id) }

    /// Note ids the event touched.
    public var noteIDs: Set<NoteID> { Set(images.map(\.noteID)) }
}

/// The before/after diff of one note in one event — what the Activity window's
/// diff view renders (FR-4.3).
public struct NoteDiff: Sendable, Hashable, Codable, Identifiable {
    public var noteID: NoteID
    public var title: String
    public var beforePath: String?
    public var afterPath: String?
    /// Line diff over the note's *body* (front matter stripped).
    public var diff: TextDiff
    /// `true` when the event created the note.
    public var created: Bool
    /// `true` when the event moved the note to the Trash.
    public var trashed: Bool

    public var id: NoteID { noteID }

    public init(
        noteID: NoteID,
        title: String,
        beforePath: String?,
        afterPath: String?,
        diff: TextDiff,
        created: Bool = false,
        trashed: Bool = false
    ) {
        self.noteID = noteID
        self.title = title
        self.beforePath = beforePath
        self.afterPath = afterPath
        self.diff = diff
        self.created = created
        self.trashed = trashed
    }

    /// `--- before` / `+++ after` unified text, for logs and for the pasteboard.
    public var unified: String {
        diff.unified(before: beforePath ?? "/dev/null", after: afterPath ?? "/dev/null")
    }

    /// `true` when the note was renamed or moved by the event.
    public var wasRelocated: Bool {
        guard let beforePath, let afterPath else { return false }
        return beforePath != afterPath
    }
}

// The organized baseline of a note (FR-3.2) is ``OrganizedBaseline``, and the
// store it lives in is ``BaselineStore`` — both in `Session/BaselineStore.swift`
// (ADR-033). ``ActivityLog`` and ``DatabaseBaselineStore`` implement that
// protocol over `note_baselines`.

/// What ``ActivityLog/prune(olderThan:now:keepingUndoDepth:)`` removed.
public struct ActivityPruneReport: Sendable, Hashable, Codable {
    /// Events whose raw session text was dropped (FR-4.4's 30-day floor).
    public var sessionTextsPruned: Int
    /// Events whose before/after images were dropped — only ever events Undo
    /// can no longer reach.
    public var eventsStrippedOfImages: Int

    public init(sessionTextsPruned: Int = 0, eventsStrippedOfImages: Int = 0) {
        self.sessionTextsPruned = sessionTextsPruned
        self.eventsStrippedOfImages = eventsStrippedOfImages
    }

    public var isEmpty: Bool { sessionTextsPruned == 0 && eventsStrippedOfImages == 0 }
}
