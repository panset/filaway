import Foundation

/// What the editor reported (FR-3.1).
///
/// FR-3.1 ends a session only when there have been no keystrokes for the idle
/// interval **and** the note "is not frontmost-with-focus being actively
/// scrolled/selected" — so a session is kept alive by three different signals,
/// and only one of them is a text change.
///
/// `FilawayApp`'s `MarkdownTextView` already reports exactly these three
/// through `onEditorActivity`; this is the Core-side vocabulary the app feeds
/// into ``SessionTracker``, so the tracker never sees an AppKit type.
public enum EditorActivityKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A character-level change. Also arrives separately as
    /// ``SessionTracker/noteEdited(_:at:)`` — a keystroke both *starts* a
    /// session and *sustains* it, and only the edit path marks the note as
    /// touched.
    case keystroke
    /// Selection or caret movement.
    case selection
    /// Scrolling the note.
    case scroll

    /// `true` when the activity means the text changed.
    public var isEdit: Bool { self == .keystroke }
}

/// One editor activity report, timestamped by the app.
///
/// The app's own `EditorActivity` enum stays in `FilawayApp` (it is an AppKit
/// detail); this is the value that crosses into `FilawayCore`.
public struct EditorActivity: Sendable, Hashable, Codable {
    public var noteID: NoteID
    public var kind: EditorActivityKind
    public var at: Date

    public init(noteID: NoteID, kind: EditorActivityKind, at: Date) {
        self.noteID = noteID
        self.kind = kind
        self.at = at
    }
}
