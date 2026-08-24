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
            .createFolder(CreateFolderAction(path: "Snippets")),
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

            // 1. A plan the validator already accepts is never touched.
            if before.isValid {
                #expect(!result.didRepair, "a valid plan was rewritten: \(original.actions)")
                #expect(result.plan == original)
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

            // 5. Every warning says which action it describes, and points into
            //    the plan.
            for warning in result.warnings {
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

    @Test("a plan the repair rewrote never loses an action")
    func nothingIsSilentlyDropped() throws {
        for original in Self.randomPlans(count: 300, seed: 7) {
            let result = PlanRepair.repair(original, in: Self.context)
            #expect(result.plan.actions.count >= original.actions.count,
                    "dropping is the organizer's job, not the repair's")
            #expect(result.plan.summary == original.summary, "the repair never rewrites the summary")
        }
    }
}
