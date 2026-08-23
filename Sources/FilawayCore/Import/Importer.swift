import Foundation

/// One note an importer found and could bring in.
///
/// Deliberately narrow: FR-7.2 asks for titles and bodies, nothing else. A
/// candidate carries no identity of its own — the importer maps it onto a
/// relative path when it writes, and ``NoteStore`` assigns the `id`.
public struct ImportCandidate: Sendable, Hashable, Identifiable {
    public var id: String
    /// Title as the source app spelled it, before ``PathRules/sanitizeTitle(_:)``.
    public var title: String
    /// Markdown (or plain text) body.
    public var body: String
    /// Folder the source filed it under, mapped onto a Library folder path.
    /// `""` puts the note at the root.
    public var suggestedFolder: String
    /// Creation date, when the source knows one.
    public var created: Date?
    /// Last-modified date, when the source knows one.
    public var modified: Date?

    public init(
        id: String,
        title: String,
        body: String,
        suggestedFolder: String = "",
        created: Date? = nil,
        modified: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.suggestedFolder = suggestedFolder
        self.created = created
        self.modified = modified
    }
}

/// What an import run did. Returned rather than logged, so the caller decides
/// what the user sees.
public struct ImportReport: Sendable, Hashable {
    public var imported: [String]
    public var skipped: [String]
    public var failed: [String]

    public init(imported: [String] = [], skipped: [String] = [], failed: [String] = []) {
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
    }

    public var count: Int { imported.count }
}

/// Why an import could not run or could not finish.
public enum ImportError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The importer exists as a contract only — this build cannot run it.
    case notAvailableInThisVersion(String)
    /// The source app is not installed, or its data is not where it should be.
    case sourceUnavailable(String)
    /// macOS refused the automation or file access the importer needs.
    case permissionDenied(String)
    /// The source produced something the importer could not read.
    case unreadableSource(String)

    public var description: String {
        switch self {
        case let .notAvailableInThisVersion(detail): return detail
        case let .sourceUnavailable(detail): return "Source unavailable: \(detail)"
        case let .permissionDenied(detail): return "Permission denied: \(detail)"
        case let .unreadableSource(detail): return "Could not read the export: \(detail)"
        }
    }
}

/// Brings notes in from somewhere else (FR-7.2).
///
/// The protocol ships in Phase 1 even though no implementation does, because the
/// shape of the feature decides two things that are expensive to change later:
/// that an import is *discover then write* (so the user can be shown what is
/// about to happen before anything lands on disk), and that writing goes through
/// ``NoteStore`` like every other write — an import is not allowed its own file
/// format, its own front matter or its own collision rules.
///
/// ```swift
/// let importer = AppleNotesImporter()
/// let candidates = try await importer.discover()          // throws in Phase 1
/// let report = try await importer.importNotes(candidates, into: store) { done, total in … }
/// ```
public protocol NoteImporter: Sendable {
    /// Menu-item text: "Apple Notes…".
    var displayName: String { get }
    /// `true` when the source is present and the import could actually run.
    var isAvailable: Bool { get }
    /// Reads the source without writing anything.
    func discover() async throws -> [ImportCandidate]
    /// Writes the candidates through `store`.
    /// - Parameter progress: called with `(completed, total)` on an arbitrary
    ///   executor; hop to the main actor before touching UI.
    func importNotes(
        _ candidates: [ImportCandidate],
        into store: NoteStore,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ImportReport
}

public extension NoteImporter {
    var isAvailable: Bool { false }

    func importNotes(
        _ candidates: [ImportCandidate],
        into store: NoteStore
    ) async throws -> ImportReport {
        try await importNotes(candidates, into: store, progress: nil)
    }
}

/// FR-7.2, deferred to Phase 1.x (plan §1 amendment 8, ADR-039).
///
/// Every entry point throws ``ImportError/notAvailableInThisVersion(_:)`` with
/// the same sentence the disabled File → Import… menu item shows, so the string
/// the user reads is defined once, in Core, and the app never has to invent one.
///
/// The stub exists rather than the feature because the two credible routes into
/// Apple Notes — an AppleScript automation loop, and parsing a user-produced
/// export — both need entitlements, consent UI and an HTML-to-Markdown
/// conversion pass that is a milestone of its own, and neither is on the path to
/// the Phase 1 goal.
public struct AppleNotesImporter: NoteImporter {

    public init() {}

    public var displayName: String { "Apple Notes…" }

    /// Always `false` in Phase 1. The menu item reads this to stay disabled.
    public var isAvailable: Bool { false }

    /// The one sentence the menu item's tooltip and every thrown error share.
    public static let unavailableMessage =
        "Importing from Apple Notes arrives in a Phase 1.x update. "
        + "Until then, drag exported .md or .txt files into your notes folder — "
        + "Filaway picks them up immediately."

    public func discover() async throws -> [ImportCandidate] {
        throw ImportError.notAvailableInThisVersion(Self.unavailableMessage)
    }

    public func importNotes(
        _ candidates: [ImportCandidate],
        into store: NoteStore,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> ImportReport {
        throw ImportError.notAvailableInThisVersion(Self.unavailableMessage)
    }
}
