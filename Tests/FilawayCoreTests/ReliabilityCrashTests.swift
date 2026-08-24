import Foundation
import Testing

@testable import FilawayCore

/// M4-08 — the three ways a machine can die under Filaway, and the promise that
/// none of them costs a byte (NFR-3: "no data loss on crash beyond FR-2.3's
/// two-second window; AI failures never corrupt or lose notes").
///
/// * `kill -9` in the middle of ``NoteStore/save(body:to:tags:)``.
/// * `kill -9` in the middle of an apply, and in the middle of an Undo.
/// * A power cut that leaves a SQLite file unreadable.
///
/// A test cannot really SIGKILL itself, so each case throws from a hook at the
/// exact instruction a kill would land on and then asks the *next launch* to
/// pick up the pieces.
@Suite("Crash safety (NFR-3)")
struct ReliabilityCrashTests {

    // MARK: - (a) kill -9 inside an atomic write

    @Test("A kill between the staged write and the rename leaves the old note whole")
    func killBeforeRenameKeepsTheOriginal() async throws {
        let temp = try TempLibrary()
        let original = "auth notes\n\nTOKEN=abc\n"
        try await temp.store.save(body: original, to: "Auth.md")
        let before = try temp.readExternal("Auth.md")

        await temp.store.setFailureHook(.crash(at: { step in
            if case let .beforeRename(path) = step { return path == "Auth.md" }
            return false
        }))
        await #expect(throws: StorageError.self) {
            try await temp.store.save(body: "everything the user just typed\n", to: "Auth.md")
        }

        // The file the user can see never stopped being the old one.
        #expect(try temp.readExternal("Auth.md") == before)
        #expect(try await temp.store.read("Auth.md").body == original)
        // ADR-008: the staging directory is outside the notes root, so a kill
        // mid-write cannot leave a `.tmp` sibling next to the note.
        #expect(temp.strayEntries().isEmpty)
        #expect(temp.allMarkdownPaths() == ["Auth.md"])
    }

    @Test("A kill during the very first write of a note creates no half-file")
    func killBeforeRenameOnCreateLeavesNothing() async throws {
        let temp = try TempLibrary()
        await temp.store.setFailureHook(.crash(at: { _ in true }))

        await #expect(throws: StorageError.self) {
            try await temp.store.save(body: "first words\n", to: "Fresh.md")
        }
        #expect(temp.allMarkdownPaths().isEmpty)
        #expect(temp.strayEntries().isEmpty)
        #expect(await temp.store.exists("Fresh.md") == false)
    }

    @Test("A note that survived a killed write is not recorded as our own edit")
    func killedWriteLeavesNoEchoSuppression() async throws {
        let temp = try TempLibrary()
        try await temp.store.save(body: "one\n", to: "Note.md")
        _ = await temp.store.consumeOwnOperation(relativePath: "Note.md", contentHash: nil)
        let pendingBefore = await temp.store.pendingOwnOperationCount

        await temp.store.setFailureHook(.crash(at: { _ in true }))
        await #expect(throws: StorageError.self) {
            try await temp.store.save(body: "two\n", to: "Note.md")
        }
        // A write that never landed must not suppress a *real* external change
        // to the same path later on (ADR-009).
        #expect(await temp.store.pendingOwnOperationCount == pendingBefore)
    }

    // MARK: - (b) kill -9 mid-apply

    @Test("A kill after one segment removal but before the rest restores every byte")
    func killBetweenSegmentRemovalsRestoresBytes() async throws {
        // Two sources, one destination: the applier appends both segments, then
        // removes them. Crashing on the *second* removal leaves the first source
        // already shortened on disk — the state the journal exists for.
        let removals = Counter()
        let harness = try ApplyHarness(failureHook: ApplyFailureHook { step in
            guard case .removeSegment = step else { return }
            if removals.increment() == 2 { throw ApplyError.simulatedCrash(step.description) }
        })
        try await harness.seed("Scratch A.md", "keep a\n\ncurl -sS https://a.example\n")
        try await harness.seed("Scratch B.md", "keep b\n\ncurl -sS https://b.example\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let a = try await harness.id(of: "Scratch A.md")
        let b = try await harness.id(of: "Scratch B.md")
        let target = try await harness.id(of: "Commands/curl.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(a), segment: "curl -sS https://a.example", destination: .existingNote(.id(target))
            )),
            .moveSegment(MoveSegmentAction(
                source: .id(b), segment: "curl -sS https://b.example", destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch A.md", "Scratch B.md"])

        await expectThrows(try await harness.applier.apply(plan)) { error in
            if case .simulatedCrash = error as? ApplyError ?? .noteMissing("") { return true }
            return false
        }
        // Mid-crash the first source really has lost its segment.
        #expect(!(try await harness.body("Scratch A.md")).contains("https://a.example"))
        #expect(try await harness.activity.incompleteEvents().count == 1)

        // "Relaunch."
        _ = harness.restart()
        let outcomes = try await harness.recover()
        #expect(outcomes.count == 1)
        #expect(outcomes[0].resolution == .rolledBack)
        #expect(harness.fingerprint() == before, "recovery must restore the tree byte for byte")
        #expect(try await harness.body("Scratch A.md").contains("https://a.example"))
        #expect(try await harness.body("Scratch B.md").contains("https://b.example"))
        #expect(try await harness.body("Commands/curl.md") == "# curl\n")
        #expect(temp(harness).strayEntries().isEmpty)
    }

    @Test("A kill after an emptied source reached the Trash brings its text back")
    func killAfterTrashingTheSourceRestoresIt() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { $0 == .beforeAfterImages }))
        try await harness.seed("Scratch.md", "curl -sS https://example.com\n")
        try await harness.seed("Commands/curl.md", "# curl\n")
        let source = try await harness.id(of: "Scratch.md")
        let target = try await harness.id(of: "Commands/curl.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .moveSegment(MoveSegmentAction(
                source: .id(source),
                segment: "curl -sS https://example.com",
                destination: .existingNote(.id(target))
            )),
        ], bodiesFor: ["Scratch.md"])
        await expectThrows(try await harness.applier.apply(plan)) { $0 is ApplyError }

        // The source is gone from the library — it emptied and was trashed.
        #expect(!temp(harness).allMarkdownPaths().contains("Scratch.md"))

        _ = harness.restart()
        let outcomes = try await harness.recover()
        #expect(outcomes[0].resolution == .rolledBack)
        #expect(harness.fingerprint() == before)
        #expect(try await harness.body("Scratch.md") == "curl -sS https://example.com\n")
    }

    @Test("A kill after the retitle but before the move rolls the whole plan back")
    func killBetweenRetitleAndMoveRollsBack() async throws {
        let harness = try ApplyHarness(failureHook: .crash(at: { step in
            if case .moveNote = step { return true }
            return false
        }))
        try await harness.seed("Untitled note.md", "auth debugging\n")
        try await harness.store.createFolder("Debugging")
        let note = try await harness.id(of: "Untitled note.md")
        let before = harness.fingerprint()

        let plan = try await harness.plan([
            .retitleNote(RetitleNoteAction(note: .id(note), newTitle: "Auth API debug")),
            .moveNote(MoveNoteAction(note: .id(note), toFolderPath: "Debugging")),
        ])
        await expectThrows(try await harness.applier.apply(plan)) { $0 is ApplyError }
        // The retitle landed: the file is at a path the plan invented.
        #expect(temp(harness).allMarkdownPaths().contains("Auth API debug.md"))

        _ = harness.restart()
        #expect(try await harness.recover()[0].resolution == .rolledBack)
        #expect(harness.fingerprint() == before)
        #expect(temp(harness).allMarkdownPaths() == ["Untitled note.md"])
    }

    // MARK: - (b continued) kill -9 mid-Undo

    @Test("A kill part-way through Undo leaves the event undoable, and a retry finishes it")
    func killDuringUndoLeavesTheEventUndoable() async throws {
        let harness = try ApplyHarness()
        try await harness.seed("Auth.md", "auth notes\n")
        try await harness.seed("Scratch.md", "scratch\n")
        let auth = try await harness.id(of: "Auth.md")
        let scratch = try await harness.id(of: "Scratch.md")
        let before = harness.fingerprint()

        try await harness.apply(try await harness.plan([
            .appendToNote(AppendToNoteAction(target: .id(auth), content: "TOKEN=abc")),
            .appendToNote(AppendToNoteAction(target: .id(scratch), content: "and more")),
        ]))
        let applied = harness.fingerprint()
        #expect(applied != before)

        // Die on the second file Undo rewrites.
        let writes = Counter()
        await harness.store.setFailureHook(StorageFailureHook { step in
            if writes.increment() == 2 { throw StorageError.simulatedCrash(step.description) }
        })
        await expectThrows(try await harness.undo.undoLatest()) { $0 is StorageError }
        await harness.store.setFailureHook(nil)

        // Undo never got as far as recording itself, so the event is still
        // there to be undone — nothing was lost, and nothing is half-undone in
        // the log's view of the world.
        let undoable = try await harness.undo.undoableEvents()
        #expect(undoable.count == 1)

        // "Relaunch" and try again: every byte comes back, and the note the
        // first attempt had already restored counts as restored rather than as
        // a conflict (the reverse patch would otherwise be replayed onto text
        // that is already the before-image).
        let result = try await harness.undoLatest()
        #expect(result.outcome == .complete)
        #expect(result.notes.allSatisfy { $0.action == .restored })
        #expect(harness.fingerprint() == before)
        #expect(try await harness.undo.undoableEvents().isEmpty)
    }

    // MARK: - (c) power loss: an unreadable database

    @Test("Garbage in filaway.sqlite is moved aside and the index rebuilds from the folder")
    func corruptMetadataDatabaseIsQuarantinedAndRebuilt() async throws {
        let temp = try TempLibrary()
        try await temp.store.createFolder("Commands")
        try await temp.store.save(body: "curl -sS https://example.com\n", to: "Commands/curl.md")
        try await temp.store.save(body: "auth notes\n", to: "Auth.md")

        // A first, healthy open, so the file exists with a real schema.
        do {
            let metadata = try MetadataStore(library: temp.library)
            try await metadata.rebuild(from: temp.store.scan(settleWindow: 0))
            #expect(try await metadata.noteCount() == 2)
            #expect(await metadata.recoveredFromCorruption == nil)
        }

        // The power cut: the file is now something else entirely.
        try Data(repeating: 0x5A, count: 8_192).write(to: temp.library.databaseURL)

        let metadata = try MetadataStore(library: temp.library)
        let aside = try #require(await metadata.recoveredFromCorruption)
        #expect(aside.lastPathComponent.hasPrefix("filaway.sqlite.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: aside.path), "the bytes are kept, never deleted")
        #expect(try await metadata.noteCount() == 0)

        // DS-3: everything in there is derived, so the folder puts it back.
        try await metadata.rebuild(from: temp.store.scan(settleWindow: 0))
        #expect(try await metadata.noteCount() == 2)
        #expect(try await metadata.note(relativePath: "Commands/curl.md") != nil)
        #expect(try await metadata.schemaVersion() == DatabaseSchema.version)
        // And the notes themselves were never in danger.
        #expect(temp.allMarkdownPaths() == ["Auth.md", "Commands/curl.md"])
    }

    @Test("A deleted filaway.sqlite rebuilds with no quarantine at all")
    func deletedMetadataDatabaseJustRebuilds() async throws {
        let temp = try TempLibrary()
        try await temp.store.save(body: "one\n", to: "One.md")
        do {
            let metadata = try MetadataStore(library: temp.library)
            try await metadata.rebuild(from: temp.store.scan(settleWindow: 0))
        }
        try FileManager.default.removeItem(at: temp.library.databaseURL)

        let metadata = try MetadataStore(library: temp.library)
        #expect(await metadata.recoveredFromCorruption == nil)
        try await metadata.rebuild(from: temp.store.scan(settleWindow: 0))
        #expect(try await metadata.noteCount() == 1)
    }

    @Test("Garbage in ai-usage.sqlite is moved aside and the ledger starts empty")
    func corruptUsageLedgerIsQuarantined() async throws {
        let temp = try TempLibrary()
        try FileManager.default.createDirectory(
            at: temp.library.supportDirectory, withIntermediateDirectories: true
        )
        let url = AIUsageLedger.url(in: temp.library)
        do {
            let ledger = try AIUsageLedger(library: temp.library)
            #expect(await ledger.recoveredFromCorruption == nil)
        }
        try Data("this is not a database, it is a poem".utf8).write(to: url)

        let ledger = try AIUsageLedger(library: temp.library)
        let aside = try #require(await ledger.recoveredFromCorruption)
        #expect(aside.lastPathComponent.hasPrefix("ai-usage.sqlite.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(try await ledger.totals(from: .distantPast, to: .distantFuture).requests == 0)
    }

    @Test("An unreadable filaway.sqlite is quarantined once, not once per connection")
    func quarantineHappensOncePerCorruption() async throws {
        let temp = try TempLibrary()
        try FileManager.default.createDirectory(
            at: temp.library.supportDirectory, withIntermediateDirectories: true
        )
        try Data(repeating: 0x00, count: 4_096).write(to: temp.library.databaseURL)

        let activity = try ActivityLog(library: temp.library)
        #expect(await activity.recoveredFromCorruption != nil)
        // The second opener finds a healthy file and leaves it alone.
        let metadata = try MetadataStore(library: temp.library)
        #expect(await metadata.recoveredFromCorruption == nil)

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: temp.library.supportDirectory.path)
            .filter { $0.contains(".corrupt-") }
        #expect(quarantined.count == 1)
    }

    @Test("The WAL and shm sidecars travel with a quarantined database")
    func quarantineTakesTheSidecars() async throws {
        let temp = try TempLibrary()
        try FileManager.default.createDirectory(
            at: temp.library.supportDirectory, withIntermediateDirectories: true
        )
        let main = temp.library.databaseURL
        try Data("nonsense".utf8).write(to: main)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: main.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: main.path + "-shm"))

        let aside = try DatabaseFile.moveAside(main, at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!FileManager.default.fileExists(atPath: main.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: aside.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: aside.path + "-shm"))
    }

    // MARK: - Helpers

    private func temp(_ harness: ApplyHarness) -> TempLibrary { harness.temp }
}

/// A counter a `@Sendable` failure hook can close over.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
