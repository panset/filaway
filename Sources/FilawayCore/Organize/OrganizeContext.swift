import Foundation

/// The library as the organizer sees it: what exists, what may be written to,
/// and what must never be mentioned to the provider (FR-4.5).
///
/// Built from a ``LibrarySnapshot`` (or a ``MetadataStore`` snapshot) *through*
/// ``ExclusionFilter``, so an excluded note is absent from ``notes`` entirely —
/// there is no path by which its text can reach a prompt. The excluded folder
/// paths themselves are kept, because the validator has to be able to say
/// "that target is inside an excluded folder" rather than "unknown folder".
public struct OrganizeContext: Sendable, Equatable {
    /// Every note the AI is allowed to know about.
    public var notes: [NoteSummary]
    /// Every folder the AI is allowed to write into, excluding the root (`""`).
    public var folderPaths: [String]
    /// Folders the user excluded from AI processing.
    public var excludedFolders: [String]
    /// Bodies of the notes in play, for verifying `moveSegment` segments.
    /// Only the session's notes need to be here; a missing body downgrades the
    /// verbatim check to a warning.
    public var bodies: [NoteID: String]

    public init(
        notes: [NoteSummary] = [],
        folderPaths: [String] = [],
        excludedFolders: [String] = [],
        bodies: [NoteID: String] = [:]
    ) {
        self.notes = notes
        self.folderPaths = folderPaths.map(PathRules.normalize).filter { !$0.isEmpty }
        self.excludedFolders = ExclusionFilter(excludedFolders: excludedFolders).excludedFolders
        self.bodies = bodies
    }

    /// Builds a context from a snapshot, stripping excluded content first.
    public init(
        snapshot: LibrarySnapshot,
        excludedFolders: [String] = [],
        bodies: [NoteID: String] = [:]
    ) {
        let filter = ExclusionFilter(excludedFolders: excludedFolders)
        let filtered = filter.filter(snapshot)
        self.init(
            notes: filtered.notes,
            folderPaths: filtered.folderPaths,
            excludedFolders: filter.excludedFolders,
            bodies: bodies.filter { id, _ in filtered.notes.contains { $0.id == id } }
        )
    }

    /// The exclusion rule for this context.
    public var exclusionFilter: ExclusionFilter { ExclusionFilter(excludedFolders: excludedFolders) }

    private var notesByID: [NoteID: NoteSummary] {
        Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var notesByPath: [String: NoteSummary] {
        Dictionary(notes.map { (PathRules.normalize($0.relativePath), $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func note(id: NoteID) -> NoteSummary? { notesByID[id] }

    public func note(path: String) -> NoteSummary? { notesByPath[PathRules.normalize(path)] }

    /// Resolves a plan's reference. `nil` means the model named something that
    /// does not exist — a hallucinated id or path (risk #6).
    public func note(for ref: NoteRef) -> NoteSummary? {
        if let id = ref.id, let note = notesByID[id] { return note }
        if let path = ref.path, let note = notesByPath[PathRules.normalize(path)] { return note }
        return nil
    }

    /// `true` when both halves of a reference resolve to *different* notes.
    public func referenceIsContradictory(_ ref: NoteRef) -> Bool {
        guard let id = ref.id, let path = ref.path, !path.isEmpty else { return false }
        guard let byID = notesByID[id], let byPath = notesByPath[PathRules.normalize(path)] else { return false }
        return byID.id != byPath.id
    }

    public func folderExists(_ path: String) -> Bool {
        let normalized = PathRules.normalize(path)
        return normalized.isEmpty || folderPaths.contains(normalized)
    }

    public func isExcluded(_ path: String) -> Bool {
        exclusionFilter.isExcluded(path: path)
    }

    /// The note at `folder/title.md`, if one already exists — a create that
    /// lands here would overwrite user text and must be rejected.
    public func note(inFolder folder: String, title: String) -> NoteSummary? {
        note(path: PathRules.relativePath(folder: folder, title: title))
    }

    /// Preconditions for every note a plan touches (FR-3.2 CAS).
    public func preconditions(for plan: OrganizationPlan) -> PlanPreconditions {
        preconditions(forActions: plan.actions)
    }

    public func preconditions(forActions actions: [PlanAction]) -> PlanPreconditions {
        var out = PlanPreconditions()
        for ref in actions.flatMap(\.referencedNotes) {
            guard let note = note(for: ref) else { continue }
            out[note.id] = note.contentHash
        }
        return out
    }
}
