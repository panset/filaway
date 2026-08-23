import Foundation

/// Errors thrown by ``NoteStore`` and ``Library``.
public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No note or folder exists at the given relative path.
    case notFound(String)
    /// A note already exists where an exclusive write was requested.
    case alreadyExists(String)
    /// The relative path is not a `.md` file (DS-1: only Markdown is managed).
    case notAMarkdownFile(String)
    /// The folder path exceeds ``PathRules/maxFolderDepth``.
    case folderTooDeep(String)
    /// The path escaped the library root.
    case outsideLibrary(String)
    /// The file's bytes are not valid UTF-8.
    case notUTF8(String)
    /// Every collision suffix from 2…999 was taken.
    case couldNotFindFreeName(String)
    /// `trashItem` failed *and* the recovery bin fallback failed; nothing was deleted.
    case couldNotTrash(String, String)

    public var description: String {
        switch self {
        case let .notFound(path): "No note or folder at '\(path)'."
        case let .alreadyExists(path): "A file already exists at '\(path)'."
        case let .notAMarkdownFile(path): "'\(path)' is not a .md file."
        case let .folderTooDeep(path): "'\(path)' is deeper than \(PathRules.maxFolderDepth) folders."
        case let .outsideLibrary(path): "'\(path)' is outside the library root."
        case let .notUTF8(path): "'\(path)' is not valid UTF-8."
        case let .couldNotFindFreeName(path): "Could not find a free filename near '\(path)'."
        case let .couldNotTrash(path, reason): "Could not move '\(path)' to the Trash: \(reason)."
        }
    }
}
