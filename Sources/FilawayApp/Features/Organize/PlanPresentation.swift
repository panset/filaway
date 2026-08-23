import FilawayCore
import SwiftUI

/// Plan actions in the words a person would use (FR-4.2: the card and its
/// sheets "always state exactly what happened or will happen").
///
/// Nothing here shows note *body* text beyond the first line of a moved
/// segment — the point of the Edit sheet is deciding where things go, not
/// re-reading what was written.
enum PlanPresentation {

    /// Every note the library knows, for resolving a ``NoteRef`` to a title.
    struct Library {
        var notes: [NoteSummary]
        /// Folder paths at depth ≤ 2, plus the root, as (path, label).
        var folders: [(path: String, label: String)]

        func note(_ ref: NoteRef) -> NoteSummary? {
            if let id = ref.id, let match = notes.first(where: { $0.id == id }) { return match }
            if let path = ref.path { return notes.first { $0.relativePath == path } }
            return nil
        }

        func title(_ ref: NoteRef) -> String { note(ref)?.title ?? ref.label }

        func title(of id: NoteID) -> String {
            notes.first { $0.id == id }?.title ?? "a note"
        }
    }

    static func symbol(for kind: PlanAction.Kind) -> String {
        switch kind {
        case .createNote: return "doc.badge.plus"
        case .appendToNote: return "text.append"
        case .createFolder: return "folder.badge.plus"
        case .moveNote: return "arrow.right.doc.on.clipboard"
        case .retitleNote: return "character.cursor.ibeam"
        case .tagNote: return "tag"
        case .moveSegment: return "arrow.turn.down.right"
        }
    }

    /// One sentence, present tense for a proposal.
    static func describe(_ action: PlanAction, in library: Library) -> String {
        switch action {
        case let .createNote(create):
            let folder = create.folderPath.isEmpty ? "the Library root" : create.folderPath
            return "Create “\(create.title)” in \(folder)"
        case let .appendToNote(append):
            let heading = append.heading.map { " under “\($0)”" } ?? ""
            return "Append to “\(library.title(append.target))”\(heading)"
        case let .createFolder(folder):
            return "Create the folder \(folder.path)"
        case let .moveNote(move):
            let folder = move.toFolderPath.isEmpty ? "the Library root" : move.toFolderPath
            return "Move “\(library.title(move.note))” to \(folder)"
        case let .retitleNote(retitle):
            return "Rename “\(library.title(retitle.note))” to “\(retitle.newTitle)”"
        case let .tagNote(tag):
            return "Tag “\(library.title(tag.note))” \(tag.tags.map { "#\($0)" }.joined(separator: " "))"
        case let .moveSegment(move):
            let destination: String
            switch move.destination {
            case let .existingNote(ref): destination = "“\(library.title(ref))”"
            case let .newNote(title, folderPath, _):
                destination = "a new note “\(title)”" + (folderPath.isEmpty ? "" : " in \(folderPath)")
            }
            return "Move a section out of “\(library.title(move.source))” into \(destination)"
        }
    }

    /// The first line of what a `moveSegment` or `appendToNote` carries, so the
    /// user can tell one section from another.
    static func detail(_ action: PlanAction) -> String? {
        let text: String?
        switch action {
        case let .moveSegment(move): text = move.segment
        case let .appendToNote(append): text = append.content
        case let .createNote(create): text = create.content
        default: text = nil
        }
        guard let firstLine = text?.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        return String(firstLine.prefix(80))
    }
}

/// Reads `SegmentDestination` without every caller writing the switch.
extension SegmentDestination {
    var existingNoteRef: NoteRef? {
        if case let .existingNote(ref) = self { return ref }
        return nil
    }
}
