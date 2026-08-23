import Foundation

/// How completely an undo put things back.
public enum UndoOutcome: String, Sendable, Hashable, Codable {
    /// Every affected note is byte-identical to its before-image.
    case complete
    /// At least one note had been edited in a way the reverse patch could not
    /// unpick, so the recovered text was appended under a conflict marker
    /// instead of replacing the user's edit (FR-4.4).
    case partial
}

/// What an undo did to one note.
public struct NoteUndoOutcome: Sendable, Hashable, Codable, Identifiable {
    public enum Action: String, Sendable, Hashable, Codable {
        /// The note was untouched since the apply, so the before-image went
        /// back byte-for-byte.
        case restored
        /// The note had moved on; the reverse patch was replayed onto it.
        case patched
        /// Some of the patch would not land: the user's text was kept and the
        /// recovered text appended under "Restored by Undo (conflict)".
        case conflicted
        /// A note the plan created was moved to the Trash.
        case trashed
        /// A note the plan trashed was written back.
        case recreated
        /// Nothing to do — the note was already in its before state.
        case unchanged
    }

    public var noteID: NoteID
    public var action: Action
    public var relativePath: String
    public var previousPath: String?
    /// Where a trashed note went.
    public var trashURL: String?
    public var detail: String

    public var id: NoteID { noteID }

    public init(
        noteID: NoteID,
        action: Action,
        relativePath: String,
        previousPath: String? = nil,
        trashURL: String? = nil,
        detail: String = ""
    ) {
        self.noteID = noteID
        self.action = action
        self.relativePath = relativePath
        self.previousPath = previousPath
        self.trashURL = trashURL
        self.detail = detail
    }
}

/// The result of one undo.
public struct UndoResult: Sendable, Hashable, Codable, Identifiable {
    /// The event that was reversed.
    public var eventID: ActivityEventID
    /// The Activity event the undo itself recorded.
    public var undoEventID: ActivityEventID
    public var outcome: UndoOutcome
    public var notes: [NoteUndoOutcome]
    public var summary: String

    public var id: ActivityEventID { undoEventID }

    public init(
        eventID: ActivityEventID,
        undoEventID: ActivityEventID,
        outcome: UndoOutcome,
        notes: [NoteUndoOutcome],
        summary: String
    ) {
        self.eventID = eventID
        self.undoEventID = undoEventID
        self.outcome = outcome
        self.notes = notes
        self.summary = summary
    }
}

/// Why an undo refused.
public enum UndoError: Error, Equatable, Sendable, CustomStringConvertible {
    case nothingToUndo
    case unknownEvent(ActivityEventID)
    /// The event was never applied, was already undone, or its images have been
    /// pruned.
    case notUndoable(ActivityEventID)
    /// A later organization event touched one of the same notes. Undo is LIFO:
    /// reverse that one first. The associated id is the *blocking* event.
    case blockedByLaterEvent(ActivityEventID)

    public var description: String {
        switch self {
        case .nothingToUndo: "There is nothing to undo."
        case let .unknownEvent(id): "No Activity event \(id)."
        case let .notUndoable(id): "Activity event \(id) can no longer be undone."
        case let .blockedByLaterEvent(id): "A later organization event (\(id)) touched the same notes; undo that first."
        }
    }
}

/// Undo for applied organization plans (M2-08; FR-4.3, FR-4.4).
///
/// The rules, in the order they are applied to each affected note:
///
/// 1. **Untouched since the apply** — the current file still hashes to the
///    after-image — the before-image is written back verbatim, so the file is
///    byte-identical to what it was before the AI saw it.
/// 2. **Edited since** — the reverse patch (a line diff from after back to
///    before) is replayed onto the *current* text, so the user's edit survives.
/// 3. **A hunk will not land** — nothing is dropped: the user's text stays and
///    the text the patch was carrying is appended under a
///    "Restored by Undo (conflict)" heading. The outcome is ``UndoOutcome/partial``.
///
/// Creates become Trash, a trashed empty source is written back, and a move or
/// retitle is reversed by moving the file back. Undo records its own Activity
/// event and marks the original non-undoable — redo is out of scope for Phase 1.
///
/// Ordering is **LIFO**: an event whose notes a *later* organization event also
/// touched is refused with ``UndoError/blockedByLaterEvent(_:)`` rather than
/// silently clobbering the later change. Undo events themselves never block, or
/// a ten-deep unwind would stop after its first step.
public actor UndoService {
    private let store: NoteStore
    private let activity: ActivityLog
    private let clock: @Sendable () -> Date
    private let fileManager = FileManager.default
    private let log = Log.make("organize")

    public init(
        store: NoteStore,
        activity: ActivityLog,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.activity = activity
        self.clock = clock
    }

    /// The applied events Undo can still reach, newest first (FR-4.3: ≥10).
    public func undoableEvents(limit: Int = ActivityLog.undoDepth) async throws -> [ActivityEvent] {
        try await activity.undoableEvents(limit: limit)
    }

    /// Reverses the most recent applied organization event.
    @discardableResult
    public func undoLatest() async throws -> UndoResult {
        guard let event = try await activity.undoableEvents(limit: 1).first else { throw UndoError.nothingToUndo }
        return try await undo(event.id)
    }

    /// Reverses one event by id.
    @discardableResult
    public func undo(_ eventID: ActivityEventID) async throws -> UndoResult {
        guard let event = try await activity.event(eventID) else { throw UndoError.unknownEvent(eventID) }
        guard event.kind == .applied, event.status == .applied, event.isUndoable, !event.images.isEmpty else {
            throw UndoError.notUndoable(eventID)
        }
        if let blocking = try await activity.laterEvent(touching: event.noteIDs, after: event) {
            throw UndoError.blockedByLaterEvent(blocking.id)
        }

        var notes: [NoteUndoOutcome] = []
        var images: [NoteImage] = []
        var outcome = UndoOutcome.complete

        for image in event.images {
            let (note, undoImage) = try await reverse(image)
            notes.append(note)
            images.append(undoImage)
            if note.action == .conflicted { outcome = .partial }
        }

        let summary = Self.summarize(notes, original: event.summary)
        let undoEventID = try await activity.recordUndo(
            of: eventID,
            summary: summary,
            images: images,
            outcome: outcome.rawValue,
            detail: notes.filter { $0.action == .conflicted }.map(\.detail).joined(separator: "; "),
            at: clock()
        )
        log.info("undid event: \(notes.count, privacy: .public) note(s), outcome \(outcome.rawValue, privacy: .public)")
        return UndoResult(
            eventID: eventID,
            undoEventID: undoEventID,
            outcome: outcome,
            notes: notes,
            summary: summary
        )
    }

    // MARK: - One note

    private func reverse(_ image: NoteImage) async throws -> (NoteUndoOutcome, NoteImage) {
        let currentPath = try await locate(image)
        let currentText = currentPath.flatMap { try? rawText(at: $0) }
        let currentSide = currentPath.map { NoteImageSide(relativePath: $0, text: currentText ?? "") }

        // A note the event created: to the Trash, never a hard delete. Its
        // current text rides along in the undo event's before-image, so even a
        // note the user edited after the apply is recoverable from the log.
        guard let before = image.before else {
            guard let currentPath else {
                return (
                    NoteUndoOutcome(noteID: image.noteID, action: .unchanged, relativePath: image.relativePath,
                                    detail: "The created note was already gone"),
                    NoteImage(noteID: image.noteID, title: image.title, before: nil, after: nil)
                )
            }
            let url = try await store.deleteNote(currentPath)
            return (
                NoteUndoOutcome(noteID: image.noteID, action: .trashed, relativePath: currentPath,
                                trashURL: url.path, detail: "Moved \(currentPath) to the Trash"),
                NoteImage(noteID: image.noteID, title: image.title, before: currentSide, after: nil,
                          trashedURL: url.path)
            )
        }

        // A note the event trashed (an emptied `moveSegment` source): write it
        // back where it was.
        guard let currentPath, let currentText else {
            let summary = try await store.writeRaw(before.text, to: freePath(before.relativePath))
            return (
                NoteUndoOutcome(noteID: image.noteID, action: .recreated, relativePath: summary.relativePath,
                                detail: "Restored \(summary.relativePath)"),
                NoteImage(noteID: image.noteID, title: image.title, before: nil,
                          after: NoteImageSide(relativePath: summary.relativePath, text: before.text))
            )
        }

        // Reverse the move or retitle first, so the text lands at the path the
        // before-image names.
        var path = currentPath
        var previousPath: String?
        if path != before.relativePath {
            path = try await relocate(path, to: before.relativePath)
            previousPath = currentPath
        }

        let after = image.after
        // The third case is a *retry*: an Undo the process died half-way
        // through leaves some notes already restored, and a second attempt must
        // call those done rather than run the reverse patch over text that is
        // already the before-image and report a conflict (M4-08).
        if after == nil || Hashing.sha256Hex(currentText) == after?.contentHash || currentText == before.text {
            // Untouched since the apply — byte-identical restore.
            _ = try await store.writeRaw(before.text, to: path)
            return (
                NoteUndoOutcome(noteID: image.noteID, action: .restored, relativePath: path,
                                previousPath: previousPath, detail: "Restored \(path)"),
                NoteImage(noteID: image.noteID, title: image.title, before: currentSide,
                          after: NoteImageSide(relativePath: path, text: before.text))
            )
        }

        // Edited since: replay the reverse patch onto what is there now.
        let reversePatch = TextDiff.between(after?.text ?? "", before.text)
        let patched = reversePatch.apply(to: currentText)
        var text = patched.text
        var action = NoteUndoOutcome.Action.patched
        var detail = "Re-applied \(patched.appliedHunks.count) change(s) to \(path)"
        if !patched.isComplete {
            action = .conflicted
            let recovered = patched.unrecoveredLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !recovered.isEmpty {
                text = ApplyText.appendingConflictBlock(recovered, to: text)
            }
            detail = "\(patched.failedHunks.count) change(s) in \(path) had been edited; "
                + (recovered.isEmpty ? "the note was left as the user wrote it" : "the recovered text was appended")
        }
        _ = try await store.writeRaw(text, to: path)
        return (
            NoteUndoOutcome(noteID: image.noteID, action: action, relativePath: path,
                            previousPath: previousPath, detail: detail),
            NoteImage(noteID: image.noteID, title: image.title, before: currentSide,
                      after: NoteImageSide(relativePath: path, text: text))
        )
    }

    /// Where the note is *now*: at the path the event left it, or wherever a
    /// rename since has taken it.
    private func locate(_ image: NoteImage) async throws -> String? {
        for candidate in [image.after?.relativePath, image.before?.relativePath].compactMap({ $0 }) {
            if fileManager.fileExists(atPath: url(candidate).path) { return candidate }
        }
        let snapshot = try await store.scan()
        return snapshot.notes.first { $0.id == image.noteID }?.relativePath
    }

    /// Moves a file back to (as close as possible to) the path it had, using
    /// ``NoteStore``'s move and rename so nothing is written twice.
    private func relocate(_ path: String, to target: String) async throws -> String {
        var current = path
        let folder = PathRules.folderPath(of: target)
        if PathRules.folderPath(of: current) != folder {
            try await store.createFolder(folder)
            current = try await store.move(current, toFolder: folder).relativePath
        }
        if PathRules.title(of: current) != PathRules.title(of: target) {
            current = try await store.rename(current, to: PathRules.title(of: target)).relativePath
        }
        return current
    }

    private func freePath(_ preferred: String) async throws -> String {
        guard fileManager.fileExists(atPath: url(preferred).path) else { return preferred }
        return try await store.freeRelativePath(
            folder: PathRules.folderPath(of: preferred),
            title: PathRules.title(of: preferred)
        )
    }

    private func url(_ relativePath: String) -> URL { store.library.url(for: relativePath) }

    private func rawText(at relativePath: String) throws -> String {
        guard let data = fileManager.contents(atPath: url(relativePath).path) else {
            throw ApplyError.noteMissing(relativePath)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw StorageError.notUTF8(relativePath) }
        return text
    }

    static func summarize(_ notes: [NoteUndoOutcome], original: String) -> String {
        guard !notes.isEmpty else { return "Undid: \(original)" }
        let conflicts = notes.filter { $0.action == .conflicted }
        let head = "Undid \(notes.count) note change\(notes.count == 1 ? "" : "s")"
        guard !conflicts.isEmpty else { return head + "." }
        return head + ", \(conflicts.count) with a conflict block."
    }
}
