import Foundation
import Testing

@testable import FilawayCore

@Suite("Plan validator")
struct PlanValidatorTests {
    private let context = SampleLibrary.context
    private var validator: PlanValidator { PlanValidator(context: context) }

    /// Builds a plan with the preconditions the library implies, so a test that
    /// is not about CAS does not have to spell them out.
    private func plan(_ actions: [PlanAction], summary: String = "Do it") -> OrganizationPlan {
        var plan = OrganizationPlan(summary: summary, actions: actions)
        plan.preconditions = context.preconditions(for: plan)
        return plan
    }

    // MARK: - The happy paths

    @Test("an empty plan is valid and says nothing to do")
    func emptyPlan() {
        let result = validator.validate(plan([], summary: "Nothing needs filing"))
        #expect(result.isValid)
        #expect(result.hasWarning(.nothingToDo))
        #expect(result.errors.isEmpty)
    }

    @Test("a realistic merge plan passes")
    func realisticPlan() {
        let result = validator.validate(plan([
            .createFolder(CreateFolderAction(path: "Commands/Docker")),
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                segmentHash: Hashing.sha256Hex(SampleLibrary.segment),
                destination: .existingNote(.id(SampleLibrary.curlID)),
                heading: "Fetch documents"
            )),
            .retitleNote(RetitleNoteAction(note: .id(SampleLibrary.untitledID), newTitle: "Auth notes")),
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["http"])),
        ], summary: "Merge the curl snippet into Commands/curl"))
        #expect(result.isValid, "\(result.summary)")
        #expect(result.warnings.isEmpty, "\(result.summary)")
    }

    @Test("a note may be created in a folder the same plan creates")
    func createsItsOwnFolder() {
        let result = validator.validate(plan([
            .createFolder(CreateFolderAction(path: "Recipes")),
            .createNote(CreateNoteAction(title: "Sourdough", folderPath: "Recipes", content: "flour\n")),
        ]))
        #expect(result.isValid, "\(result.summary)")
    }

    // MARK: - Hallucinated references (risk #6)

    @Test("an unknown note id is an error")
    func unknownNote() {
        let ghost = NoteID(UUID(uuidString: "99999999-9999-4999-8999-999999999999")!)
        let result = validator.validate(plan([
            .appendToNote(AppendToNoteAction(target: .id(ghost), content: "x")),
        ]))
        #expect(!result.isValid)
        #expect(result.hasError(.unknownNote))
    }

    @Test("an unknown path is an error")
    func unknownPath() {
        let result = validator.validate(plan([
            .moveNote(MoveNoteAction(note: .path("Nowhere/ghost.md"), toFolderPath: "Commands")),
        ]))
        #expect(result.hasError(.unknownNote))
    }

    @Test("an empty reference is an error")
    func emptyReference() {
        let result = validator.validate(plan([
            .tagNote(TagNoteAction(note: NoteRef(), tags: ["x"])),
        ]))
        #expect(result.hasError(.emptyReference))
    }

    @Test("an id and a path that disagree are an error")
    func contradictoryReference() {
        let result = validator.validate(plan([
            .tagNote(TagNoteAction(
                note: NoteRef(id: SampleLibrary.curlID, path: "Scratch.md"), tags: ["x"]
            )),
        ]))
        #expect(result.hasError(.contradictoryReference))
    }

    @Test("a folder that neither exists nor is created is an error")
    func unknownFolder() {
        let result = validator.validate(plan([
            .createNote(CreateNoteAction(title: "n", folderPath: "Invented", content: "x")),
        ]))
        #expect(result.hasError(.unknownFolder))
    }

    // MARK: - Depth and path safety

    @Test("three folder levels is an error")
    func tooDeep() {
        for action in [
            PlanAction.createFolder(CreateFolderAction(path: "A/B/C")),
            .createNote(CreateNoteAction(title: "n", folderPath: "A/B/C", content: "x")),
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.scratchID), toFolderPath: "A/B/C")),
        ] {
            #expect(validator.validate(plan([action])).hasError(.folderTooDeep), "\(action.kind)")
        }
    }

    @Test("escapes and absolute paths are errors")
    func unsafePaths() {
        let cases = ["/etc", "../../etc", "~/Documents", "Commands/../../etc", "Commands\nEvil"]
        for path in cases {
            let result = validator.validate(plan([.createFolder(CreateFolderAction(path: path))]))
            #expect(!result.isValid, "\(path) should be rejected")
        }
        #expect(PlanValidator.pathSafetyIssue("Commands/Docker") == nil)
    }

    @Test("a title that is not filesystem-safe is an error")
    func unsafeTitle() {
        for title in ["a/b", "with:colon", "   ", ".hidden"] {
            let result = validator.validate(plan([
                .createNote(CreateNoteAction(title: title, folderPath: "Commands", content: "x")),
            ]))
            #expect(result.hasError(.unsafeTitle), "\(title) should be rejected")
        }
        #expect(validator.validate(plan([
            .retitleNote(RetitleNoteAction(note: .id(SampleLibrary.untitledID), newTitle: "OK/Not")),
        ])).hasError(.unsafeTitle))
    }

    // MARK: - Exclusions (FR-4.5)

    @Test("a target inside an excluded folder is an error")
    func excludedTarget() {
        for action in [
            PlanAction.createNote(CreateNoteAction(title: "n", folderPath: "Private", content: "x")),
            .createFolder(CreateFolderAction(path: "Private/Deeper")),
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.scratchID), toFolderPath: "Private")),
        ] {
            #expect(validator.validate(plan([action])).hasError(.excludedTarget), "\(action.kind)")
        }
    }

    @Test("a source inside an excluded folder is an error, named as such")
    func excludedSource() {
        let byPath = validator.validate(plan([
            .appendToNote(AppendToNoteAction(target: .path("Private/Salary.md"), content: "x")),
        ]))
        #expect(byPath.hasError(.excludedSource))

        // By id it is simply unknown — the note never entered the context, so
        // the model could only have invented the id.
        let byID = validator.validate(plan([
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.privateID), content: "x")),
        ]))
        #expect(byID.hasError(.unknownNote))
    }

    // MARK: - Never overwrite (FR-4.4)

    @Test("creating a note where one exists is rejected")
    func createCollision() {
        let result = validator.validate(plan([
            .createNote(CreateNoteAction(title: "curl", folderPath: "Commands", content: "x")),
        ]))
        #expect(result.hasError(.titleCollision))
    }

    @Test("retitling onto an existing note is rejected")
    func retitleCollision() {
        let result = validator.validate(plan([
            .createFolder(CreateFolderAction(path: "Commands")),
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.untitledID), toFolderPath: "Commands")),
            .retitleNote(RetitleNoteAction(note: .id(SampleLibrary.untitledID), newTitle: "curl")),
        ]))
        // The retitle would put a second `curl` in Commands — the validator has
        // to judge collisions against the library *as the plan leaves it*.
        #expect(result.hasError(.titleCollision))
    }

    @Test("moving a note onto an existing path is rejected")
    func moveCollision() {
        let context = OrganizeContext(
            notes: [
                SampleLibrary.note(id: SampleLibrary.scratchID, path: "curl.md", body: "a"),
                SampleLibrary.note(id: SampleLibrary.curlID, path: "Commands/curl.md", body: "b"),
            ],
            folderPaths: ["Commands"]
        )
        var plan = OrganizationPlan(summary: "s", actions: [
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.scratchID), toFolderPath: "Commands")),
        ])
        plan.preconditions = context.preconditions(for: plan)
        #expect(PlanValidator(context: context).validate(plan).hasError(.titleCollision))
    }

    @Test("two actions creating the same path is a duplicate")
    func duplicateCreate() {
        let result = validator.validate(plan([
            .createNote(CreateNoteAction(title: "New", folderPath: "Commands", content: "a")),
            .createNote(CreateNoteAction(title: "New", folderPath: "Commands", content: "b")),
        ]))
        #expect(result.hasError(.duplicateAction))
    }

    // MARK: - Contradictions

    @Test("two different destinations for one note contradict")
    func contradictoryMoves() {
        let result = validator.validate(plan([
            .createFolder(CreateFolderAction(path: "Archive")),
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.scratchID), toFolderPath: "Commands")),
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.scratchID), toFolderPath: "Archive")),
        ]))
        #expect(result.hasError(.contradictoryAction))
    }

    @Test("two different titles for one note contradict")
    func contradictoryRetitles() {
        let result = validator.validate(plan([
            .retitleNote(RetitleNoteAction(note: .id(SampleLibrary.untitledID), newTitle: "One")),
            .retitleNote(RetitleNoteAction(note: .id(SampleLibrary.untitledID), newTitle: "Two")),
        ]))
        #expect(result.hasError(.contradictoryAction))
    }

    @Test("an identical action twice is a warning, not an error")
    func duplicateAction() {
        let action = PlanAction.tagNote(TagNoteAction(note: .id(SampleLibrary.scratchID), tags: ["x"]))
        let result = validator.validate(plan([action, action]))
        #expect(result.isValid)
        #expect(result.hasWarning(.duplicateAction))
    }

    // MARK: - moveSegment

    @Test("a segment that is not in the source verbatim is rejected")
    func segmentNotFound() {
        let result = validator.validate(plan([
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: "curl -sS https://example.test/documents",  // paraphrased, not copied
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
        ]))
        #expect(result.hasError(.segmentNotFound))
    }

    @Test("a segment hash that does not match its text is rejected")
    func segmentHashMismatch() {
        let result = validator.validate(plan([
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: SampleLibrary.segment,
                segmentHash: String(repeating: "0", count: 64),
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
        ]))
        #expect(result.hasError(.segmentHashMismatch))
    }

    @Test("an empty segment is rejected")
    func emptySegment() {
        let result = validator.validate(plan([
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: "",
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
        ]))
        #expect(result.hasError(.emptySegment))
    }

    @Test("without the source text the check downgrades to a warning")
    func segmentUnverified() {
        var context = SampleLibrary.context
        context.bodies = [:]
        var plan = OrganizationPlan(summary: "s", actions: [
            .moveSegment(MoveSegmentAction(
                source: .id(SampleLibrary.scratchID),
                segment: "anything at all",
                destination: .existingNote(.id(SampleLibrary.curlID))
            )),
        ])
        plan.preconditions = context.preconditions(for: plan)
        let result = PlanValidator(context: context).validate(plan)
        #expect(result.isValid)
        #expect(result.hasWarning(.segmentUnverified))
    }

    // MARK: - Preconditions (FR-3.2)

    @Test("a touched note without a precondition is rejected")
    func missingPrecondition() {
        let plan = OrganizationPlan(summary: "s", actions: [
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["x"])),
        ])
        #expect(validator.validate(plan).hasError(.missingPrecondition))
    }

    @Test("a stale precondition is rejected")
    func stalePrecondition() {
        var plan = OrganizationPlan(summary: "s", actions: [
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["x"])),
        ])
        plan.preconditions = PlanPreconditions([SampleLibrary.curlID: "deadbeef"])
        #expect(validator.validate(plan).hasError(.stalePrecondition))
    }

    @Test("actions that create things need no preconditions")
    func createsNeedNoPreconditions() {
        let plan = OrganizationPlan(summary: "s", actions: [
            .createFolder(CreateFolderAction(path: "Recipes")),
            .createNote(CreateNoteAction(title: "Sourdough", folderPath: "Recipes", content: "flour")),
        ])
        #expect(validator.validate(plan).isValid)
    }

    // MARK: - No-ops and noise

    @Test("no-ops are warnings")
    func noOps() {
        let sameFolder = validator.validate(plan([
            .moveNote(MoveNoteAction(note: .id(SampleLibrary.curlID), toFolderPath: "Commands")),
        ]))
        #expect(sameFolder.isValid)
        #expect(sameFolder.hasWarning(.noOp))

        let sameTags = validator.validate(plan([
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["shell"])),
        ]))
        #expect(sameTags.hasWarning(.noOp))

        let existingFolder = validator.validate(plan([.createFolder(CreateFolderAction(path: "Commands"))]))
        #expect(existingFolder.hasWarning(.folderExists))
    }

    @Test("empty content is an error to append and a warning to create")
    func emptyContent() {
        let append = validator.validate(plan([
            .appendToNote(AppendToNoteAction(target: .id(SampleLibrary.curlID), content: "  \n")),
        ]))
        #expect(append.hasError(.emptyContent))

        let create = validator.validate(plan([
            .createNote(CreateNoteAction(title: "Empty", folderPath: "", content: "")),
        ]))
        #expect(create.isValid)
        #expect(create.hasWarning(.emptyContent))
    }

    @Test("an empty tag is an error")
    func invalidTag() {
        #expect(validator.validate(plan([
            .tagNote(TagNoteAction(note: .id(SampleLibrary.curlID), tags: ["ok", "  "])),
        ])).hasError(.invalidTag))
    }

    @Test("a runaway plan is rejected")
    func tooManyActions() {
        let actions = (0 ..< 60).map { index in
            PlanAction.createNote(CreateNoteAction(title: "n\(index)", folderPath: "", content: "x"))
        }
        #expect(validator.validate(plan(actions)).hasError(.tooManyActions))
    }

    @Test("actions the decoder dropped come through as warnings")
    func unreadableActions() {
        let result = validator.validate(
            plan([SampleActions.createFolder]),
            unknownActions: [UnknownPlanAction(index: 3, name: "deleteNote", reason: "not in the set", raw: .null)]
        )
        #expect(result.isValid)
        #expect(result.hasWarning(.unreadableAction))
        #expect(result.warnings.first?.detail.contains("deleteNote") == true)
    }

    // MARK: - Property-style

    @Test("a plan built from random unknown ids never validates")
    func randomUnknownIDsAlwaysFail() {
        var generator = SplitMix64(seed: 0xF11A_1A17)
        for _ in 0 ..< 200 {
            let ghost = NoteID(UUID(uuid: (
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator),
                UInt8.random(in: 0 ... 255, using: &generator), UInt8.random(in: 0 ... 255, using: &generator)
            )))
            let actions: [PlanAction] = [
                .appendToNote(AppendToNoteAction(target: .id(ghost), content: "x")),
                .moveNote(MoveNoteAction(note: .id(ghost), toFolderPath: "Commands")),
                .retitleNote(RetitleNoteAction(note: .id(ghost), newTitle: "T")),
                .tagNote(TagNoteAction(note: .id(ghost), tags: ["t"])),
                .moveSegment(MoveSegmentAction(
                    source: .id(ghost), segment: "s", destination: .existingNote(.id(ghost))
                )),
            ]
            let action = actions[Int.random(in: 0 ..< actions.count, using: &generator)]
            var plan = OrganizationPlan(summary: "s", actions: [action])
            plan.preconditions = PlanPreconditions([ghost: "whatever"])
            let result = validator.validate(plan)
            #expect(!result.isValid, "\(action.kind) on an unknown id must fail")
            #expect(result.hasError(.unknownNote))
        }
    }

    @Test("random folder paths deeper than the cap never validate")
    func randomDeepFoldersAlwaysFail() {
        var generator = SplitMix64(seed: 7)
        let names = ["A", "B", "Commands", "Notes", "x y", "Docker"]
        for _ in 0 ..< 100 {
            let depth = Int.random(in: 3 ... 6, using: &generator)
            let path = (0 ..< depth).map { _ in names[Int.random(in: 0 ..< names.count, using: &generator)] }
                .joined(separator: "/")
            let result = validator.validate(plan([.createFolder(CreateFolderAction(path: path))]))
            #expect(!result.isValid, "\(path) is \(depth) deep and must fail")
        }
    }
}
