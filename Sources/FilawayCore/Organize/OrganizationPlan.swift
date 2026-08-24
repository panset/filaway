import Foundation

/// How a plan names an existing note.
///
/// The model is given note ids, so ``id`` is the normal case; ``path`` is
/// accepted because a model that has just been shown a library tree will
/// sometimes answer with `"Commands/curl.md"`. Both may be present, in which
/// case ``PlanValidator`` insists they agree.
public struct NoteRef: Sendable, Hashable, Codable {
    public var id: NoteID?
    /// Relative path, e.g. `"Commands/curl.md"`.
    public var path: String?

    public init(id: NoteID? = nil, path: String? = nil) {
        self.id = id
        self.path = path
    }

    public static func id(_ id: NoteID) -> NoteRef { NoteRef(id: id) }
    public static func path(_ path: String) -> NoteRef { NoteRef(path: path) }

    /// `true` when the reference names nothing at all.
    public var isEmpty: Bool { id == nil && (path?.isEmpty ?? true) }

    /// Content-free description for issue messages.
    public var label: String {
        if let path, !path.isEmpty { return path }
        if let id { return id.uuidString }
        return "<empty reference>"
    }
}

/// Advisory character offsets into the source note, when the model supplies
/// them. Apply never trusts them: ``PlanAction/moveSegment(_:)`` carries the
/// segment text verbatim and the applier locates it by search.
public struct PlanTextRange: Sendable, Hashable, Codable {
    public var start: Int
    public var length: Int

    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

// MARK: - Action payloads

public struct CreateNoteAction: Sendable, Hashable, Codable {
    public var title: String
    /// `""` for the library root.
    public var folderPath: String
    public var content: String
    public var tags: [String]

    public init(title: String, folderPath: String = "", content: String, tags: [String] = []) {
        self.title = title
        self.folderPath = folderPath
        self.content = content
        self.tags = tags
    }
}

/// FR-4.4's additive merge: text is *appended*, under a divider or a heading.
public struct AppendToNoteAction: Sendable, Hashable, Codable {
    public var target: NoteRef
    public var content: String
    /// Heading inserted above the appended block, without leading `#`s.
    public var heading: String?
    /// Whether to write a `---` rule before the block. Defaults to `true`.
    public var divider: Bool?

    public init(target: NoteRef, content: String, heading: String? = nil, divider: Bool? = nil) {
        self.target = target
        self.content = content
        self.heading = heading
        self.divider = divider
    }
}

public struct CreateFolderAction: Sendable, Hashable, Codable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct MoveNoteAction: Sendable, Hashable, Codable {
    public var note: NoteRef
    public var toFolderPath: String

    public init(note: NoteRef, toFolderPath: String) {
        self.note = note
        self.toFolderPath = toFolderPath
    }
}

public struct RetitleNoteAction: Sendable, Hashable, Codable {
    public var note: NoteRef
    public var newTitle: String

    public init(note: NoteRef, newTitle: String) {
        self.note = note
        self.newTitle = newTitle
    }
}

public struct TagNoteAction: Sendable, Hashable, Codable {
    public var note: NoteRef
    /// Tags to **add**. Removing a tag is not representable (FR-4.4).
    public var tags: [String]

    public init(note: NoteRef, tags: [String]) {
        self.note = note
        self.tags = tags
    }
}

/// Where a moved segment lands.
public enum SegmentDestination: Sendable, Hashable, Codable {
    case existingNote(NoteRef)
    case newNote(title: String, folderPath: String, tags: [String])

    private enum CodingKeys: String, CodingKey {
        case kind, note, title, folderPath, tags
    }

    private enum Kind: String, Codable {
        case existingNote, newNote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .existingNote:
            self = .existingNote(try container.decode(NoteRef.self, forKey: .note))
        case .newNote:
            self = .newNote(
                title: try container.decode(String.self, forKey: .title),
                folderPath: try container.decodeIfPresent(String.self, forKey: .folderPath) ?? "",
                tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .existingNote(ref):
            try container.encode(Kind.existingNote, forKey: .kind)
            try container.encode(ref, forKey: .note)
        case let .newNote(title, folderPath, tags):
            try container.encode(Kind.newNote, forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(folderPath, forKey: .folderPath)
            try container.encode(tags, forKey: .tags)
        }
    }
}

/// Plan §1 amendment 1 — **merge = move segment**.
///
/// FR-4.1 asks for "append/merge session content into an existing note" while
/// FR-4.4 forbids deleting user content. The resolution: a segment leaves the
/// source and arrives at the target *in one undoable event*, and the exact
/// segment text travels with the action so apply can verify it still exists
/// verbatim before touching anything (and skip the whole plan if it does not).
/// A source note left empty goes to the macOS Trash, never a hard delete.
public struct MoveSegmentAction: Sendable, Hashable, Codable {
    public var source: NoteRef
    /// The segment, byte-for-byte as it appears in the source note.
    public var segment: String
    /// Optional SHA-256 of ``segment``; when present it must match.
    public var segmentHash: String?
    /// Advisory offsets — see ``PlanTextRange``.
    public var sourceRange: PlanTextRange?
    public var destination: SegmentDestination
    public var heading: String?
    public var divider: Bool?

    public init(
        source: NoteRef,
        segment: String,
        segmentHash: String? = nil,
        sourceRange: PlanTextRange? = nil,
        destination: SegmentDestination,
        heading: String? = nil,
        divider: Bool? = nil
    ) {
        self.source = source
        self.segment = segment
        self.segmentHash = segmentHash
        self.sourceRange = sourceRange
        self.destination = destination
        self.heading = heading
        self.divider = divider
    }

    /// The hash the applier expects, computed if the model did not send one.
    public var expectedSegmentHash: String { segmentHash ?? Hashing.sha256Hex(segment) }
}

// MARK: - The closed action set

/// FR-4.1's **closed** action set, plus amendment 1's segment move.
///
/// Nothing here can delete or overwrite user text, and that is a property of the
/// *type*, not of the validator: there is no `deleteNote`, no `replaceContent`,
/// no `setBody`. ``neverDeletesUserText`` switches exhaustively over every case
/// so that adding a destructive one cannot compile without someone deciding it
/// on purpose.
public enum PlanAction: Sendable, Hashable, Codable {
    case createNote(CreateNoteAction)
    case appendToNote(AppendToNoteAction)
    case createFolder(CreateFolderAction)
    case moveNote(MoveNoteAction)
    case retitleNote(RetitleNoteAction)
    case tagNote(TagNoteAction)
    case moveSegment(MoveSegmentAction)

    /// The `action` discriminator, and the `enum` in the tool schema.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case createNote
        case appendToNote
        case createFolder
        case moveNote
        case retitleNote
        case tagNote
        case moveSegment
    }

    public var kind: Kind {
        switch self {
        case .createNote: return .createNote
        case .appendToNote: return .appendToNote
        case .createFolder: return .createFolder
        case .moveNote: return .moveNote
        case .retitleNote: return .retitleNote
        case .tagNote: return .tagNote
        case .moveSegment: return .moveSegment
        }
    }

    /// FR-4.4, asserted by construction.
    ///
    /// Every case is additive: it creates something new, appends to something
    /// that keeps everything it already had, renames a file, changes metadata,
    /// or moves a segment whose text is carried verbatim so nothing is lost.
    public var neverDeletesUserText: Bool {
        switch self {
        case .createNote: return true       // new file
        case .appendToNote: return true     // append-only
        case .createFolder: return true     // new directory
        case .moveNote: return true         // same bytes, new path
        case .retitleNote: return true      // same bytes, new filename
        case .tagNote: return true          // front-matter only, additive
        case .moveSegment: return true       // text travels with the action
        }
    }

    /// Existing notes the action reads or mutates — the set that needs CAS
    /// preconditions in M2-07.
    public var referencedNotes: [NoteRef] {
        switch self {
        case .createNote, .createFolder:
            return []
        case let .appendToNote(action):
            return [action.target]
        case let .moveNote(action):
            return [action.note]
        case let .retitleNote(action):
            return [action.note]
        case let .tagNote(action):
            return [action.note]
        case let .moveSegment(action):
            if case let .existingNote(ref) = action.destination { return [action.source, ref] }
            return [action.source]
        }
    }

    /// Folders the action writes into — checked against the exclusion list and
    /// the depth cap.
    public var targetFolderPaths: [String] {
        switch self {
        case let .createNote(action):
            return [action.folderPath]
        case let .createFolder(action):
            return [action.path]
        case let .moveNote(action):
            return [action.toFolderPath]
        case let .moveSegment(action):
            if case let .newNote(_, folderPath, _) = action.destination { return [folderPath] }
            return []
        case .appendToNote, .retitleNote, .tagNote:
            return []
        }
    }

    /// Notes the action brings into existence, as `(folderPath, title)`.
    public var createdNotes: [(folderPath: String, title: String)] {
        switch self {
        case let .createNote(action):
            return [(action.folderPath, action.title)]
        case let .moveSegment(action):
            if case let .newNote(title, folderPath, _) = action.destination { return [(folderPath, title)] }
            return []
        default:
            return []
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .action) {
        case .createNote: self = .createNote(try CreateNoteAction(from: decoder))
        case .appendToNote: self = .appendToNote(try AppendToNoteAction(from: decoder))
        case .createFolder: self = .createFolder(try CreateFolderAction(from: decoder))
        case .moveNote: self = .moveNote(try MoveNoteAction(from: decoder))
        case .retitleNote: self = .retitleNote(try RetitleNoteAction(from: decoder))
        case .tagNote: self = .tagNote(try TagNoteAction(from: decoder))
        case .moveSegment: self = .moveSegment(try MoveSegmentAction(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .createNote(action): try action.encode(to: encoder)
        case let .appendToNote(action): try action.encode(to: encoder)
        case let .createFolder(action): try action.encode(to: encoder)
        case let .moveNote(action): try action.encode(to: encoder)
        case let .retitleNote(action): try action.encode(to: encoder)
        case let .tagNote(action): try action.encode(to: encoder)
        case let .moveSegment(action): try action.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .action)
    }
}

// MARK: - Preconditions

/// Per-note compare-and-swap preconditions (FR-3.2, applied in M2-07).
///
/// The plan was computed against these content hashes. If a note's hash has
/// moved by the time the plan is applied — the user kept typing — the whole
/// plan is discarded rather than partially applied.
public struct PlanPreconditions: Sendable, Hashable, Codable, ExpressibleByDictionaryLiteral {
    public private(set) var contentHashes: [NoteID: String]

    public init(_ contentHashes: [NoteID: String] = [:]) {
        self.contentHashes = contentHashes
    }

    public init(dictionaryLiteral elements: (NoteID, String)...) {
        contentHashes = Dictionary(elements, uniquingKeysWith: { _, latest in latest })
    }

    /// Preconditions for every note the plan touches, taken from a snapshot.
    public init(notes: [NoteSummary]) {
        contentHashes = Dictionary(notes.map { ($0.id, $0.contentHash) }, uniquingKeysWith: { _, latest in latest })
    }

    public subscript(id: NoteID) -> String? {
        get { contentHashes[id] }
        set { contentHashes[id] = newValue }
    }

    public var isEmpty: Bool { contentHashes.isEmpty }
    public var noteIDs: Set<NoteID> { Set(contentHashes.keys) }

    // Encoded as `{"<uuid>": "<hash>"}` — a plain dictionary keyed by NoteID
    // would otherwise become an alternating array in JSON.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        var out: [NoteID: String] = [:]
        for (key, value) in raw {
            guard let id = NoteID(key) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "\(key) is not a note id"
                )
            }
            out[id] = value
        }
        contentHashes = out
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(
            contentHashes.map { ($0.key.uuidString, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        ))
    }
}

// MARK: - The plan

/// What the AI proposes to do with a session (FR-4.1).
///
/// The model produces ``summary`` and ``actions`` — that is exactly the tool
/// schema. ``promptVersion``, ``model`` and ``preconditions`` are attached by
/// the caller, because they describe *how* the plan was made and *what it was
/// made against*, which the model cannot be trusted to report.
public struct OrganizationPlan: Sendable, Hashable, Codable {
    /// Plain-language sentence for the organization card ("Merge code block
    /// into Commands/curl?"). Never contains Markdown.
    public var summary: String
    public var actions: [PlanAction]
    public var preconditions: PlanPreconditions
    public var promptVersion: PromptVersion
    /// The model id that produced the plan.
    public var model: String

    public init(
        summary: String,
        actions: [PlanAction],
        preconditions: PlanPreconditions = PlanPreconditions(),
        promptVersion: PromptVersion = .organize,
        model: String = AIModel.defaultOrganize.id
    ) {
        self.summary = summary
        self.actions = actions
        self.preconditions = preconditions
        self.promptVersion = promptVersion
        self.model = model
    }

    /// A plan with nothing to do is a perfectly good answer (FR-4.6: prefer
    /// leaving the taxonomy alone over inventing structure).
    public var isEmpty: Bool { actions.isEmpty }

    /// Every note the plan touches.
    public var referencedNotes: [NoteRef] { actions.flatMap(\.referencedNotes) }

    /// FR-4.4, restated for callers that want to assert it before applying.
    public var neverDeletesUserText: Bool { actions.allSatisfy(\.neverDeletesUserText) }

    /// The name of the strict tool the model must call.
    public static let toolName = "organization_plan"

    /// The tool definition to send with an organize request.
    public static var tool: AITool {
        AITool(
            name: toolName,
            description: """
            Report the organization plan for this writing session. Use zero or more actions from the \
            closed set; an empty list means nothing needs filing. Never propose deleting or replacing \
            existing text — the only ways to change a note are appending to it, moving a segment out of \
            it, renaming it, moving it, or adding tags.
            """,
            inputSchema: toolSchema,
            strict: true
        )
    }
}
