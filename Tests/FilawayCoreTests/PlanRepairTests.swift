import Foundation
import Testing

@testable import FilawayCore

/// ``PlanRepair`` — the two rewrites a local model's plan is allowed
/// (P2-04, ADR-070).
///
/// The suite is in two halves. The first pins each rewrite by hand. The second
/// is property-style over a deterministic generator: 600 plans drawn from a
/// pool of good actions, colliding creations and unverifiable merges, checked
/// against four invariants that together say "the repair only ever turns a
/// rejected plan into an acceptable one, and never the other way round".
@Suite("Plan repair (P2-04)")
struct PlanRepairTests {

    // MARK: - Fixtures

    /// `Commands/curl.md` exists; `Private/Salary.md` is excluded.
    static var context: OrganizeContext { SampleLibrary.context }

    static let curlPath = "Commands/curl.md"

    static func plan(_ actions: [PlanAction], summary: String = "Filed the session.") -> OrganizationPlan {
        var plan = OrganizationPlan(summary: summary, actions: actions, model: AIModel.defaultOllama.id)
        plan.preconditions = context.preconditions(for: plan)
        return plan
    }

    static func validate(_ plan: OrganizationPlan) -> PlanValidation {
        PlanValidator(context: context).validate(plan)
    }

    // MARK: - Rule 1: a creation that would collide becomes an addition

    @Test("createNote at a path that exists becomes appendToNote to the note that is there")
    func createNoteCollision() throws {
        let original = Self.plan([
            .createNote(CreateNoteAction(
                title: "curl", folderPath: "Commands", content: "one more invocation\n", tags: ["shell"]
            )),
        ])
        #expect(Self.validate(original).hasError(.titleCollision), "the premise")

        let result = PlanRepair.repair(original, in: Self.context)
        #expect(result.didRepair)
        #expect(result.warnings.map(\.kind) == [.repairedCollision])
        #expect(result.warnings.first?.actionIndex == 0)

        guard case let .appendToNote(append) = result.plan.actions.first else {
            Issue.record("expected an appendToNote, got \(result.plan.actions)")
            return
        }
        #expect(append.target.id == SampleLibrary.curlID)
        #expect(append.content == "one more invocation\n", "the content the model wrote, unchanged")
        #expect(append.heading == nil, "the title only becomes a heading when it says something new")
        // The tags survive as their own additive action.
        #expect(result.plan.actions.last == .tagNote(TagNoteAction(
            note: NoteRef(id: SampleLibrary.curlID, path: Self.curlPath), tags: ["shell"]
        )))
        #expect(Self.validate(result.plan).isValid, "\(Self.validate(result.plan).summary)")
        #expect(result.plan.neverDeletesUserText)
        // FR-3.2: the note it now touches has a compare-and-swap precondition.
        #expect(result.plan.preconditions[SampleLibrary.curlID] == SampleLibrary.precondition(for: SampleLibrary.curlID))
    }

    @Test("a title that says something new becomes the appended block's heading")
    func collisionKeepsTheTitleAsAHeading() throws {
        let original = Self.plan([
            .createNote(CreateNoteAction(title: "curl", folderPath: "Commands", content: "x\n")),
        ])
        let repaired = PlanRepair.repair(original, in: Self.context).plan
        guard case let .appendToNote(sameTitle) = repaired.actions[0] else { return }
        #expect(sameTitle.heading == nil)

        // A *different* title at the same path cannot collide — the path is the
        // title — so the heading case is the moveSegment one.
        let move = Self.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                destination: .newNote(title: "curl", folderPath: "Commands", tags: [])
            )),
        ])
        let repairedMove = PlanRepair.repair(move, in: Self.context).plan
        guard case let .moveSegment(action) = repairedMove.actions[0] else {
            Issue.record("expected a moveSegment, got \(repairedMove.actions)")
            return
        }
        guard case let .existingNote(target) = action.destination else {
            Issue.record("the destination was not redirected")
            return
        }
        #expect(target.id == SampleLibrary.curlID)
        #expect(action.segment == SampleLibrary.segment, "a verifiable segment still moves")
        #expect(Self.validate(repairedMove).isValid)
    }

    // MARK: - Rule 2: a merge nobody can verify becomes an addition

    @Test("moveSegment whose segment is not in the source becomes an append, and the source keeps every byte")
    func unverifiableMerge() throws {
        let paraphrased = "curl -sS https://example.test/documents"
        #expect(!SampleLibrary.scratchBody.contains(paraphrased), "the premise")
        let original = Self.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: paraphrased,
                destination: .existingNote(.id(SampleLibrary.curlID)),
                heading: "Fetch documents"
            )),
        ])
        #expect(Self.validate(original).hasError(.segmentNotFound), "the premise")

        let result = PlanRepair.repair(original, in: Self.context)
        #expect(result.warnings.map(\.kind) == [.repairedMerge])
        guard case let .appendToNote(append) = result.plan.actions.first else {
            Issue.record("expected an appendToNote, got \(result.plan.actions)")
            return
        }
        #expect(append.target.id == SampleLibrary.curlID)
        #expect(append.content == paraphrased)
        #expect(append.heading == "Fetch documents")
        #expect(!result.plan.actions.contains { $0.kind == .moveSegment }, "nothing leaves the source note")
        #expect(Self.validate(result.plan).isValid, "\(Self.validate(result.plan).summary)")
    }

    @Test("a segment that really is in the source is left alone")
    func verifiableMergeUntouched() throws {
        let original = Self.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
        ])
        #expect(Self.validate(original).isValid, "the premise")
        let result = PlanRepair.repair(original, in: Self.context)
        #expect(!result.didRepair)
        #expect(result.plan == original)
    }

    @Test("a source note nobody loaded is never downgraded on suspicion")
    func unloadedSourceIsNotDowngraded() throws {
        // The same context without bodies: the validator warns
        // `segmentUnverified` and lets the applier check against disk.
        let context = OrganizeContext(snapshot: SampleLibrary.snapshot, excludedFolders: ["Private"], bodies: [:])
        let original = OrganizationPlan(summary: "Merge.", actions: [
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: "anything at all",
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
        ])
        let result = PlanRepair.repair(original, in: context)
        #expect(!result.didRepair)
        #expect(result.plan == original)
    }

    // MARK: - What the repair refuses to do

    @Test("a collision with an excluded note is never repaired into it (FR-4.5)")
    func excludedTargetIsNeverARepairTarget() throws {
        let original = Self.plan([
            .createNote(CreateNoteAction(title: "Salary", folderPath: "Private", content: "more\n")),
        ])
        let result = PlanRepair.repair(original, in: Self.context)
        #expect(!result.didRepair, "the repair must not turn an excluded note into a merge target")
        #expect(result.plan == original)
        #expect(!Self.validate(result.plan).isValid, "and the validator still rejects it")
    }

    @Test("a plan with nothing to repair comes back byte-identical")
    func untouchedPlanIsIdentical() throws {
        let original = Self.plan([
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.curlID), content: "more\n")),
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["http"])),
            // The folder is created *and filed into*; rule 6 drops only the
            // ones nothing files into (P2-11).
            .createFolder(CreateFolderAction(path: "Snippets")),
            .createNote(CreateNoteAction(title: "ripgrep", folderPath: "Snippets", content: "rg -n TODO\n")),
        ])
        let result = PlanRepair.repair(original, in: Self.context)
        #expect(!result.didRepair)
        #expect(result.plan == original)
    }

    @Test("only Ollama opts in")
    func onlyLocalModelsOptIn() {
        #expect(AIProviderKind.ollama.repairsPlanCollisions)
        #expect(!AIProviderKind.claude.repairsPlanCollisions)
    }

    // MARK: - Properties

    /// A deterministic pool of actions: some good, some colliding, some
    /// unverifiable, some irrelevant to the repair.
    static func actionPool() -> [PlanAction] {
        [
            // Good.
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.curlID), content: "more\n")),
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["http"])),
            .createFolder(CreateFolderAction(path: "Snippets")),
            .retitleNote(RetitleNoteAction(note: .id(SampleLibrary.untitledID), newTitle: "Something named")),
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
            .createNote(CreateNoteAction(title: "New subject", folderPath: "Commands", content: "body\n")),
            // Colliding creations.
            .createNote(CreateNoteAction(
                title: "curl", folderPath: "Commands", content: "collides\n", tags: ["shell"]
            )),
            .createNote(CreateNoteAction(title: "curl", folderPath: "Commands", content: "collides too\n")),
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                destination: .newNote(title: "curl", folderPath: "Commands", tags: ["shell"])
            )),
            // Unverifiable merges.
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: "a paraphrase the source never contained",
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: "another line that is not there",
                destination: .newNote(title: "Fresh subject", folderPath: "Commands", tags: [])
            )),
            // Deeper than the library allows (P2-09).
            .createNote(CreateNoteAction(
                title: "Deep subject", folderPath: "Home/Projects/Skills/Cinegram", content: "deep\n"
            )),
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.untitledID), toFolderPath: "A/B/C/D")),
            // Untouchable: an excluded target, and a target that does not exist.
            .createNote(CreateNoteAction(title: "Salary", folderPath: "Private", content: "no\n")),
            .appendToNote(AppendToNoteAction(target: .id(NoteID()), content: "nowhere\n")),
        ]
    }

    /// `SystemRandomNumberGenerator` would make a failure unreproducible; this
    /// is the same splitmix64 the fuzz suite uses, seeded per test.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomPlans(count: Int, seed: UInt64 = 20_260_824) -> [OrganizationPlan] {
        var rng = Seeded(seed: seed)
        let pool = actionPool()
        return (0..<count).map { _ in
            let size = Int.random(in: 1...4, using: &rng)
            var actions: [PlanAction] = []
            for _ in 0..<size {
                actions.append(pool[Int.random(in: 0..<pool.count, using: &rng)])
            }
            return plan(actions)
        }
    }

    @Test("the repair never makes a plan worse, and fixes the two errors it exists for")
    func repairOnlyImproves() throws {
        var repairedCount = 0
        for original in Self.randomPlans(count: 600) {
            let before = Self.validate(original)
            let result = PlanRepair.repair(original, in: Self.context)
            let after = Self.validate(result.plan)

            // 1. A plan the validator already accepts is never touched —
            //    except that rule 6 takes a `createFolder` nothing files into
            //    out of it, which the validator only ever *warned* about
            //    (P2-11).
            if before.isValid {
                #expect(result.warnings.allSatisfy { $0.kind == .droppedUnusedFolder },
                        "a valid plan was rewritten: \(original.actions)")
                #expect(result.plan.actions == Self.withoutUnusedFolders(original.actions))
                continue
            }
            guard result.didRepair else {
                #expect(result.plan == original, "no warnings, so nothing may have changed")
                continue
            }
            repairedCount += 1

            // 2. FR-4.4 survives every rewrite.
            #expect(result.plan.neverDeletesUserText)

            // 3. No *new* kind of error appears. The repair may leave errors it
            //    is not for (an unknown note, an excluded target); it may never
            //    introduce one.
            let beforeKinds = Set(before.errors.map(\.kind))
            let afterKinds = Set(after.errors.map(\.kind))
            #expect(afterKinds.isSubset(of: beforeKinds),
                    "new errors \(afterKinds.subtracting(beforeKinds)) from \(original.actions)")

            // 4. The two errors the repair exists for are gone — except where
            //    the note in the way is one the user excluded, which the repair
            //    is not allowed to write to (FR-4.5).
            //    A collision between two actions of the *same* plan is a
            //    different bug (the model said it twice) and belongs to the
            //    organizer's drop pass, not here.
            for issue in after.errors where issue.kind == .titleCollision {
                let created = issue.actionIndex.map { result.plan.actions[$0].createdNotes } ?? []
                #expect(created.allSatisfy { note in
                    guard let existing = Self.context.note(inFolder: note.folderPath, title: note.title)
                    else { return true }
                    return Self.context.isExcluded(existing.relativePath)
                }, "a repairable collision survived: \(result.plan.actions)")
            }
            #expect(!after.hasError(.segmentNotFound))

            // 5. Every warning about an action that is *still there* says which
            //    one, and points into the plan. `droppedUnusedFolder` is the
            //    one plan-level warning: its action is gone, so an index would
            //    name the wrong one.
            for warning in result.warnings where warning.kind != .droppedUnusedFolder {
                let index = try #require(warning.actionIndex)
                #expect(index < result.plan.actions.count)
            }
        }
        #expect(repairedCount > 100, "the generator should be producing repairable plans")
    }

    @Test("repairing twice is repairing once")
    func repairIsAFixedPoint() throws {
        for original in Self.randomPlans(count: 300, seed: 99) {
            let once = PlanRepair.repair(original, in: Self.context).plan
            let twice = PlanRepair.repair(once, in: Self.context)
            #expect(!twice.didRepair, "a repaired plan still had something to repair: \(once.actions)")
            #expect(twice.plan == once)
        }
    }

    @Test("the only action the repair drops is a folder nothing files into")
    func nothingIsSilentlyDropped() throws {
        for original in Self.randomPlans(count: 300, seed: 7) {
            let result = PlanRepair.repair(original, in: Self.context)
            let dropped = result.warnings.filter { $0.kind == .droppedUnusedFolder }.count
            // Dropping is otherwise the organizer's job, not the repair's, and
            // rule 6 accounts for every action that left (P2-11).
            #expect(result.plan.actions.count >= original.actions.count - dropped,
                    "\(original.actions) lost more than \(dropped) actions")
            #expect(Self.withoutUnusedFolders(result.plan.actions) == result.plan.actions,
                    "an unused folder survived: \(result.plan.actions)")
            #expect(result.plan.summary == original.summary, "the repair never rewrites the summary")
        }
    }

    /// The rule-6 predicate, written out independently of the implementation:
    /// a `createFolder` survives only when some *other* action files into that
    /// folder or below it, and only the first of a repeat does.
    static func withoutUnusedFolders(_ actions: [PlanAction]) -> [PlanAction] {
        var used = Set<String>()
        for action in actions where action.kind != .createFolder {
            for folder in action.targetFolderPaths {
                var path = PathRules.normalize(folder)
                while !path.isEmpty {
                    used.insert(path)
                    path = PathRules.parent(of: path) ?? ""
                }
            }
        }
        var seen = Set<String>()
        return actions.filter { action in
            guard case let .createFolder(create) = action else { return true }
            let path = PathRules.normalize(create.path)
            return !path.isEmpty && used.contains(path) && seen.insert(path).inserted
        }
    }
}

// MARK: - Rule 4: the createFolder the model forgot (P2-08)

@Suite("Plan repair — missing folders (P2-08)")
struct PlanRepairMissingFolderTests {
    /// The live failure verbatim: file into a folder that does not exist,
    /// with no createFolder in the plan.
    @Test("an unknownFolder plan gains the createFolder and validates")
    func insertsTheMissingFolder() throws {
        let original = PlanRepairTests.plan([
            .createNote(CreateNoteAction(title: "OIDC", folderPath: "Reference", content: "curl …\n")),
        ])
        #expect(PlanRepairTests.validate(original).hasError(.unknownFolder), "the premise")

        let result = PlanRepair.repair(original, in: PlanRepairTests.context)
        #expect(result.warnings.map(\.kind) == [.repairedMissingFolder])
        #expect(result.plan.actions.first == .createFolder(CreateFolderAction(path: "Reference")))
        #expect(PlanRepairTests.validate(result.plan).isValid,
                "\(PlanRepairTests.validate(result.plan).summary)")
        #expect(result.plan.neverDeletesUserText)
    }

    /// An over-deep folder used to belong here too; since P2-09 rule 5 clamps
    /// it first and rule 4 then creates the *clamped* folder (ADR-073), so the
    /// only paths left un-repaired are the ones nothing could make safe.
    @Test("an unsafe folder is not repaired")
    func leavesUnsafeFoldersAlone() throws {
        for folder in ["../up", ""] {
            let original = PlanRepairTests.plan([
                .createNote(CreateNoteAction(title: "x", folderPath: folder, content: "y\n")),
            ])
            let result = PlanRepair.repair(original, in: PlanRepairTests.context)
            #expect(!result.warnings.contains { $0.kind == .repairedMissingFolder },
                    "\(folder) must stay the validator's rejection")
        }
    }

    @Test("a folder the plan already creates is not created twice")
    func respectsTheModelsOwnCreateFolder() throws {
        let original = PlanRepairTests.plan([
            .createFolder(CreateFolderAction(path: "Reference")),
            .createNote(CreateNoteAction(title: "OIDC", folderPath: "Reference", content: "curl …\n")),
        ])
        let result = PlanRepair.repair(original, in: PlanRepairTests.context)
        #expect(!result.didRepair, "nothing to fix")
        #expect(result.plan.actions == original.actions)
    }
}

// MARK: - Rule 5: a folder deeper than the library allows (P2-09)

/// The third live plan-quality failure, in the user's own words:
/// `folderTooDeep: Home/Projects/… /Skills/… is 5 levels deep; the cap is 2`.
/// ADR-073.
@Suite("Plan repair — folder depth (P2-09)")
struct PlanRepairFolderDepthTests {

    static func validate(_ plan: OrganizationPlan) -> PlanValidation {
        PlanRepairTests.validate(plan)
    }

    /// A clamp keeps the last **two** components, so it can only ever land in a
    /// folder that is itself two levels deep. `SampleLibrary` has none, which
    /// is exactly the shape the live failure had — this context adds one so the
    /// "clamped onto something that already exists" cases can be pinned.
    static let nestedID = NoteID(UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
    static let nestedPath = "Projects/Commands/curl.md"
    static let nestedBody = "# curl\n\nAlready filed.\n"

    static var nestedContext: OrganizeContext {
        let notes = SampleLibrary.notes + [
            SampleLibrary.note(id: nestedID, path: nestedPath, body: nestedBody),
        ]
        let snapshot = LibrarySnapshot(
            notes: notes,
            folderPaths: SampleLibrary.folderPaths + ["Projects", "Projects/Commands"],
            scannedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
        var bodies = SampleLibrary.bodies
        bodies[nestedID] = nestedBody
        return OrganizeContext(snapshot: snapshot, excludedFolders: ["Private"], bodies: bodies)
    }

    static func nestedPlan(_ actions: [PlanAction]) -> OrganizationPlan {
        var plan = OrganizationPlan(summary: "Filed the session.", actions: actions, model: AIModel.defaultOllama.id)
        plan.preconditions = nestedContext.preconditions(for: plan)
        return plan
    }

    static func validateNested(_ plan: OrganizationPlan) -> PlanValidation {
        PlanValidator(context: nestedContext).validate(plan)
    }

    @Test("a five-level folder is clamped to its last two, and the plan then validates")
    func clampsTheLiveFailure() throws {
        let original = PlanRepairTests.plan([
            .createNote(CreateNoteAction(
                title: "Filaway Updates",
                folderPath: "Home/Projects/Cinegram/Skills/Cinegram",
                content: "- the card is too small\n"
            )),
        ])
        #expect(Self.validate(original).hasError(.folderTooDeep), "the premise")

        let result = PlanRepair.repair(original, in: PlanRepairTests.context)
        #expect(result.didRepair)
        // Rule 5 clamps, rule 4 then remembers the folder does not exist yet.
        #expect(Set(result.warnings.map(\.kind)) == [.repairedFolderDepth, .repairedMissingFolder])
        #expect(result.plan.actions.first == .createFolder(CreateFolderAction(path: "Skills/Cinegram")))
        guard case let .createNote(create) = result.plan.actions.last else {
            Issue.record("expected the createNote to survive: \(result.plan.actions)")
            return
        }
        #expect(create.folderPath == "Skills/Cinegram", "the deepest components carry the classification")
        #expect(create.content == "- the card is too small\n", "the model's content, unchanged")
        #expect(Self.validate(result.plan).isValid, "\(Self.validate(result.plan).summary)")
        #expect(result.plan.neverDeletesUserText)
    }

    @Test("every action kind that names a folder is clamped")
    func clampsEveryFolderBearingAction() throws {
        let deep = "One/Two/Three/Four"
        let cases: [(PlanAction, String)] = [
            (.createNote(CreateNoteAction(title: "New", folderPath: deep, content: "x\n")), "createNote"),
            (.moveNote(MoveNoteAction(note: .id(SampleLibrary.untitledID), toFolderPath: deep)), "moveNote"),
            (.moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                destination: .newNote(title: "New", folderPath: deep, tags: [])
            )), "moveSegment"),
        ]
        for (action, label) in cases {
            let result = PlanRepair.repair(PlanRepairTests.plan([action]), in: PlanRepairTests.context)
            #expect(result.warnings.contains { $0.kind == .repairedFolderDepth }, "\(label) was not clamped")
            let folders = result.plan.actions.flatMap(\.targetFolderPaths)
            #expect(folders.allSatisfy { PathRules.depth(ofFolder: $0) <= PathRules.maxFolderDepth },
                    "\(label) left a deep folder: \(folders)")
            #expect(Self.validate(result.plan).isValid, "\(label): \(Self.validate(result.plan).summary)")
        }

        // `createFolder` is clamped too — but only when something files into
        // it. On its own it is junk, and rule 6 drops it before rule 5 can
        // bother clamping it (P2-11).
        let paired = PlanRepairTests.plan([
            .createFolder(CreateFolderAction(path: deep)),
            .createNote(CreateNoteAction(title: "New", folderPath: deep, content: "x\n")),
        ])
        let result = PlanRepair.repair(paired, in: PlanRepairTests.context)
        #expect(!result.warnings.contains { $0.kind == .droppedUnusedFolder }, "the folder is filed into")
        #expect(result.plan.actions.first == .createFolder(CreateFolderAction(path: "Three/Four")))
        #expect(Self.validate(result.plan).isValid, "\(Self.validate(result.plan).summary)")

        let alone = PlanRepairTests.plan([.createFolder(CreateFolderAction(path: deep))])
        let dropped = PlanRepair.repair(alone, in: PlanRepairTests.context)
        #expect(dropped.warnings.map(\.kind) == [.droppedUnusedFolder])
        #expect(dropped.plan.actions.isEmpty, "an empty plan is a real answer (FR-4.6)")
    }

    @Test("a folder that is already shallow enough is left byte-identical")
    func leavesShallowFoldersAlone() throws {
        for folder in ["", "Commands", "Commands/Shell"] {
            let original = PlanRepairTests.plan([
                .createNote(CreateNoteAction(title: "New subject", folderPath: folder, content: "x\n")),
            ])
            let result = PlanRepair.repair(original, in: PlanRepairTests.context)
            #expect(!result.warnings.contains { $0.kind == .repairedFolderDepth }, "\(folder)")
        }
    }

    @Test("a deep path Filaway could not make safe anyway is left as the validator's rejection")
    func refusesWhatItCannotJustify() throws {
        // An unsafe component, an escape, and a clamp that would land inside a
        // folder the user excluded from AI processing (FR-4.5).
        for folder in ["A/B/C:d/E", "../A/B/C", "A/B/Private/Salary"] {
            let original = PlanRepairTests.plan([
                .createNote(CreateNoteAction(title: "New subject", folderPath: folder, content: "x\n")),
            ])
            let result = PlanRepair.repair(original, in: PlanRepairTests.context)
            #expect(!result.warnings.contains { $0.kind == .repairedFolderDepth },
                    "\(folder) must stay the validator's rejection")
        }
    }

    @Test("a clamp never manufactures a collision a move cannot escape")
    func neverClampsAMoveOntoAnExistingNote() throws {
        // `Commands/curl.md` clamped into `Projects/Commands` would land on the
        // note already there — and a move, unlike a creation, has no additive
        // repair. It stays the validator's rejection.
        let original = Self.nestedPlan([
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.curlID), toFolderPath: "Home/Projects/Commands")),
        ])
        let result = PlanRepair.repair(original, in: Self.nestedContext)
        #expect(!result.warnings.contains { $0.kind == .repairedFolderDepth })
        #expect(result.plan.actions == original.actions)

        // The same move into a clamped folder with nothing in the way is fine.
        let free = Self.nestedPlan([
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.untitledID), toFolderPath: "Home/Projects/Commands")),
        ])
        let moved = PlanRepair.repair(free, in: Self.nestedContext)
        #expect(moved.warnings.contains { $0.kind == .repairedFolderDepth })
        #expect(Self.validateNested(moved.plan).isValid, "\(Self.validateNested(moved.plan).summary)")
    }

    @Test("a clamped creation that lands on an existing note is repaired by rule 1")
    func composesWithTheCollisionRule() throws {
        let original = Self.nestedPlan([
            .createNote(CreateNoteAction(
                title: "curl", folderPath: "Home/Projects/Commands", content: "one more invocation\n"
            )),
        ])
        #expect(Self.validateNested(original).hasError(.folderTooDeep), "the premise")

        let result = PlanRepair.repair(original, in: Self.nestedContext)
        #expect(Set(result.warnings.map(\.kind)) == [.repairedFolderDepth, .repairedCollision])
        guard case let .appendToNote(append) = result.plan.actions.first else {
            Issue.record("expected an appendToNote, got \(result.plan.actions)")
            return
        }
        #expect(append.target.id == Self.nestedID)
        #expect(Self.validateNested(result.plan).isValid, "\(Self.validateNested(result.plan).summary)")
    }

    @Test("clamping is a fixed point, and never loses or invents user text")
    func clampingIsAFixedPoint() throws {
        let deep = ["Home/Projects/Cinegram/Skills/Cinegram", "A/B/C", "One/Two/Three/Four/Five/Six"]
        for folder in deep {
            let original = PlanRepairTests.plan([
                .createNote(CreateNoteAction(title: "New subject", folderPath: folder, content: "x\n")),
            ])
            let once = PlanRepair.repair(original, in: PlanRepairTests.context)
            #expect(once.plan.summary == original.summary)
            #expect(once.plan.neverDeletesUserText)
            let twice = PlanRepair.repair(once.plan, in: PlanRepairTests.context)
            #expect(!twice.didRepair, "\(folder) still had something to repair")
            #expect(twice.plan == once.plan)
        }
    }
}

// MARK: - Rule 6: the folder nothing files into (P2-11)

/// The live junk plan of 2026-08-24, and the guard that would have stopped it
/// (ADR-074).
///
/// A root-level note of OIDC commands was edited and `llama3.1:8b` answered
/// with four actions: `createFolder OIDC`, an append of the label
/// `OIDC Commands` to that same note, `createFolder OIDC` **again**, and an
/// append of `OIDC Configuration`. Every guard passed — a duplicate action and
/// an existing folder are both warnings — so it applied: the note gained two
/// bare labels under two `---` rules, and the sidebar gained an `OIDC` folder
/// nothing was ever filed into.
@Suite("Plan repair — unused folders (P2-11)")
struct PlanRepairUnusedFolderTests {

    static func plan(_ actions: [PlanAction]) -> OrganizationPlan {
        PlanRepairTests.plan(actions)
    }

    @Test("the live junk plan loses both createFolders, and the validator rejects both labels")
    func liveJunkPlan() throws {
        let original = Self.plan([
            .createFolder(CreateFolderAction(path: "OIDC")),
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.scratchID), content: "OIDC Commands")),
            .createFolder(CreateFolderAction(path: "OIDC")),
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.scratchID), content: "OIDC Configuration")),
        ])
        // The premise, and the whole reason this shipped: nothing in the plan
        // as it stands is an *error*.
        #expect(PlanRepairTests.validate(original).isValid)

        let result = PlanRepair.repair(original, in: PlanRepairTests.context)
        #expect(result.warnings.map(\.kind) == [.droppedUnusedFolder, .droppedUnusedFolder])
        #expect(result.plan.actions.allSatisfy { $0.kind != .createFolder })
        #expect(result.plan.actions.count == 2, "the appends are the validator's business, not the repair's")

        // …and the validator, once it is given the session, rejects both.
        let validation = PlanValidator(
            context: PlanRepairTests.context, sessionText: SampleLibrary.scratchBody
        ).validate(result.plan)
        #expect(validation.errors.map(\.kind) == [.contentNotFromSession, .contentNotFromSession])
        #expect(validation.errors.compactMap(\.actionIndex) == [0, 1])
    }

    @Test("a folder something files into survives, and so does its parent")
    func usedFoldersSurvive() throws {
        let original = Self.plan([
            .createFolder(CreateFolderAction(path: "Projects")),
            .createFolder(CreateFolderAction(path: "Projects/Cinegram")),
            .createNote(CreateNoteAction(
                title: "Storyboard", folderPath: "Projects/Cinegram", content: "one\ntwo\n"
            )),
        ])
        let result = PlanRepair.repair(original, in: PlanRepairTests.context)
        #expect(!result.didRepair, "\(result.warnings.map(\.detail))")
        #expect(result.plan == original)
    }

    @Test("every filing action counts as filing into a folder")
    func everyFilingKindCounts() throws {
        let cases: [(PlanAction, String)] = [
            (.createNote(CreateNoteAction(title: "New", folderPath: "Snippets", content: "a\nb\n")), "createNote"),
            (.moveNote(MoveNoteAction(note: .id(SampleLibrary.untitledID), toFolderPath: "Snippets")), "moveNote"),
            (.moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                destination: .newNote(title: "New", folderPath: "Snippets", tags: [])
            )), "moveSegment"),
        ]
        for (action, label) in cases {
            let result = PlanRepair.repair(
                Self.plan([.createFolder(CreateFolderAction(path: "Snippets")), action]),
                in: PlanRepairTests.context
            )
            #expect(!result.warnings.contains { $0.kind == .droppedUnusedFolder }, "\(label) files into it")
        }
    }

    @Test("a plan that only creates a folder becomes the empty plan")
    func onlyAFolderIsNothingToDo() throws {
        let result = PlanRepair.repair(
            Self.plan([.createFolder(CreateFolderAction(path: "Snippets"))]),
            in: PlanRepairTests.context
        )
        // FR-4.6: the organizer's own empty-plan path then says "nothing to
        // do", which is a real answer — never a card promising a folder.
        #expect(result.plan.isEmpty)
    }

    @Test("dropping a folder is additive, and never touches the preconditions")
    func droppingIsAdditive() throws {
        let original = Self.plan([
            .createFolder(CreateFolderAction(path: "Snippets")),
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["http"])),
        ])
        let result = PlanRepair.droppingUnusedFolders(original)
        #expect(result.plan.neverDeletesUserText)
        #expect(result.plan.preconditions == original.preconditions)
        #expect(result.plan.summary == original.summary)
        #expect(result.plan.actions == [original.actions[1]])
    }

    @Test("the library root is never created")
    func rootIsNeverCreated() throws {
        for path in ["", "/", "  "] {
            let result = PlanRepair.droppingUnusedFolders(Self.plan([
                .createFolder(CreateFolderAction(path: path)),
                .createNote(CreateNoteAction(title: "New", folderPath: "", content: "a\nb\n")),
            ]))
            #expect(result.plan.actions.count == 1, "\"\(path)\" survived")
        }
    }

    @Test("dropping runs for Claude too — it is not a judgement about taste")
    func dropIsNotProviderGated() throws {
        // `PlanRepair.repair` is gated on `repairsPlanCollisions`;
        // `droppingUnusedFolders` deliberately is not, and `Organizer.repair`
        // calls it for every provider (ADR-074).
        let original = Self.plan([
            .createFolder(CreateFolderAction(path: "Snippets")),
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.curlID), content: "one\ntwo\n")),
        ])
        for kind in [AIProviderKind.claude, .ollama] {
            let repaired = Organizer.repair(
                plan: original,
                unknownActions: [],
                context: PlanRepairTests.context,
                repairingCollisions: kind.repairsPlanCollisions
            )
            guard case let .keep(plan, validation, _) = repaired else {
                Issue.record("\(kind.rawValue) discarded a good plan")
                continue
            }
            #expect(plan.actions.count == 1, "\(kind.rawValue) kept the unused folder")
            #expect(validation.hasWarning(.droppedUnusedFolder), "\(kind.rawValue) did not say so")
        }
    }
}
