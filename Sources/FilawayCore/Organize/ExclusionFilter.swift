import Foundation

/// FR-4.5 — folders the user excluded from AI processing. **Excluded content is
/// never sent to the provider**, so this filter sits between the library and
/// every prompt-building path, not inside the prompt builder where a future
/// caller could forget it.
///
/// The rule is prefix-matching on folder boundaries: excluding `"Private"`
/// excludes `Private/note.md` and `Private/Deep/note.md`, but not
/// `Private notes/note.md`.
public struct ExclusionFilter: Sendable, Equatable {
    /// Normalised, de-duplicated, root-relative folder paths.
    public let excludedFolders: [String]

    public init(excludedFolders: [String]) {
        var seen = Set<String>()
        var out: [String] = []
        for raw in excludedFolders {
            let path = PathRules.normalize(raw)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        self.excludedFolders = out.sorted()
    }

    /// Nothing excluded.
    public static let none = ExclusionFilter(excludedFolders: [])

    public var isEmpty: Bool { excludedFolders.isEmpty }

    /// `true` when a note path or folder path lies in (or *is*) an excluded
    /// folder.
    public func isExcluded(path: String) -> Bool {
        let normalized = PathRules.normalize(path)
        guard !normalized.isEmpty else { return false }
        for folder in excludedFolders {
            if normalized == folder || normalized.hasPrefix(folder + "/") { return true }
        }
        return false
    }

    public func isExcluded(_ note: NoteSummary) -> Bool {
        isExcluded(path: note.relativePath)
    }

    /// The notes that may be shown to the provider.
    public func allowed(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.filter { !isExcluded($0) }
    }

    /// The notes that must not be shown — useful for tests and for the Settings
    /// screen's "N notes excluded" line.
    public func excluded(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.filter { isExcluded($0) }
    }

    public func allowed(folderPaths: [String]) -> [String] {
        folderPaths.filter { !isExcluded(path: $0) }
    }

    /// Strips every excluded note and folder from a snapshot.
    public func filter(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        LibrarySnapshot(
            notes: allowed(snapshot.notes),
            folderPaths: allowed(folderPaths: snapshot.folderPaths),
            scannedAt: snapshot.scannedAt
        )
    }

    /// Strips excluded notes from a `NoteID`-keyed body map.
    public func filter(bodies: [NoteID: String], notes: [NoteSummary]) -> [NoteID: String] {
        let excludedIDs = Set(excluded(notes).map(\.id))
        return bodies.filter { !excludedIDs.contains($0.key) }
    }

    /// Belt-and-braces check for the tests: does any excluded note's text appear
    /// anywhere in an outgoing request body?
    ///
    /// This is a *test* aid, not a runtime gate — the gate is that excluded
    /// notes never enter ``OrganizeContext`` in the first place.
    public func leaks(in body: JSONValue, bodies: [NoteID: String], notes: [NoteSummary]) -> [String] {
        let haystack = body.allStrings.joined(separator: "\n")
        var found: [String] = []
        for note in excluded(notes) {
            if haystack.contains(note.title) { found.append(note.relativePath) }
            if let text = bodies[note.id], !text.isEmpty, haystack.contains(text) {
                found.append(note.relativePath)
            }
        }
        return found
    }
}
