import Foundation

/// Something that happened to the library, as seen by ``LibraryWatcher`` (DS-4).
///
/// The stream carries only changes Filaway did *not* make itself: the store's
/// own writes are matched against its ``OwnOperation`` ledger and suppressed, so
/// a UI that already knows about its own save never sees an echo.
public enum LibraryChange: Sendable, Equatable {
    /// A `.md` file appeared that the database did not know about.
    case added(NoteSummary)
    /// A known file's bytes changed.
    case modified(NoteSummary)
    /// A known file is gone. `id` is the identity the database had for it.
    case removed(relativePath: String, id: NoteID?)
    /// A known note appeared at a new path — matched by front-matter `id`, or by
    /// content hash for notes Filaway has never saved.
    case moved(from: String, to: String, note: NoteSummary)
    /// An external edit landed on a note the editor had unsaved changes for.
    /// The in-app buffer stayed the file; the external bytes were preserved at
    /// ``externalCopyPath``, which also arrives as a separate ``added(_:)``.
    case conflict(noteID: NoteID, relativePath: String, externalCopyPath: String)
    case folderAdded(String)
    case folderRemoved(String)

    /// The relative path the change concerns.
    public var relativePath: String {
        switch self {
        case let .added(note), let .modified(note): note.relativePath
        case let .removed(path, _): path
        case let .moved(_, to, _): to
        case let .conflict(_, path, _): path
        case let .folderAdded(path), let .folderRemoved(path): path
        }
    }

    /// The note the change concerns, when the change carries one.
    public var note: NoteSummary? {
        switch self {
        case let .added(note), let .modified(note), let .moved(_, _, note): note
        default: nil
        }
    }
}

/// What ``LibraryWatcher/resolveExternalChange(noteID:inMemoryText:)`` did.
public struct ConflictResolution: Sendable, Equatable {
    /// The note as it now stands on disk — the in-app buffer, saved.
    public let note: NoteSummary
    /// `<Title> (external edit yyyy-MM-dd HHmm).md`, or `nil` when the external
    /// bytes matched the buffer and nothing had to be preserved.
    public let externalCopyPath: String?
    /// `true` when a conflict copy was written.
    public var didConflict: Bool { externalCopyPath != nil }

    public init(note: NoteSummary, externalCopyPath: String?) {
        self.note = note
        self.externalCopyPath = externalCopyPath
    }
}
