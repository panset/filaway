import Foundation

/// The two deterministic rewrites Filaway will make to a small model's plan
/// (P2-04, ADR-070).
///
/// **Why.** Measured over the nine organize goldens plus the smoke corpus,
/// `llama3.1:8b` produces a *decodable, well-shaped* plan almost every time and
/// then breaks one of two rules the validator cannot forgive:
///
/// * `titleCollision` — it answers "create `Commands/curl.md`" when the library
///   it was just shown already has `Commands/curl.md` and it means "add to it".
/// * `segmentNotFound` — it answers `moveSegment` and its `segment` is not in
///   the source note byte for byte (a dropped code fence, two non-adjacent
///   lines stitched together).
///
/// Both are naming mistakes, not filing mistakes: the note it picked is right.
/// Rejecting the plan costs the user the whole card. The numbers before and
/// after are in `docs/verification/P2-ollama.md`.
///
/// **What it is allowed to do.** Exactly this, and nothing else:
///
/// | Before | After |
/// |---|---|
/// | `createNote` whose folder + title name an existing note | `appendToNote` to that note, same content (`+ tagNote` when it carried tags) |
/// | `moveSegment` into a *new* note whose folder + title name an existing note | the same `moveSegment` into that existing note |
/// | `moveSegment` whose `segment` is not in the source verbatim | `appendToNote` (or `createNote`) of that text at the destination — **the source keeps every byte** |
/// | a folder path deeper than ``PathRules/maxFolderDepth`` | clamped to its **last** `maxFolderDepth` components (P2-09's live `folderTooDeep`) |
/// | a filing target's folder does not exist and no `createFolder` makes it | the missing `createFolder` is inserted first — the model's intent, minus its forgetfulness (P2-08's live `unknownFolder`) |
/// | a `createFolder` nothing files into, or the same one twice | dropped — the empty folder P2-11's live junk plan left in the sidebar |
///
/// Every result is strictly *additive*. The third rule in particular trades a
/// move for a copy: an unverifiable merge would have removed text from the
/// source note, and a repair is never allowed to guess about removal. The
/// content written is model-authored either way — that is already true of
/// `appendToNote` and `createNote`, which is why the downgrade adds nothing new
/// to the threat model — and
/// ``OrganizationPlan/neverDeletesUserText`` stays exhaustive over
/// ``PlanAction`` because no new case exists.
///
/// **What it will not do.** It never invents a target, never resolves a
/// collision against a note in an excluded folder (FR-4.5 — that note is not
/// the model's to write to), never touches an action it cannot explain, and
/// never rewrites the summary. The summary check in
/// ``Organizer/summaryStillMatches(_:kept:dropped:context:)`` still runs
/// afterwards; a repaired action names the same note the original named, so a
/// summary that mentioned it stays true.
///
/// **Who runs it.** Only providers that opt in —
/// ``AIProviderKind/repairsPlanCollisions``. Claude does not: Sonnet does not
/// make these mistakes, and quietly repairing a frontier model's plan would
/// hide a prompt regression behind a rewrite.
public enum PlanRepair {

    /// A repaired plan, plus one warning per rewrite.
    ///
    /// The warnings are ``PlanIssueKind/repairedCollision`` /
    /// ``PlanIssueKind/repairedMerge`` and ride into
    /// ``PlanValidation/warnings``, so the Figure 2a card and the Activity row
    /// both say the plan was adjusted rather than it silently changing under
    /// the user (FR-4.3).
    public struct Result: Sendable {
        public var plan: OrganizationPlan
        public var warnings: [PlanIssue]

        public init(plan: OrganizationPlan, warnings: [PlanIssue] = []) {
            self.plan = plan
            self.warnings = warnings
        }

        /// `true` when anything was rewritten.
        public var didRepair: Bool { !warnings.isEmpty }
    }

    /// Applies the table above. A plan with nothing to repair is returned
    /// unchanged, warnings empty.
    public static func repair(_ plan: OrganizationPlan, in context: OrganizeContext) -> Result {
        var actions: [PlanAction] = []
        var trailing: [PlanAction] = []
        var warnings: [PlanIssue] = []
        actions.reserveCapacity(plan.actions.count)

        // Rule 6 (P2-11) runs first of all, because it is the only rule that
        // *removes* an action: every index the rules below report is then an
        // index into the list they are actually working on. Nothing it drops
        // can matter to them — a folder no action files into is not a folder
        // any action can collide with, clamp into or forget to create.
        let remaining = dropUnusedFolders(plan.actions, warnings: &warnings)

        // Rule 5 (P2-09) is next, as a pre-pass: a clamped folder can then
        // collide with a note that is already there (rule 1 repairs that), and
        // it is the *clamped* folder rule 4 has to remember to create.
        let source = clampFolderDepth(remaining, in: context, warnings: &warnings)

        for (index, action) in source.enumerated() {
            switch action {
            case let .createNote(create):
                guard let occupant = occupant(folder: create.folderPath, title: create.title, in: context) else {
                    actions.append(action)
                    continue
                }
                let target = reference(to: occupant)
                actions.append(.appendToNote(AppendToNoteAction(
                    target: target,
                    content: create.content,
                    heading: heading(create.title, into: occupant)
                )))
                if !create.tags.isEmpty {
                    // Appended *after* the loop, so every warning's
                    // `actionIndex` still points at the action it describes.
                    trailing.append(.tagNote(TagNoteAction(note: target, tags: create.tags)))
                }
                warnings.append(collisionWarning(index: index, path: occupant.relativePath, from: "createNote"))

            case let .moveSegment(move):
                var repaired = move
                var repairedDestination = false
                if case let .newNote(title, folderPath, tags) = move.destination,
                   let occupant = occupant(folder: folderPath, title: title, in: context) {
                    let target = reference(to: occupant)
                    repaired.destination = .existingNote(target)
                    if repaired.heading == nil { repaired.heading = heading(title, into: occupant) }
                    if !tags.isEmpty { trailing.append(.tagNote(TagNoteAction(note: target, tags: tags))) }
                    warnings.append(
                        collisionWarning(index: index, path: occupant.relativePath, from: "moveSegment")
                    )
                    repairedDestination = true
                }

                if let downgraded = downgrade(repaired, in: context) {
                    actions.append(downgraded)
                    warnings.append(PlanIssue(
                        kind: .repairedMerge,
                        actionIndex: index,
                        detail: "the segment was not in the source note verbatim, so it was added to the "
                            + "destination instead of moved; the source note keeps every byte."
                    ))
                } else {
                    actions.append(repairedDestination ? .moveSegment(repaired) : action)
                }

            default:
                actions.append(action)
            }
        }

        // Rule 4 (P2-08): insert the `createFolder` the model forgot. Only for
        // a folder that would pass the validator anyway (safe components,
        // depth <= PathRules.maxFolderDepth) — repairing an unsafe path would
        // just move the rejection one error later.
        var creates = Set(actions.compactMap { action -> String? in
            if case let .createFolder(create) = action { return create.path }
            return nil
        })
        var inserted: [PlanAction] = []
        for (index, action) in actions.enumerated() {
            let folder: String?
            switch action {
            case let .createNote(create): folder = create.folderPath
            case let .moveNote(move): folder = move.toFolderPath
            case let .moveSegment(move):
                if case let .newNote(_, folderPath, _) = move.destination { folder = folderPath } else { folder = nil }
            default: folder = nil
            }
            guard let folder, !folder.isEmpty,
                  !context.folderExists(folder), !creates.contains(folder),
                  !context.isExcluded(folder),
                  (try? PathRules.sanitizeFolderPath(folder)) == folder
            else { continue }
            creates.insert(folder)
            inserted.append(.createFolder(CreateFolderAction(path: folder)))
            warnings.append(PlanIssue(
                kind: .repairedMissingFolder,
                actionIndex: index,
                detail: "the plan files into \(folder), which does not exist; the missing createFolder was added."
            ))
        }
        actions = inserted + actions

        guard !warnings.isEmpty else { return Result(plan: plan) }

        var repaired = plan
        repaired.actions = actions + trailing
        // The repair changed which notes the plan touches, and every touched
        // note needs a compare-and-swap precondition (FR-3.2) or the validator
        // rejects the result for `missingPrecondition` instead.
        repaired.preconditions = context.preconditions(for: repaired)
        return Result(plan: repaired, warnings: warnings)
    }

    // MARK: - Rule 6: a folder nothing files into (P2-11)

    /// Rule 6 on its own, for the callers that run it **for every provider**.
    ///
    /// It is the one rule that is not a judgement about a model's taste, which
    /// is what ``AIProviderKind/repairsPlanCollisions`` gates: a `createFolder`
    /// nothing files into leaves an empty folder in the sidebar whoever wrote
    /// it, and dropping a creation cannot make any plan worse. ADR-070's
    /// reasoning — that quietly rewriting Sonnet's plan would hide a prompt
    /// regression — does not reach it, because nothing here is rewritten.
    public static func droppingUnusedFolders(_ plan: OrganizationPlan) -> Result {
        var warnings: [PlanIssue] = []
        let actions = dropUnusedFolders(plan.actions, warnings: &warnings)
        guard !warnings.isEmpty else { return Result(plan: plan) }
        var out = plan
        out.actions = actions
        // `createFolder` references no note, so the compare-and-swap
        // preconditions are exactly what they were.
        return Result(plan: out, warnings: warnings)
    }

    /// Drops every `createFolder` whose path no *other* action in the plan
    /// files into — and every exact duplicate of one that survives.
    ///
    /// **The live failure.** A root-level note of OIDC commands was edited, and
    /// the plan came back as `createFolder OIDC`, an append, `createFolder
    /// OIDC` again, another append. Every guard passed — a duplicate action and
    /// an existing folder are both mere *warnings* — so it applied, and the
    /// sidebar gained an `OIDC` folder that nothing was ever filed into. FR-4.1
    /// is about filing a session; a folder with nothing in it files nothing,
    /// and the user can make one in the sidebar in two seconds.
    ///
    /// "Files into" means a `createNote.folderPath`, a `moveNote.toFolderPath`
    /// or a `moveSegment` destination's `folderPath` — or a *descendant* of
    /// one, so `createFolder Projects` survives next to `createNote` in
    /// `Projects/Cinegram`.
    ///
    /// Dropping a creation is strictly additive, exactly as inserting one is
    /// (rule 4), so ``OrganizationPlan/neverDeletesUserText`` is untouched. If
    /// nothing is left, the plan is empty — and an empty plan is a real answer
    /// (FR-4.6), so the user gets "nothing to do" rather than a card that
    /// promises a folder.
    ///
    /// It runs **before** every other rule, so that no rule below ever reports
    /// an `actionIndex` into a list an later drop has shortened. The cost is
    /// one case it does not catch: when rule 1 turns the plan's only
    /// `createNote` into an `appendToNote`, the `createFolder` beside it is
    /// left behind — but that folder holds the colliding note, so it exists,
    /// and creating a folder that exists is a `folderExists` warning and a
    /// no-op, never an empty folder in the sidebar.
    private static func dropUnusedFolders(
        _ actions: [PlanAction],
        warnings: inout [PlanIssue]
    ) -> [PlanAction] {
        var used = Set<String>()
        for action in actions {
            let folder: String?
            switch action {
            case let .createNote(create): folder = create.folderPath
            case let .moveNote(move): folder = move.toFolderPath
            case let .moveSegment(move):
                if case let .newNote(_, folderPath, _) = move.destination { folder = folderPath } else { folder = nil }
            case .createFolder, .appendToNote, .retitleNote, .tagNote:
                folder = nil
            }
            var path = PathRules.normalize(folder ?? "")
            while !path.isEmpty {
                used.insert(path)
                path = PathRules.parent(of: path) ?? ""
            }
        }

        var kept: [PlanAction] = []
        var seen = Set<String>()
        kept.reserveCapacity(actions.count)
        for action in actions {
            guard case let .createFolder(create) = action else {
                kept.append(action)
                continue
            }
            let path = PathRules.normalize(create.path)
            if !path.isEmpty, used.contains(path), seen.insert(path).inserted {
                kept.append(action)
                continue
            }
            // No `actionIndex`: the action it describes is not in the repaired
            // plan at all, and an index that points at a *different* action
            // would be worse than none.
            warnings.append(PlanIssue(
                kind: .droppedUnusedFolder,
                detail: seen.contains(path)
                    ? "the plan creates \(path) twice; the repeat was dropped."
                    : "nothing in the plan files into \(path), so creating it was dropped."
            ))
        }
        return kept
    }

    // MARK: - Rule 5: a folder deeper than the library allows (P2-09)

    /// Rewrites every folder path deeper than ``PathRules/maxFolderDepth`` to
    /// its **last** `maxFolderDepth` components, one warning per action.
    ///
    /// **Why the last ones.** The live failure was
    /// `Home/Projects/<something>/Skills/<something>` — five levels, in a
    /// library that had no folders at all. Read left to right that path is a
    /// mental filing cabinet the model invented; read right to left it is the
    /// model's actual classification of the session, and the leading components
    /// are the generic ones (`Home`, `Projects`). Keeping the deepest pair
    /// keeps the judgement and drops the scaffolding — and it is *stable*: the
    /// same session clamped twice lands in the same folder.
    ///
    /// **When it refuses.** Anything that would move the rejection one error
    /// later rather than remove it: a path with a real safety problem, a
    /// component that is not already a legal folder name (sanitising one would
    /// be inventing a name the user never saw), a clamped folder the user
    /// excluded (FR-4.5), or a `moveNote` whose clamped destination already
    /// holds a note of that title — a clamp may not manufacture a
    /// `titleCollision` nobody can repair.
    private static func clampFolderDepth(
        _ actions: [PlanAction],
        in context: OrganizeContext,
        warnings: inout [PlanIssue]
    ) -> [PlanAction] {
        var out: [PlanAction] = []
        out.reserveCapacity(actions.count)

        for (index, action) in actions.enumerated() {
            guard let deep = action.targetFolderPaths.first,
                  let shallow = clamped(deep, in: context)
            else {
                out.append(action)
                continue
            }

            let rewritten: PlanAction
            switch action {
            case let .createNote(original):
                var create = original
                create.folderPath = shallow
                rewritten = .createNote(create)
            case let .createFolder(original):
                var create = original
                create.path = shallow
                rewritten = .createFolder(create)
            case let .moveNote(original):
                // A move may not be repaired *into* a collision.
                guard let note = context.note(for: original.note),
                      context.note(inFolder: shallow, title: note.title) == nil
                else {
                    out.append(action)
                    continue
                }
                var move = original
                move.toFolderPath = shallow
                rewritten = .moveNote(move)
            case let .moveSegment(original):
                guard case let .newNote(title, _, tags) = original.destination else {
                    out.append(action)
                    continue
                }
                var move = original
                move.destination = .newNote(title: title, folderPath: shallow, tags: tags)
                rewritten = .moveSegment(move)
            default:
                out.append(action)
                continue
            }

            out.append(rewritten)
            warnings.append(PlanIssue(
                kind: .repairedFolderDepth,
                actionIndex: index,
                detail: "the plan filed into a folder \(PathRules.depth(ofFolder: deep)) levels deep; "
                    + "the cap is \(PathRules.maxFolderDepth), so its last \(PathRules.maxFolderDepth) "
                    + "levels were kept (\(shallow))."
            ))
        }
        return out
    }

    /// The clamped form of `folder`, or `nil` when it is shallow enough already
    /// or when clamping it would not be an improvement.
    private static func clamped(_ folder: String, in context: OrganizeContext) -> String? {
        guard PlanValidator.pathSafetyIssue(folder) == nil else { return nil }
        let parts = PathRules.components(folder)
        guard parts.count > PathRules.maxFolderDepth else { return nil }
        // Every component, not merely the kept ones: an unsafe component the
        // clamp happens to drop would turn `folderTooDeep` into a *different*
        // rejection, and the repair may only ever remove errors.
        guard parts.allSatisfy({ PathRules.sanitizeTitle($0) == $0 }) else { return nil }
        let shallow = parts.suffix(PathRules.maxFolderDepth).joined(separator: "/")
        guard !context.isExcluded(shallow) else { return nil }
        return shallow
    }

    // MARK: - The unverifiable merge

    /// `moveSegment` → an additive action when the segment is not in the source
    /// verbatim, `nil` when the move is fine or cannot be judged here.
    ///
    /// "Cannot be judged" means the source note's text was not in the context —
    /// the validator warns `segmentUnverified` for exactly that case and lets
    /// the applier check again against the bytes on disk. Downgrading on a
    /// *suspicion* would turn every un-loaded source into a copy.
    private static func downgrade(_ move: MoveSegmentAction, in context: OrganizeContext) -> PlanAction? {
        guard !move.segment.isEmpty,
              let source = context.note(for: move.source),
              let body = context.bodies[source.id],
              !body.contains(move.segment)
        else { return nil }

        switch move.destination {
        case let .existingNote(target):
            guard let note = context.note(for: target), !context.isExcluded(note.relativePath) else { return nil }
            return .appendToNote(AppendToNoteAction(
                target: target, content: move.segment, heading: move.heading, divider: move.divider
            ))
        case let .newNote(title, folderPath, tags):
            // The collision pass above already rewrote a destination that
            // exists, so this one really is new.
            return .createNote(CreateNoteAction(
                title: title, folderPath: folderPath, content: move.segment, tags: tags
            ))
        }
    }

    // MARK: - Helpers

    /// The note a creation at `folder`/`title` would land on, when there is one
    /// the plan is allowed to write to.
    private static func occupant(folder: String, title: String, in context: OrganizeContext) -> NoteSummary? {
        guard let note = context.note(inFolder: folder, title: title) else { return nil }
        // FR-4.5: a note the user excluded is not a merge target, and turning a
        // collision into an append would smuggle the session into it.
        guard !context.isExcluded(note.relativePath) else { return nil }
        return note
    }

    private static func reference(to note: NoteSummary) -> NoteRef {
        NoteRef(id: note.id, path: note.relativePath)
    }

    /// The title the model chose is the best label the added block has — unless
    /// it would merely repeat the heading the note already leads with.
    private static func heading(_ title: String, into note: NoteSummary) -> String? {
        title == note.title ? nil : title
    }

    private static func collisionWarning(index: Int, path: String, from kind: String) -> PlanIssue {
        PlanIssue(
            kind: .repairedCollision,
            actionIndex: index,
            detail: "\(kind) named \(path), which already exists; it was changed to add to that note instead."
        )
    }
}

public extension AIProviderKind {
    /// `true` when ``PlanRepair`` may rewrite this backend's plans.
    ///
    /// Only the local models opt in. An 8B model shown a library that already
    /// contains the obvious home note answers "create it" when it means "add to
    /// it" often enough to cost most of the cards; Sonnet does not, and quietly
    /// repairing a frontier model's plan would hide a prompt regression rather
    /// than surface it.
    ///
    /// It lives here rather than beside the other ``AIProviderKind`` switches
    /// on purpose: it is a fact about the repair, not about the wire format,
    /// and the AI layer has no business knowing what an organization plan is.
    var repairsPlanCollisions: Bool {
        switch self {
        case .claude: return false
        case .ollama: return true
        }
    }
}
