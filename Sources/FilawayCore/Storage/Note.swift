import Foundation

/// Stable identity of a note (DS-2).
///
/// The value is written into the note's front-matter the first time Filaway
/// saves it, which is what makes external renames and moves recognisable as
/// *moves* rather than delete+create (DS-4), and what will let Phase 2 sync a
/// note across machines.
public struct NoteID: Hashable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
    public let rawValue: UUID

    public init() { rawValue = UUID() }
    public init(_ uuid: UUID) { rawValue = uuid }

    /// Parses a UUID string; `nil` if the text is not a UUID.
    public init?(_ description: String) {
        guard let uuid = UUID(uuidString: description.trimmingCharacters(in: .whitespaces)) else { return nil }
        rawValue = uuid
    }

    /// Uppercase RFC-4122 form, as written to front-matter and the database.
    public var uuidString: String { rawValue.uuidString }
    public var description: String { uuidString }

    /// Placeholder identity for a note that has no front-matter `id` yet.
    ///
    /// Derived from the relative path, so re-scanning an untouched file yields
    /// the same value twice — without that, every scan would look like a new
    /// note. It is deliberately *recomputable*: ``isDerived(fromRelativePath:)``
    /// tells the reconciler "this file has never been saved by Filaway, so the
    /// database's identity for this path wins".
    public static func derived(fromRelativePath path: String) -> NoteID {
        let digest = Hashing.sha256Hex("filaway.note.path:" + PathRules.normalize(path))
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = digest.startIndex
        for _ in 0 ..< 16 {
            let next = digest.index(index, offsetBy: 2)
            bytes.append(UInt8(digest[index ..< next], radix: 16) ?? 0)
            index = next
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // UUID version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return NoteID(UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }

    /// `true` when this identity was synthesised from `path` rather than read
    /// from the file's front-matter.
    public func isDerived(fromRelativePath path: String) -> Bool {
        self == Self.derived(fromRelativePath: path)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try UUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Everything Filaway knows about a note *without* reading its body.
///
/// Produced by ``NoteStore/scan(reusing:settleWindow:)`` and stored verbatim in
/// the `notes` table, so a scan and a database read are interchangeable.
public struct NoteSummary: Sendable, Equatable, Identifiable {
    public let id: NoteID
    /// `"Commands/curl.md"`, relative to the library root.
    public let relativePath: String
    /// Filename stem — DS-1 makes this the single source of truth for the title.
    public let title: String
    /// `""` for the library root, else `"Commands"` or `"Commands/Docker"`.
    public let folderPath: String
    public let tags: [String]
    /// Front-matter `created`, falling back to the file's creation date.
    public let created: Date
    /// File modification time (plan §1: "edited time = file mtime").
    public let modified: Date
    /// File size in bytes.
    public let size: Int
    /// Lowercase hex SHA-256 of the file's bytes, front-matter included.
    public let contentHash: String

    public init(
        id: NoteID,
        relativePath: String,
        title: String,
        folderPath: String,
        tags: [String],
        created: Date,
        modified: Date,
        size: Int,
        contentHash: String
    ) {
        self.id = id
        self.relativePath = relativePath
        self.title = title
        self.folderPath = folderPath
        self.tags = tags
        self.created = created
        self.modified = modified
        self.size = size
        self.contentHash = contentHash
    }
}

/// A note with its body loaded.
///
/// ``body`` is clean Markdown: the front-matter block has been stripped, and the
/// title is *not* repeated as an H1. The editor edits `body`; ``NoteStore`` puts
/// the front-matter back on save, preserving any keys it does not understand.
public struct Note: Sendable, Equatable, Identifiable {
    public var id: NoteID { summary.id }
    public var relativePath: String { summary.relativePath }
    public var title: String { summary.title }
    public var folderPath: String { summary.folderPath }
    public var tags: [String] { summary.tags }
    public var created: Date { summary.created }
    public var modified: Date { summary.modified }
    public var contentHash: String { summary.contentHash }

    public let summary: NoteSummary
    /// Markdown body without front-matter.
    public let body: String
    /// The parsed front-matter block, kept so unknown keys survive a save.
    public let frontMatter: FrontMatter?
    /// `true` when the file starts with a UTF-8 byte-order mark.
    public let hasByteOrderMark: Bool

    public init(summary: NoteSummary, body: String, frontMatter: FrontMatter?, hasByteOrderMark: Bool = false) {
        self.summary = summary
        self.body = body
        self.frontMatter = frontMatter
        self.hasByteOrderMark = hasByteOrderMark
    }
}

/// A node of the Library tree (FR-1.2).
public struct Folder: Sendable, Equatable, Identifiable {
    /// Relative path; `""` is the library root.
    public var id: String { path }
    public let path: String
    /// Last path component; `""` for the root.
    public let name: String
    /// Root is `0`, a top-level folder `1`, a subfolder `2`.
    public let depth: Int
    public var subfolders: [Folder]
    public var notes: [NoteSummary]

    public init(path: String, name: String, depth: Int, subfolders: [Folder] = [], notes: [NoteSummary] = []) {
        self.path = path
        self.name = name
        self.depth = depth
        self.subfolders = subfolders
        self.notes = notes
    }
}

/// The result of a full stat-scan of the library.
public struct LibrarySnapshot: Sendable, Equatable {
    /// Every `.md` file under the root, sorted by relative path.
    public let notes: [NoteSummary]
    /// Every folder under the root, sorted, excluding the root itself.
    public let folderPaths: [String]
    public let scannedAt: Date

    public init(notes: [NoteSummary], folderPaths: [String], scannedAt: Date) {
        self.notes = notes
        self.folderPaths = folderPaths
        self.scannedAt = scannedAt
    }

    /// Notes keyed by relative path.
    public var notesByPath: [String: NoteSummary] {
        Dictionary(notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    /// The Library tree the sidebar renders.
    public var tree: Folder { Folder.tree(notes: notes, folderPaths: folderPaths) }
}

public extension Folder {
    /// Builds the folder tree from a flat scan result.
    static func tree(notes: [NoteSummary], folderPaths: [String]) -> Folder {
        var childrenByParent: [String: [String]] = [:]
        var allPaths = Set(folderPaths.map(PathRules.normalize))
        // A note in a folder implies the folder, even if the scan missed it.
        for note in notes where !note.folderPath.isEmpty {
            var current = note.folderPath
            while !current.isEmpty {
                allPaths.insert(current)
                current = PathRules.parent(of: current) ?? ""
            }
        }
        for path in allPaths where !path.isEmpty {
            childrenByParent[PathRules.parent(of: path) ?? "", default: []].append(path)
        }

        var notesByFolder: [String: [NoteSummary]] = [:]
        for note in notes { notesByFolder[note.folderPath, default: []].append(note) }

        func build(_ path: String) -> Folder {
            let children = (childrenByParent[path] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map(build)
            let contents = (notesByFolder[path] ?? [])
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return Folder(
                path: path,
                name: PathRules.name(of: path),
                depth: PathRules.depth(ofFolder: path),
                subfolders: children,
                notes: contents
            )
        }
        return build("")
    }
}
