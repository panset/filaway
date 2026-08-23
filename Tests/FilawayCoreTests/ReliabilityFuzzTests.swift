import Foundation
import Testing

@testable import FilawayCore

/// M4-08 — hundreds of hostile plans against a real library, with one promise
/// per plan (NFR-3: "AI failures never corrupt or lose notes"; risk #6).
///
/// The invariant is deliberately *not* "the validator rejects everything",
/// because that would encode today's severity split into a test and break the
/// moment a warning becomes an error. It is the thing the user actually cares
/// about:
///
/// * a plan the validator rejects is never applied, and the tree is byte-for-byte
///   what it was;
/// * a plan the validator accepts may change the tree, but **Undo puts every
///   byte back** — which is only true if the apply was additive, transactional
///   and journalled;
/// * nothing in the pipeline traps, whatever the model sends.
///
/// The corpus is generated from a seeded PRNG, so a failure names the seed and
/// the case that produced it and reproduces exactly.
@Suite("Malformed-plan fuzz (NFR-3, risk #6)")
struct ReliabilityFuzzTests {
    static let excludedFolder = "Private"

    @Test("Hundreds of hostile plans: rejected ones write nothing, accepted ones fully undo")
    func hostilePlansNeverLoseBytes() async throws {
        let harness = try ApplyHarness(excludedFolders: [Self.excludedFolder])
        try await seed(harness)
        let pristine = harness.fingerprint()
        let folders = harness.folders()

        let corpus = try await FuzzCorpus(harness: harness)
        var random = SplitMix64(seed: 0x5EED_0F_F1_1E_2026)
        var rejected = 0
        var accepted = 0

        for index in 0 ..< 400 {
            let sample = corpus.plan(index: index, using: &random)
            let context = try await harness.context()
            let validation = PlanValidator(context: context).validate(sample.plan)

            if !validation.isValid {
                rejected += 1
                await expectThrows(try await harness.applier.apply(sample.plan)) { error in
                    error is ApplyError || error is StorageError
                }
                #expect(
                    harness.fingerprint() == pristine,
                    "\(sample.label) was rejected but the tree changed"
                )
                #expect(harness.folders() == folders, "\(sample.label) left a folder behind")
                #expect(harness.temp.strayEntries().isEmpty, "\(sample.label) left a stray file")
                continue
            }

            // The validator let it through, so it is allowed to change things —
            // but only reversibly.
            accepted += 1
            do {
                _ = try await harness.apply(sample.plan)
            } catch {
                #expect(
                    harness.fingerprint() == pristine,
                    "\(sample.label) failed mid-apply without rolling back"
                )
                continue
            }
            let result = try await harness.undoLatest()
            #expect(result.outcome == .complete, "\(sample.label) could not be fully undone")
            #expect(
                harness.fingerprint() == pristine,
                "\(sample.label) applied and undone is not the tree we started with"
            )
            #expect(harness.temp.strayEntries().isEmpty, "\(sample.label) left a stray file")
        }

        // A corpus that stopped being adversarial would silently pass, so say
        // out loud that it is still mostly poison.
        #expect(rejected > 300, "the fuzz corpus has gone soft: only \(rejected)/400 were rejected")
        #expect(accepted + rejected == 400)
        // …and still exercises the accept-then-undo half at least sometimes.
        #expect(accepted > 0, "no generated plan validated: the undo half of the property never ran")
    }

    @Test("Every hostile plan decodes without trapping, whatever the JSON")
    func hostileToolInputNeverTraps() throws {
        var random = SplitMix64(seed: 0xBAD_10AD)
        for index in 0 ..< 400 {
            let input = FuzzCorpus.toolInput(index: index, using: &random)
            do {
                let decoding = try PlanDecoder.decode(toolInput: input)
                // Whatever came back, it is a plan made of the closed action set
                // and nothing else — that is the type system's guarantee, and
                // the reason a hallucinated action costs a warning, not a note.
                let additive = decoding.plan.actions.allSatisfy { $0.neverDeletesUserText }
                #expect(additive)
            } catch is PlanDecodingError {
                // The documented failure mode.
            } catch {
                Issue.record("case \(index) threw an undocumented \(type(of: error)): \(error)")
            }
        }
    }

    @Test("A tool input with 5,000 junk actions is bounded, not fatal")
    func runawayActionListIsBounded() async throws {
        let harness = try ApplyHarness()
        try await seed(harness)
        let pristine = harness.fingerprint()

        var actions: [JSONValue] = []
        for index in 0 ..< 5_000 {
            actions.append(.object([
                "action": .string("createNote"),
                "title": .string("Runaway \(index)"),
                "folderPath": .string(""),
                "content": .string("x"),
                "tags": .array([]),
            ]))
        }
        let decoding = try PlanDecoder.decode(
            toolInput: .object(["summary": .string("runaway"), "actions": .array(actions)])
        )
        let context = try await harness.context()
        let validation = PlanValidator(context: context).validate(decoding.plan)
        #expect(validation.hasError(.tooManyActions))
        await expectThrows(try await harness.applier.apply(decoding.plan)) { $0 is ApplyError }
        #expect(harness.fingerprint() == pristine)
    }

    // MARK: - Provider response decoding

    @Test("Random wire responses decode or throw AIError — never anything else")
    func randomWireResponsesNeverTrap() {
        var random = SplitMix64(seed: 0xC0DE_C0DE)
        for index in 0 ..< 400 {
            let value = FuzzCorpus.wireResponse(index: index, using: &random)
            do {
                let response = try ClaudeWire.response(from: value)
                // If it decoded, the plan decoder must also survive it.
                do {
                    _ = try PlanDecoder.decode(response: response)
                } catch is PlanDecodingError {
                } catch {
                    Issue.record("case \(index): plan decode threw \(type(of: error)): \(error)")
                }
            } catch is AIError {
                // The documented failure mode.
            } catch {
                Issue.record("case \(index): wire decode threw \(type(of: error)): \(error)")
            }
        }
    }

    @Test("Every stop_reason, known or invented, yields a usable verdict")
    func everyStopReasonIsHandled() throws {
        let reasons = [
            "end_turn", "tool_use", "max_tokens", "stop_sequence", "pause_turn", "refusal",
            "", "null", "TOOL_USE", "tool_use\u{0}", "🙂", String(repeating: "x", count: 4_096),
            "model_context_window_exceeded", "-1",
        ]
        for reason in reasons {
            let value = JSONValue.object([
                "id": .string("msg_1"),
                "model": .string("claude-test"),
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("text"), "text": .string("hello")])]),
                "stop_reason": .string(reason),
                "usage": .object(["input_tokens": .integer(1), "output_tokens": .integer(1)]),
            ])
            let response = try ClaudeWire.response(from: value)
            #expect(response.stopReason.rawValue == reason)
            // No tool call in there, so the decoder must say so rather than
            // invent an empty plan.
            do {
                _ = try PlanDecoder.decode(response: response)
                Issue.record("stop_reason \(reason.debugDescription) produced a plan out of thin air")
            } catch is PlanDecodingError {
            } catch {
                Issue.record("stop_reason \(reason.debugDescription): \(error)")
            }
        }
    }

    // MARK: - Seeding

    private func seed(_ harness: ApplyHarness) async throws {
        try await harness.seed("Scratch.md", "keep me\n\ncurl -sS https://example.com\n\ntrailing\n")
        try await harness.seed("Auth.md", "auth notes\n")
        try await harness.seed("Commands/curl.md", "# curl\n\nnotes about curl\n")
        try await harness.seed("Commands/git.md", "# git\n")
        try await harness.seed("\(Self.excludedFolder)/Diary.md", "not for the AI\n")
    }
}

// MARK: - The corpus

/// Builds one adversarial ``OrganizationPlan`` per index, with a label that
/// names what is wrong with it.
struct FuzzCorpus {
    struct Sample {
        var label: String
        var plan: OrganizationPlan
    }

    let scratch: NoteID
    let auth: NoteID
    let curl: NoteID
    let diary: NoteID
    let scratchHash: String
    let authHash: String
    let curlHash: String

    init(harness: ApplyHarness) async throws {
        let snapshot = try await harness.snapshot()
        func note(_ path: String) throws -> NoteSummary {
            guard let found = snapshot.notes.first(where: { $0.relativePath == path }) else {
                throw StorageError.notFound(path)
            }
            return found
        }
        let scratchNote = try note("Scratch.md")
        let authNote = try note("Auth.md")
        let curlNote = try note("Commands/curl.md")
        scratch = scratchNote.id
        auth = authNote.id
        curl = curlNote.id
        diary = try note("\(ReliabilityFuzzTests.excludedFolder)/Diary.md").id
        scratchHash = scratchNote.contentHash
        authHash = authNote.contentHash
        curlHash = curlNote.contentHash
    }

    /// 28 shapes of wrong, cycled and then perturbed by the PRNG so the same
    /// shape is not always the same plan.
    func plan(index: Int, using random: inout SplitMix64) -> Sample {
        let shape = index % 28
        let salt = Int(random.next() % 1_000)
        var actions: [PlanAction] = []
        var label = "case \(index)"

        switch shape {
        case 0:
            label = "path traversal in createNote"
            actions = [.createNote(CreateNoteAction(
                title: "escape \(salt)", folderPath: "../../etc", content: "x"
            ))]
        case 1:
            label = "absolute folder path"
            actions = [.createNote(CreateNoteAction(
                title: "absolute \(salt)", folderPath: "/etc/cron.d", content: "x"
            ))]
        case 2:
            label = "folder three levels deep"
            actions = [.createFolder(CreateFolderAction(path: "One/Two/Three"))]
        case 3:
            label = "createNote into an excluded folder"
            actions = [.createNote(CreateNoteAction(
                title: "leak \(salt)", folderPath: ReliabilityFuzzTests.excludedFolder, content: "x"
            ))]
        case 4:
            label = "moveNote into an excluded folder"
            actions = [.moveNote(MoveNoteAction(
                note: .id(auth), toFolderPath: ReliabilityFuzzTests.excludedFolder
            ))]
        case 5:
            label = "append to a note inside an excluded folder"
            actions = [.appendToNote(AppendToNoteAction(target: .id(diary), content: "x"))]
        case 6:
            label = "title of 20,000 characters"
            actions = [.createNote(CreateNoteAction(
                title: String(repeating: "т", count: 20_000), folderPath: "", content: "x"
            ))]
        case 7:
            label = "title made entirely of path separators"
            actions = [.createNote(CreateNoteAction(title: "../../..", folderPath: "", content: "x"))]
        case 8:
            label = "title with a NUL and control characters"
            actions = [.createNote(CreateNoteAction(
                title: "bad\u{0}title\u{7}\u{1B}[31m", folderPath: "", content: "x"
            ))]
        case 9:
            label = "title with a right-to-left override and zero-width joiners"
            actions = [.createNote(CreateNoteAction(
                title: "invoice\u{202E}fdp.md\u{200B}\u{200D}", folderPath: "", content: "x"
            ))]
        case 10:
            label = "NFD spelling of an existing title (unicode normalisation collision)"
            actions = [.createNote(CreateNoteAction(
                title: "Auth".decomposedStringWithCanonicalMapping, folderPath: "", content: "x"
            ))]
        case 11:
            label = "retitle onto an existing note's path"
            actions = [.retitleNote(RetitleNoteAction(note: .id(scratch), newTitle: "Auth"))]
        case 12:
            label = "segment that is not in the source"
            actions = [.moveSegment(MoveSegmentAction(
                source: .id(scratch),
                segment: "this text was never typed \(salt)",
                destination: .existingNote(.id(curl))
            ))]
        case 13:
            label = "segment hash that does not match the segment"
            actions = [.moveSegment(MoveSegmentAction(
                source: .id(scratch),
                segment: "curl -sS https://example.com",
                segmentHash: String(repeating: "0", count: 64),
                destination: .existingNote(.id(curl))
            ))]
        case 14:
            label = "empty segment"
            actions = [.moveSegment(MoveSegmentAction(
                source: .id(scratch), segment: "", destination: .existingNote(.id(curl))
            ))]
        case 15:
            label = "moveSegment whose destination is its own source"
            actions = [.moveSegment(MoveSegmentAction(
                source: .id(scratch),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(scratch))
            ))]
        case 16:
            label = "the same action twice"
            let action = PlanAction.appendToNote(AppendToNoteAction(target: .id(auth), content: "twice"))
            actions = [action, action]
        case 17:
            label = "two different titles for one note"
            actions = [
                .retitleNote(RetitleNoteAction(note: .id(auth), newTitle: "Auth API debug")),
                .retitleNote(RetitleNoteAction(note: .id(auth), newTitle: "Something else")),
            ]
        case 18:
            label = "two different destination folders for one note"
            actions = [
                .moveNote(MoveNoteAction(note: .id(auth), toFolderPath: "Commands")),
                .moveNote(MoveNoteAction(note: .id(auth), toFolderPath: "Ideas")),
            ]
        case 19:
            label = "move and retitle that contradict each other"
            actions = [
                .moveNote(MoveNoteAction(note: .id(auth), toFolderPath: "Commands")),
                .retitleNote(RetitleNoteAction(note: .id(auth), newTitle: "curl")),
                .moveNote(MoveNoteAction(note: .id(auth), toFolderPath: "")),
            ]
        case 20:
            label = "reference to a note that does not exist"
            actions = [.appendToNote(AppendToNoteAction(target: .id(NoteID()), content: "x"))]
        case 21:
            label = "reference whose id and path name different notes"
            actions = [.appendToNote(AppendToNoteAction(
                target: NoteRef(id: auth, path: "Commands/curl.md"), content: "x"
            ))]
        case 22:
            label = "empty reference"
            actions = [.appendToNote(AppendToNoteAction(target: NoteRef(), content: "x"))]
        case 23:
            label = "append with nothing to append"
            actions = [.appendToNote(AppendToNoteAction(target: .id(auth), content: "   \n\t "))]
        case 24:
            label = "whitespace-only tag"
            actions = [.tagNote(TagNoteAction(note: .id(auth), tags: ["  ", ""]))]
        case 25:
            label = "60 actions"
            actions = (0 ..< 60).map { offset in
                .createNote(CreateNoteAction(title: "Runaway \(salt)-\(offset)", folderPath: "", content: "x"))
            }
        case 26:
            label = "reference by a path that escapes the library"
            actions = [.appendToNote(AppendToNoteAction(
                target: NoteRef(path: "../../../../etc/passwd"), content: "x"
            ))]
        default:
            label = "createFolder with a traversal component"
            actions = [.createFolder(CreateFolderAction(path: "Commands/../../escape"))]
        }

        var plan = OrganizationPlan(summary: label, actions: actions)
        // Preconditions: mostly correct, sometimes stale, sometimes missing —
        // the third guard has to be exercised too (FR-3.2).
        switch random.next() % 8 {
        case 0:
            plan.preconditions = PlanPreconditions([:])
        case 1:
            plan.preconditions = PlanPreconditions([
                scratch: String(repeating: "f", count: 64),
                auth: String(repeating: "f", count: 64),
            ])
        default:
            plan.preconditions = PlanPreconditions([
                scratch: scratchHash, auth: authHash, curl: curlHash,
            ])
        }
        return Sample(label: label, plan: plan)
    }

    /// Raw tool input — the layer above ``plan(index:using:)``, where the JSON
    /// itself is wrong rather than the plan inside it.
    static func toolInput(index: Int, using random: inout SplitMix64) -> JSONValue {
        let junk: [JSONValue] = [
            .null, .bool(true), .integer(-1), .number(-0.0), .string(""),
            .string(String(repeating: "z", count: 5_000)), .array([]), .object([:]),
        ]
        func pick(_ random: inout SplitMix64) -> JSONValue {
            junk[Int(random.next() % UInt64(junk.count))]
        }

        switch index % 14 {
        case 0: return .null
        case 1: return .string("{\"summary\": \"a string, not an object\"}")
        case 2: return .array([pick(&random)])
        case 3: return .object(["actions": .array([])])
        case 4: return .object(["summary": pick(&random), "actions": .array([])])
        case 5: return .object(["summary": .string("s"), "actions": pick(&random)])
        case 6: return .object(["summary": .string("s"), "actions": .array([pick(&random)])])
        case 7:
            return .object([
                "summary": .string("s"),
                "actions": .array([.object(["action": .string("deleteEverything"), "path": .string("/")])]),
            ])
        case 8:
            return .object([
                "summary": .string("s"),
                "actions": .array([.object(["action": pick(&random), "title": pick(&random)])]),
            ])
        case 9:
            return .object([
                "summary": .string("s"),
                "actions": .array([.object([
                    "action": .string("createNote"),
                    "title": .integer(42),
                    "folderPath": .array([]),
                    "content": .object([:]),
                    "tags": .string("not an array"),
                ])]),
            ])
        case 10:
            return .object([
                "summary": .string("s"),
                "actions": .array([.object([
                    "action": .string("appendToNote"),
                    "target": pick(&random),
                    "content": .string("x"),
                ])]),
            ])
        case 11:
            return .object([
                "summary": .string("s"),
                "actions": .array([.object([
                    "action": .string("moveSegment"),
                    "source": .object(["id": .string("not-a-uuid")]),
                    "segment": .string("x"),
                    "destination": .object(["kind": .string("teleport")]),
                ])]),
            ])
        case 12:
            // One good action buried in noise: the decoder must keep it and
            // report the rest, never throw the lot away.
            return .object([
                "summary": .string("s"),
                "actions": .array([
                    pick(&random),
                    .object([
                        "action": .string("createFolder"),
                        "path": .string("Ideas"),
                    ]),
                    .object(["action": .string("nope")]),
                ]),
            ])
        default:
            return .object([
                "summary": .string(String(repeating: "s", count: 10_000)),
                "actions": .array((0 ..< 20).map { _ in pick(&random) }),
                "unexpected": pick(&random),
            ])
        }
    }

    /// A Messages-API `message` object, mangled in a different way each time.
    static func wireResponse(index: Int, using random: inout SplitMix64) -> JSONValue {
        let stopReasons = [
            "end_turn", "tool_use", "max_tokens", "refusal", "pause_turn", "", "who_knows", "🙂",
        ]
        let stop = JSONValue.string(stopReasons[Int(random.next() % UInt64(stopReasons.count))])
        let usage = JSONValue.object(["input_tokens": .integer(10), "output_tokens": .integer(5)])
        let goodContent = JSONValue.array([.object([
            "type": .string("tool_use"),
            "id": .string("toolu_1"),
            "name": .string(OrganizationPlan.toolName),
            "input": toolInputSample(random: &random),
        ])])

        switch index % 12 {
        case 0: return .null
        case 1: return .string("not an object")
        case 2: return .object([:])
        case 3: return .object(["type": .string("error"), "error": .object(["message": .string("boom")])])
        case 4: return .object(["id": .string("m"), "model": .string("x"), "stop_reason": stop, "usage": usage])
        case 5: return .object(["id": .string("m"), "content": .array([]), "stop_reason": stop, "usage": usage])
        case 6:
            return .object([
                "id": .string("m"), "model": .string("x"),
                "content": .array([.object(["type": .string("unheard_of"), "blob": .integer(1)])]),
                "stop_reason": stop, "usage": usage,
            ])
        case 7:
            return .object([
                "id": .string("m"), "model": .string("x"),
                "content": .array([.object(["type": .string("tool_use"), "name": .string("some_other_tool")])]),
                "stop_reason": stop, "usage": usage,
            ])
        case 8:
            return .object([
                "id": .integer(7), "model": .bool(false), "content": .string("nope"),
                "stop_reason": .null, "usage": .string("none"),
            ])
        case 9:
            return .object([
                "id": .string("m"), "model": .string("x"), "content": goodContent,
                "stop_reason": .string("refusal"),
                "stop_details": .object(["type": .string("refusal"), "category": .string("policy")]),
                "usage": usage,
            ])
        case 10:
            return .object([
                "id": .string("m"), "model": .string("x"), "content": goodContent,
                "stop_reason": .string("max_tokens"), "usage": usage,
            ])
        default:
            return .object([
                "id": .string("m"), "model": .string("x"), "content": goodContent,
                "stop_reason": stop, "usage": usage,
            ])
        }
    }

    private static func toolInputSample(random: inout SplitMix64) -> JSONValue {
        var local = random
        let value = toolInput(index: Int(local.next() % 14), using: &local)
        random = local
        return value
    }
}

extension ApplyHarness {
    /// The library as the validator sees it right now, bodies included.
    func context(excludedFolders: [String] = [ReliabilityFuzzTests.excludedFolder]) async throws -> OrganizeContext {
        let snapshot = try await snapshot()
        var bodies: [NoteID: String] = [:]
        for note in snapshot.notes {
            bodies[note.id] = try await store.read(note.relativePath).body
        }
        return OrganizeContext(snapshot: snapshot, excludedFolders: excludedFolders, bodies: bodies)
    }
}
