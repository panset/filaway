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

        for (index, action) in plan.actions.enumerated() {
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

        guard !warnings.isEmpty else { return Result(plan: plan) }

        var repaired = plan
        repaired.actions = actions + trailing
        // The repair changed which notes the plan touches, and every touched
        // note needs a compare-and-swap precondition (FR-3.2) or the validator
        // rejects the result for `missingPrecondition` instead.
        repaired.preconditions = context.preconditions(for: repaired)
        return Result(plan: repaired, warnings: warnings)
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
