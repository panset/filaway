import Foundation

/// What can be wrong (or merely odd) about a plan.
///
/// Kinds are split by *severity at the emit site*, not here: everything in
/// ``PlanValidation/errors`` blocks the plan, everything in
/// ``PlanValidation/warnings`` is shown on the card or logged.
public enum PlanIssueKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// The plan names a note that does not exist (or was excluded).
    case unknownNote
    /// A reference whose id and path point at different notes.
    case contradictoryReference
    /// A reference with neither an id nor a path.
    case emptyReference
    /// A target folder that neither exists nor is created by this plan.
    case unknownFolder
    /// Deeper than `PathRules.maxFolderDepth`.
    case folderTooDeep
    /// A target inside a folder the user excluded from AI processing (FR-4.5).
    case excludedTarget
    /// A source note inside an excluded folder — it should never have been sent.
    case excludedSource
    /// Absolute path, `..`, or a component that is not filesystem-safe.
    case unsafePath
    /// A title that is empty or would be rewritten by `PathRules.sanitizeTitle`.
    case unsafeTitle
    /// A create or retitle that would land on an existing note's path — the one
    /// way a plan could overwrite user text (FR-4.4).
    case titleCollision
    /// The same action twice.
    case duplicateAction
    /// Two actions that cannot both happen (two different new folders for one
    /// note, two different titles, …).
    case contradictoryAction
    /// An append or create with nothing to write.
    case emptyContent
    /// `moveSegment` with an empty segment.
    case emptySegment
    /// The segment is not in the source note verbatim.
    case segmentNotFound
    /// `segmentHash` does not match `segment`.
    case segmentHashMismatch
    /// The source note's text was not available, so the segment could not be
    /// verified here — apply will verify it again before writing.
    case segmentUnverified
    /// A note is touched without a CAS precondition (FR-3.2).
    case missingPrecondition
    /// The precondition no longer matches the note on disk.
    case stalePrecondition
    /// An empty or whitespace-only tag.
    case invalidTag
    /// More actions than a session plausibly needs — a runaway model (risk #6).
    case tooManyActions
    /// The action changes nothing.
    case noOp
    /// The folder already exists.
    case folderExists
    /// The decoder could not read one of the model's actions.
    case unreadableAction
    /// The plan is empty. Perfectly valid — "nothing to do".
    case nothingToDo
    /// ``PlanRepair`` turned a creation that would have collided with an
    /// existing note into an addition to that note (P2-04, ADR-070). Always a
    /// warning: the plan the user is shown is not quite the one the model
    /// wrote, and the card and the Activity row say so.
    case repairedCollision
    /// ``PlanRepair`` turned a `moveSegment` whose segment it could not verify
    /// into an addition at the destination, leaving the source note whole
    /// (P2-04, ADR-070). Always a warning.
    case repairedMerge
    /// ``PlanRepair`` inserted the `createFolder` the model forgot: the plan
    /// filed into a folder that does not exist and never created it — the
    /// live `unknownFolder` failure (P2-08). Creating a folder is additive.
    case repairedMissingFolder
    /// ``PlanRepair`` clamped a folder path deeper than
    /// ``PathRules/maxFolderDepth`` to its last two levels — the live
    /// `folderTooDeep` failure (P2-09, ADR-073). Always a warning.
    case repairedFolderDepth
    /// ``PlanRepair`` dropped a `createFolder` no other action files into —
    /// the empty folder the live junk plan left in the sidebar (P2-11,
    /// ADR-074). Always a warning; creating nothing is additive.
    case droppedUnusedFolder
    /// An `appendToNote` or `createNote` whose content is one short line that
    /// is nowhere in the session text: a bare label the model invented rather
    /// than material it carried (P2-11, ADR-074). Always an **error** — the
    /// live failure wrote two of these into a note under a `---` rule.
    case contentNotFromSession
}

/// One finding.
public struct PlanIssue: Sendable, Hashable, Codable {
    public var kind: PlanIssueKind
    /// Index into ``OrganizationPlan/actions``; `nil` for plan-level findings.
    public var actionIndex: Int?
    /// Content-free explanation. Note *text* never appears here — only titles,
    /// paths and ids, which the user typed and already sees.
    public var detail: String

    public init(kind: PlanIssueKind, actionIndex: Int? = nil, detail: String) {
        self.kind = kind
        self.actionIndex = actionIndex
        self.detail = detail
    }
}

/// The verdict.
public struct PlanValidation: Sendable, Hashable, Codable {
    public var errors: [PlanIssue]
    public var warnings: [PlanIssue]

    public init(errors: [PlanIssue] = [], warnings: [PlanIssue] = []) {
        self.errors = errors
        self.warnings = warnings
    }

    /// A plan with no errors may be applied. An empty plan is valid.
    public var isValid: Bool { errors.isEmpty }

    public func hasError(_ kind: PlanIssueKind) -> Bool { errors.contains { $0.kind == kind } }
    public func hasWarning(_ kind: PlanIssueKind) -> Bool { warnings.contains { $0.kind == kind } }

    /// One line per finding, for logs and the Activity entry.
    public var summary: String {
        (errors.map { "error: \($0.kind.rawValue): \($0.detail)" }
            + warnings.map { "warning: \($0.kind.rawValue): \($0.detail)" })
            .joined(separator: "\n")
    }
}

/// Checks a plan against the library before anything touches disk
/// (FR-4.1, FR-4.4, FR-4.5, risk #6).
///
/// The validator is the second of three guards. The first is the type system —
/// ``PlanAction`` has no case that can delete or replace user text. The third is
/// the compare-and-swap apply in M2-07, which re-checks the preconditions this
/// validator insists on. What is left for the validator is everything a model
/// can get wrong *within* the closed set: paths that do not exist, folders three
/// levels deep, targets inside excluded folders, a create that would land on an
/// existing note, a segment that is not in the source note verbatim,
/// contradictory actions.
public struct PlanValidator: Sendable {
    public var context: OrganizeContext
    /// Guard against a runaway model; a session plan is normally 1–5 actions.
    public var maxActions: Int
    /// Everything the user wrote in this session, when the caller has it.
    ///
    /// Only the organizer does: ``OrganizeContext/bodies`` is the *session's*
    /// notes there (``OrganizeContextBuilder``), and the applier's is the notes
    /// the plan happens to reference — a different set, and one that cannot
    /// answer "did this line come out of the session?". So P2-11's
    /// ``PlanIssueKind/contentNotFromSession`` guard is an **option**, and
    /// `nil` — the applier, and every caller that only wants the structural
    /// checks — turns it off rather than guessing.
    public var sessionText: String?

    public init(context: OrganizeContext, maxActions: Int = 50, sessionText: String? = nil) {
        self.context = context
        self.maxActions = maxActions
        self.sessionText = sessionText
    }

    public func validate(_ plan: OrganizationPlan, unknownActions: [UnknownPlanAction] = []) -> PlanValidation {
        var errors: [PlanIssue] = []
        var warnings: [PlanIssue] = []

        for unknown in unknownActions {
            warnings.append(PlanIssue(
                kind: .unreadableAction,
                actionIndex: unknown.index,
                detail: "\(unknown.name ?? "action") was dropped: \(unknown.reason)"
            ))
        }

        if plan.actions.isEmpty {
            warnings.append(PlanIssue(kind: .nothingToDo, detail: "The plan has no actions."))
            return PlanValidation(errors: errors, warnings: warnings)
        }

        if plan.actions.count > maxActions {
            errors.append(PlanIssue(
                kind: .tooManyActions,
                detail: "\(plan.actions.count) actions, limit is \(maxActions)."
            ))
        }

        // Folders this plan creates, ancestors included.
        var plannedFolders = Set<String>()
        for action in plan.actions {
            guard case let .createFolder(create) = action else { continue }
            var path = PathRules.normalize(create.path)
            while !path.isEmpty {
                plannedFolders.insert(path)
                path = PathRules.parent(of: path) ?? ""
            }
        }

        // The session text every `content` field has to be drawn from (P2-11),
        // normalised once. `nil` when the caller has no session — the guard
        // then does not run at all.
        let sessionText = sessionText.map(Self.matchText(of:)).flatMap { $0.isEmpty ? nil : $0 }

        var seenActions: [PlanAction: Int] = [:]
        var moveTargets: [NoteID: (index: Int, folder: String)] = [:]
        var retitles: [NoteID: (index: Int, title: String)] = [:]
        var createdPaths: [String: Int] = [:]
        // Where each note ends up as the plan runs, and which paths are taken.
        // Collisions have to be judged against the *projected* library, or a
        // move followed by a retitle could quietly land on an existing note.
        var projectedPaths: [NoteID: String] = [:]
        var occupiedPaths = Set(context.notes.map { PathRules.normalize($0.relativePath) })

        for (index, action) in plan.actions.enumerated() {
            if let first = seenActions[action] {
                warnings.append(PlanIssue(
                    kind: .duplicateAction,
                    actionIndex: index,
                    detail: "identical to action \(first)."
                ))
            } else {
                seenActions[action] = index
            }

            // Folder targets: safety, depth, existence, exclusion.
            for folder in action.targetFolderPaths {
                validateFolder(
                    folder,
                    index: index,
                    plannedFolders: plannedFolders,
                    isCreation: action.kind == .createFolder,
                    errors: &errors,
                    warnings: &warnings
                )
            }

            // Notes the plan brings into existence must not land on an existing
            // file — that is the only way a plan could overwrite user text.
            for created in action.createdNotes {
                validateTitle(created.title, index: index, errors: &errors)
                let path = PathRules.relativePath(folder: created.folderPath, title: created.title)
                if occupiedPaths.contains(path) {
                    errors.append(PlanIssue(
                        kind: .titleCollision,
                        actionIndex: index,
                        detail: "\(path) already exists; creating it would overwrite user text."
                    ))
                }
                if let first = createdPaths[path] {
                    errors.append(PlanIssue(
                        kind: .duplicateAction,
                        actionIndex: index,
                        detail: "action \(first) already creates \(path)."
                    ))
                } else {
                    createdPaths[path] = index
                    occupiedPaths.insert(path)
                }
            }

            // Every reference to an existing note must resolve, and must not be
            // in an excluded folder.
            for ref in action.referencedNotes {
                validateReference(ref, index: index, errors: &errors)
            }

            switch action {
            case let .createNote(create):
                if create.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warnings.append(PlanIssue(
                        kind: .emptyContent, actionIndex: index, detail: "\(create.title) would be empty."
                    ))
                } else {
                    validateContentIsFromTheSession(
                        create.content, index: index, sessionText: sessionText, errors: &errors
                    )
                }
                validateTags(create.tags, index: index, errors: &errors)

            case let .appendToNote(append):
                if append.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append(PlanIssue(
                        kind: .emptyContent, actionIndex: index, detail: "nothing to append to \(append.target.label)."
                    ))
                } else {
                    validateContentIsFromTheSession(
                        append.content, index: index, sessionText: sessionText, errors: &errors
                    )
                }

            case let .createFolder(create):
                if context.folderExists(create.path), !PathRules.normalize(create.path).isEmpty {
                    warnings.append(PlanIssue(
                        kind: .folderExists, actionIndex: index, detail: "\(create.path) already exists."
                    ))
                }

            case let .moveNote(move):
                guard let note = context.note(for: move.note) else { break }
                let destination = PathRules.normalize(move.toFolderPath)
                if note.folderPath == destination {
                    warnings.append(PlanIssue(
                        kind: .noOp, actionIndex: index, detail: "\(note.relativePath) is already in \(destination.isEmpty ? "the library root" : destination)."
                    ))
                }
                if let existing = moveTargets[note.id], existing.folder != destination {
                    errors.append(PlanIssue(
                        kind: .contradictoryAction,
                        actionIndex: index,
                        detail: "action \(existing.index) already moves \(note.relativePath) to \(existing.folder.isEmpty ? "the library root" : existing.folder)."
                    ))
                } else {
                    moveTargets[note.id] = (index, destination)
                }
                let current = projectedPaths[note.id] ?? PathRules.normalize(note.relativePath)
                let target = PathRules.relativePath(folder: destination, title: PathRules.title(of: current))
                if target != current, occupiedPaths.contains(target) {
                    errors.append(PlanIssue(
                        kind: .titleCollision,
                        actionIndex: index,
                        detail: "\(target) already exists."
                    ))
                } else if target != current {
                    occupiedPaths.remove(current)
                    occupiedPaths.insert(target)
                    projectedPaths[note.id] = target
                }

            case let .retitleNote(retitle):
                validateTitle(retitle.newTitle, index: index, errors: &errors)
                guard let note = context.note(for: retitle.note) else { break }
                if note.title == retitle.newTitle {
                    warnings.append(PlanIssue(
                        kind: .noOp, actionIndex: index, detail: "\(note.relativePath) is already titled \(note.title)."
                    ))
                }
                if let existing = retitles[note.id], existing.title != retitle.newTitle {
                    errors.append(PlanIssue(
                        kind: .contradictoryAction,
                        actionIndex: index,
                        detail: "action \(existing.index) already retitles \(note.relativePath) to \(existing.title)."
                    ))
                } else {
                    retitles[note.id] = (index, retitle.newTitle)
                }
                let current = projectedPaths[note.id] ?? PathRules.normalize(note.relativePath)
                let target = PathRules.relativePath(
                    folder: PathRules.folderPath(of: current), title: retitle.newTitle
                )
                if target != current, occupiedPaths.contains(target) {
                    errors.append(PlanIssue(
                        kind: .titleCollision, actionIndex: index, detail: "\(target) already exists."
                    ))
                } else if target != current {
                    occupiedPaths.remove(current)
                    occupiedPaths.insert(target)
                    projectedPaths[note.id] = target
                }

            case let .tagNote(tag):
                validateTags(tag.tags, index: index, errors: &errors)
                if tag.tags.isEmpty {
                    warnings.append(PlanIssue(kind: .noOp, actionIndex: index, detail: "no tags to add."))
                } else if let note = context.note(for: tag.note),
                          Set(tag.tags).isSubset(of: Set(note.tags)) {
                    warnings.append(PlanIssue(
                        kind: .noOp, actionIndex: index, detail: "\(note.relativePath) already has those tags."
                    ))
                }

            case let .moveSegment(move):
                validateSegment(move, index: index, errors: &errors, warnings: &warnings)
                if case let .newNote(title, _, tags) = move.destination {
                    validateTags(tags, index: index, errors: &errors)
                    _ = title  // title checked via `createdNotes`
                }
            }
        }

        validatePreconditions(plan, errors: &errors)

        return PlanValidation(errors: errors, warnings: warnings)
    }

    // MARK: - Pieces

    private func validateFolder(
        _ raw: String,
        index: Int,
        plannedFolders: Set<String>,
        isCreation: Bool,
        errors: inout [PlanIssue],
        warnings: inout [PlanIssue]
    ) {
        if let issue = Self.pathSafetyIssue(raw) {
            errors.append(PlanIssue(kind: .unsafePath, actionIndex: index, detail: "\(issue) (\(raw))"))
            return
        }
        let path = PathRules.normalize(raw)
        if PathRules.depth(ofFolder: path) > PathRules.maxFolderDepth {
            errors.append(PlanIssue(
                kind: .folderTooDeep,
                actionIndex: index,
                detail: "\(path) is \(PathRules.depth(ofFolder: path)) levels deep; the cap is \(PathRules.maxFolderDepth)."
            ))
            return
        }
        if context.isExcluded(path) {
            errors.append(PlanIssue(
                kind: .excludedTarget,
                actionIndex: index,
                detail: "\(path) is excluded from AI processing."
            ))
            return
        }
        for component in PathRules.components(path) where PathRules.sanitizeTitle(component) != component {
            errors.append(PlanIssue(
                kind: .unsafePath,
                actionIndex: index,
                detail: "\"\(component)\" is not a safe folder name."
            ))
            return
        }
        if !isCreation, !path.isEmpty, !context.folderExists(path), !plannedFolders.contains(path) {
            errors.append(PlanIssue(
                kind: .unknownFolder,
                actionIndex: index,
                detail: "\(path) does not exist and the plan does not create it."
            ))
        }
    }

    private func validateReference(_ ref: NoteRef, index: Int, errors: inout [PlanIssue]) {
        if ref.isEmpty {
            errors.append(PlanIssue(kind: .emptyReference, actionIndex: index, detail: "a note reference is empty."))
            return
        }
        if let path = ref.path, !path.isEmpty, let issue = Self.pathSafetyIssue(path) {
            errors.append(PlanIssue(kind: .unsafePath, actionIndex: index, detail: "\(issue) (\(path))"))
            return
        }
        if context.referenceIsContradictory(ref) {
            errors.append(PlanIssue(
                kind: .contradictoryReference,
                actionIndex: index,
                detail: "id and path in \(ref.label) name different notes."
            ))
            return
        }
        guard let note = context.note(for: ref) else {
            // An excluded note was never shown to the model, so a reference to
            // one is either a hallucination or a leak — say which.
            if let path = ref.path, context.isExcluded(path) {
                errors.append(PlanIssue(
                    kind: .excludedSource,
                    actionIndex: index,
                    detail: "\(path) is excluded from AI processing."
                ))
            } else {
                errors.append(PlanIssue(
                    kind: .unknownNote, actionIndex: index, detail: "no note matches \(ref.label)."
                ))
            }
            return
        }
        if context.isExcluded(note.relativePath) {
            errors.append(PlanIssue(
                kind: .excludedSource,
                actionIndex: index,
                detail: "\(note.relativePath) is excluded from AI processing."
            ))
        }
    }

    private func validateSegment(
        _ move: MoveSegmentAction,
        index: Int,
        errors: inout [PlanIssue],
        warnings: inout [PlanIssue]
    ) {
        if move.segment.isEmpty {
            errors.append(PlanIssue(kind: .emptySegment, actionIndex: index, detail: "the segment is empty."))
            return
        }
        if let hash = move.segmentHash, hash.lowercased() != Hashing.sha256Hex(move.segment) {
            errors.append(PlanIssue(
                kind: .segmentHashMismatch,
                actionIndex: index,
                detail: "segmentHash does not match the segment text."
            ))
        }
        guard let source = context.note(for: move.source) else { return }
        guard let body = context.bodies[source.id] else {
            warnings.append(PlanIssue(
                kind: .segmentUnverified,
                actionIndex: index,
                detail: "\(source.relativePath) was not loaded; apply will verify the segment."
            ))
            return
        }
        guard body.contains(move.segment) else {
            errors.append(PlanIssue(
                kind: .segmentNotFound,
                actionIndex: index,
                detail: "the segment is not in \(source.relativePath) verbatim."
            ))
            return
        }
        if case let .existingNote(destination) = move.destination,
           let target = context.note(for: destination), target.id == source.id {
            warnings.append(PlanIssue(
                kind: .noOp, actionIndex: index, detail: "the segment would move onto itself."
            ))
        }
    }

    // MARK: - Content has to come from the session (P2-11, ADR-074)

    /// A single line is a *label* — a heading, a title, a category name — when
    /// it is no longer than this **and** carries no more than
    /// ``labelWordLimit`` words. Both, not either.
    ///
    /// The numbers are hedges, not laws, and they are set from measurements at
    /// both ends. The two labels the live failure wrote were 13 and 18
    /// characters and two words each. The shortest *material* line in the
    /// committed goldens is 37 characters and six words ("the deploy script
    /// retries three times", `invalid-action-dropped`). Anything longer or
    /// wordier than a label is waved through: a long line is material even when
    /// the model paraphrased it, and this guard may only reject what is
    /// obviously junk.
    static let labelLengthLimit = 60
    static let labelWordLimit = 4

    /// Rejects an `appendToNote` / `createNote` whose content is one short line
    /// the session never contained.
    ///
    /// The live failure (2026-08-24, `llama3.1:8b`, a root-level note of OIDC
    /// commands) appended `OIDC Commands` and then `OIDC Configuration` to the
    /// very note the session was written in — two bare labels under two `---`
    /// rules, no material anywhere. Every existing guard passed: the note
    /// exists, the content is not empty, the reference resolves.
    ///
    /// **Why an error rather than a warning.** A warning would have applied it.
    /// An error at *this action's index* is what lets
    /// ``Organizer/repair(plan:unknownActions:context:repairingCollisions:)``
    /// drop exactly the junk and keep whatever else the plan got right.
    ///
    /// **What it deliberately does not touch.** Multi-line content — which is
    /// what a `createNote` composed from several session lines looks like — and
    /// any single line over ``labelLengthLimit``. A model that quotes the
    /// session, however loosely, keeps its action.
    private func validateContentIsFromTheSession(
        _ content: String,
        index: Int,
        sessionText: String?,
        errors: inout [PlanIssue]
    ) {
        guard let sessionText, Self.isLabelOnly(content, sessionText: sessionText) else { return }
        let count = content.trimmingCharacters(in: .whitespacesAndNewlines).count
        errors.append(PlanIssue(
            kind: .contentNotFromSession,
            actionIndex: index,
            // NFR-4: the length and the shape, never the line itself.
            detail: "the content is a single \(count)-character line that is not in the session text; "
                + "it is a label, not material."
        ))
    }

    /// `true` when `content` is one short line and `sessionText` — already
    /// through ``matchText(of:)`` — does not contain it.
    ///
    /// Matching is case-insensitive and whitespace-normalised, and the needle
    /// loses its Markdown furniture first (`#`, `-`, `1.`, `>`, a trailing
    /// `:`), so `## curl` still counts as carried when the session said `curl`.
    /// Every one of those makes the guard *more* permissive on purpose.
    static func isLabelOnly(_ content: String, sessionText: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        guard trimmed.count <= labelLengthLimit else { return false }
        let needle = matchText(of: stripMarkdownFurniture(trimmed))
        guard !needle.isEmpty else { return false }
        guard needle.split(separator: " ").count <= labelWordLimit else { return false }
        return !sessionText.contains(needle)
    }

    /// The comparable form of a body: lower-cased, every whitespace run one
    /// space.
    static func matchText(of text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Drops a line's leading list/heading/quote markers and its trailing `:`
    /// or `#`s.
    static func stripMarkdownFurniture(_ line: String) -> String {
        var scalars = Substring(line)
        while let first = scalars.first {
            if first == "#" || first == ">" || first == "*" || first == "+" || first == "-" || first.isWhitespace {
                scalars = scalars.dropFirst()
                continue
            }
            // An ordered-list marker: digits then `.` or `)`.
            let digits = scalars.prefix(while: \.isNumber)
            if !digits.isEmpty {
                let rest = scalars.dropFirst(digits.count)
                if let marker = rest.first, marker == "." || marker == ")" {
                    scalars = rest.dropFirst()
                    continue
                }
            }
            break
        }
        while let last = scalars.last, last == ":" || last == "#" || last.isWhitespace {
            scalars = scalars.dropLast()
        }
        return String(scalars)
    }

    private func validateTitle(_ title: String, index: Int, errors: inout [PlanIssue]) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errors.append(PlanIssue(kind: .unsafeTitle, actionIndex: index, detail: "the title is empty."))
            return
        }
        if PathRules.sanitizeTitle(title) != title {
            errors.append(PlanIssue(
                kind: .unsafeTitle,
                actionIndex: index,
                detail: "\"\(title)\" is not a safe filename; it would become \"\(PathRules.sanitizeTitle(title))\"."
            ))
        }
    }

    private func validateTags(_ tags: [String], index: Int, errors: inout [PlanIssue]) {
        for tag in tags where tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(PlanIssue(kind: .invalidTag, actionIndex: index, detail: "an empty tag."))
            return
        }
    }

    private func validatePreconditions(_ plan: OrganizationPlan, errors: inout [PlanIssue]) {
        var checked = Set<NoteID>()
        for (index, action) in plan.actions.enumerated() {
            for ref in action.referencedNotes {
                guard let note = context.note(for: ref), checked.insert(note.id).inserted else { continue }
                guard let expected = plan.preconditions[note.id] else {
                    errors.append(PlanIssue(
                        kind: .missingPrecondition,
                        actionIndex: index,
                        detail: "\(note.relativePath) has no content-hash precondition."
                    ))
                    continue
                }
                if expected != note.contentHash {
                    errors.append(PlanIssue(
                        kind: .stalePrecondition,
                        actionIndex: index,
                        detail: "\(note.relativePath) changed since the plan was made."
                    ))
                }
            }
        }
    }

    /// `nil` when the raw path is safe to hand to `NoteStore`.
    static func pathSafetyIssue(_ raw: String) -> String? {
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return "absolute paths are not allowed" }
        if raw.contains("\u{0}") { return "the path contains a null byte" }
        let components = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") { return "\"..\" is not allowed" }
        if raw.contains("\n") || raw.contains("\r") { return "the path contains a newline" }
        return nil
    }
}
