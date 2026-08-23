import Foundation
import Testing

@testable import FilawayCore

/// The automated half of the DS-4 stress check (risk #3).
///
/// `Tools/fs_churn.sh` runs the same operation mix against a live app so a human
/// can watch the sidebar; this runs it in-process against the store and watcher
/// and asserts the invariants the M1 DoD names: **no data loss, no duplicate
/// notes, moves tracked, conflict copy only when the buffer is dirty**.
@Suite("Filesystem churn (DS-4, risk #3)", .tags(.slow), .serialized)
struct ChurnTests {
    /// Mirrors the operation mix in `Tools/fs_churn.sh`.
    enum Operation: CaseIterable {
        case create, edit, rewriteAtomically, move, rename, delete, appSave, appMove
    }

    @Test(
        "Random external churn loses nothing, duplicates nothing and tracks moves",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(2))
    )
    func churn() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata)
        let folders = ["", "Commands", "Ideas", "Commands/Docker", "Ideas/Weekly"]
        for folder in folders where !folder.isEmpty { try temp.makeExternalFolder(folder) }

        var random = SplitMix64(seed: 0xC0FF_EE00_1234_5678)
        var appOwned: [String] = []          // notes created through the store
        var liveBodies: [String: String] = [:]  // relpath -> body we believe is on disk
        var observedMoves = 0

        func pick<T>(_ values: [T], _ random: inout SplitMix64) -> T? {
            values.isEmpty ? nil : values[Int(random.next() % UInt64(values.count))]
        }

        for step in 0 ..< 220 {
            let existing = temp.allMarkdownPaths()
            let operation = Operation.allCases[Int(random.next() % UInt64(Operation.allCases.count))]

            switch operation {
            case .create:
                let folder = pick(folders, &random) ?? ""
                let stem = "churn \(step)"
                let path = try await temp.store.freeRelativePath(folder: folder, title: stem)
                let body = "# \(stem)\n\nexternal create \(step)\n"
                try temp.writeExternal(body, to: path)
                liveBodies[path] = body

            case .edit:
                guard let path = pick(existing, &random) else { continue }
                let body = (try? temp.readExternal(path)).map { $0 + "external edit \(step)\n" } ?? "edit \(step)\n"
                try temp.writeExternal(body, to: path)
                liveBodies[path] = body

            case .rewriteAtomically:
                // What an editor with atomic save does: temp file plus rename.
                guard let path = pick(existing, &random) else { continue }
                let body = "rewritten \(step)\n"
                let staging = temp.base.appendingPathComponent("staging-\(step).md")
                try Data(body.utf8).write(to: staging)
                let destination = temp.url(path)
                _ = try? FileManager.default.replaceItemAt(destination, withItemAt: staging)
                liveBodies[path] = body

            case .move:
                guard let path = pick(existing, &random), let folder = pick(folders, &random) else { continue }
                let target = try await temp.store.freeRelativePath(folder: folder, title: PathRules.title(of: path))
                guard target != path else { continue }
                try temp.moveExternal(path, to: target)
                liveBodies[target] = liveBodies.removeValue(forKey: path)
                appOwned = appOwned.map { $0 == path ? target : $0 }

            case .rename:
                guard let path = pick(existing, &random) else { continue }
                let target = try await temp.store.freeRelativePath(
                    folder: PathRules.folderPath(of: path),
                    title: "renamed \(step)"
                )
                try temp.moveExternal(path, to: target)
                liveBodies[target] = liveBodies.removeValue(forKey: path)
                appOwned = appOwned.map { $0 == path ? target : $0 }

            case .delete:
                guard let path = pick(existing, &random) else { continue }
                try temp.removeExternal(path)
                liveBodies[path] = nil
                appOwned.removeAll { $0 == path }

            case .appSave:
                // The app itself writing, interleaved with the churn.
                if let path = pick(appOwned, &random) {
                    let body = "app save \(step)\n"
                    try await temp.store.save(body: body, to: path)
                    liveBodies[path] = try temp.readExternal(path)
                } else {
                    let note = try await temp.store.createNote(inFolder: pick(folders, &random) ?? "", title: "app \(step)")
                    appOwned.append(note.relativePath)
                    liveBodies[note.relativePath] = try temp.readExternal(note.relativePath)
                }

            case .appMove:
                guard let path = pick(appOwned, &random), let folder = pick(folders, &random) else { continue }
                let moved = try await temp.store.move(path, toFolder: folder)
                liveBodies[moved.relativePath] = liveBodies.removeValue(forKey: path)
                appOwned = appOwned.map { $0 == path ? moved.relativePath : $0 }
            }

            // Reconcile every few operations, the way a coalesced FSEvents batch
            // would, and once more at the end.
            if step % 3 == 0 || step == 219 {
                let changes = try await watcher.reconcile()
                observedMoves += changes.count { if case .moved = $0 { return true } else { return false } }
            }
        }

        try await watcher.reconcile()

        // 1. No data loss: every file on disk is a row, byte-identical.
        let onDisk = temp.allMarkdownPaths()
        let rows = try await metadata.allNotes()
        #expect(rows.map(\.relativePath).sorted() == onDisk, "database and disk disagree")
        for row in rows {
            let raw = try temp.readExternal(row.relativePath)
            #expect(row.contentHash == Hashing.sha256Hex(raw), "stale hash for \(row.relativePath)")
        }

        // 2. No duplicates: one row per path, one identity per row.
        #expect(Set(rows.map(\.relativePath)).count == rows.count, "duplicate paths in the database")
        #expect(Set(rows.map(\.id)).count == rows.count, "duplicate identities in the database")

        // 3. Moves were tracked, not seen as delete + create.
        #expect(observedMoves > 0, "the churn never produced a tracked move")

        // 4. DS-1: nothing but .md files and folders in the notes root.
        #expect(temp.strayEntries().isEmpty, "stray files in the notes root: \(temp.strayEntries())")

        // 5. No conflict copies without a dirty buffer.
        #expect(!onDisk.contains { $0.contains("(external edit ") }, "a conflict copy appeared with no dirty buffer")

        // 6. The library is settled: reconciling again finds nothing.
        #expect(try await watcher.reconcile().isEmpty)
    }

    @Test(
        "Churn around a dirty buffer produces exactly one conflict copy and loses neither version",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(2))
    )
    func churnWithDirtyBuffer() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata)

        let note = try await temp.store.createNote(inFolder: "Commands", title: "curl")
        try await temp.store.save(body: "saved body\n", to: note.relativePath)
        try await watcher.reconcile()

        var random = SplitMix64(seed: 0xDEAD_BEEF_0000_0001)
        for step in 0 ..< 40 {
            switch random.next() % 3 {
            case 0:
                try temp.writeExternal("noise \(step)\n", to: "noise \(step).md")
            case 1:
                let existing = temp.allMarkdownPaths().filter { $0 != note.relativePath }
                if let path = existing.first { try temp.removeExternal(path) }
            default:
                try temp.writeExternal("---\nid: \(note.id.uuidString)\n---\nexternal \(step)\n", to: note.relativePath)
            }
            if step % 4 == 0 { try await watcher.reconcile() }
        }

        // The user's buffer diverged from the file all along; autosave resolves.
        try temp.writeExternal("---\nid: \(note.id.uuidString)\n---\nfinal external\n", to: note.relativePath)
        let resolution = try await watcher.resolveExternalChange(noteID: note.id, inMemoryText: "my buffer\n")
        try await watcher.reconcile()

        let copyPath = try #require(resolution.externalCopyPath)
        #expect(try await temp.store.read(note.relativePath).body == "my buffer\n", "the buffer must win")
        #expect(try await temp.store.read(copyPath).body == "final external\n", "the external version must survive")

        let copies = temp.allMarkdownPaths().filter { $0.contains("(external edit ") }
        #expect(copies.count == 1, "expected exactly one conflict copy, got \(copies)")

        let rows = try await metadata.allNotes()
        #expect(Set(rows.map(\.id)).count == rows.count, "the conflict copy must not clone an identity")
        #expect(rows.map(\.relativePath).sorted() == temp.allMarkdownPaths())
        #expect(try await watcher.reconcile().isEmpty)
    }
}
