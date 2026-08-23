import Foundation
import Testing

@testable import FilawayCore

/// NFR-2: smooth at 5,000 notes. Tagged `.slow` and skippable with
/// `FILAWAY_SKIP_SLOW_TESTS=1`; `filaway-bench scan --notes 5000` reports the
/// same numbers on a release build.
@Suite("Scale (NFR-2)", .tags(.slow), .serialized)
struct ScaleTests {
    static let noteCount = 5_000
    /// Debug builds and CI runners are slower than the release numbers the plan
    /// quotes; the budget is the DoD's 3 s.
    static let budget: TimeInterval = 3.0

    @Test(
        "A full scan and database rebuild of 5,000 notes completes in under 3 s",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(2))
    )
    func scanAndRebuild() async throws {
        let temp = try TempLibrary()
        let written = try SyntheticCorpus.generate(noteCount: Self.noteCount, into: temp.library)
        #expect(written.count == Self.noteCount)

        let metadata = try temp.metadataStore()

        // Warm the directory cache so the measurement is about our work, not the
        // first-touch cost of 5,000 freshly created inodes.
        _ = try await temp.store.scan()

        let scanStart = Date()
        let snapshot = try await temp.store.scan()
        let scanSeconds = Date().timeIntervalSince(scanStart)

        let rebuildStart = Date()
        try await metadata.rebuild(from: snapshot)
        let rebuildSeconds = Date().timeIntervalSince(rebuildStart)

        let total = scanSeconds + rebuildSeconds
        print("""
        [scale] \(Self.noteCount) notes, \(snapshot.notes.reduce(0) { $0 + $1.size } / 1_048_576) MB \
        — scan \(Int(scanSeconds * 1000)) ms, rebuild \(Int(rebuildSeconds * 1000)) ms, total \(Int(total * 1000)) ms
        """)

        #expect(snapshot.notes.count == Self.noteCount)
        #expect(try await metadata.noteCount() == Self.noteCount, "no note may be lost or duplicated")
        #expect(total < Self.budget, "scan + rebuild took \(total) s, budget \(Self.budget) s")
    }

    @Test(
        "A reconcile over an unchanged 5,000-note library is a no-op",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(2))
    )
    func steadyStateReconcile() async throws {
        let temp = try TempLibrary()
        try SyntheticCorpus.generate(noteCount: Self.noteCount, into: temp.library)
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata)

        try await watcher.reconcile()
        #expect(try await metadata.noteCount() == Self.noteCount)

        let start = Date()
        let changes = try await watcher.reconcile()
        let seconds = Date().timeIntervalSince(start)
        print("[scale] steady-state reconcile \(Int(seconds * 1000)) ms")

        #expect(changes.isEmpty, "an unchanged library must produce no changes")
        #expect(try await metadata.noteCount() == Self.noteCount)
        #expect(seconds < Self.budget)
    }

    @Test(
        "Identities survive a rebuild of a large library",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(2))
    )
    func identityStability() async throws {
        let temp = try TempLibrary()
        try SyntheticCorpus.generate(noteCount: 1_000, into: temp.library)
        let metadata = try temp.metadataStore()
        let snapshot = try await temp.store.scan()
        try await metadata.rebuild(from: snapshot)
        let before = try await metadata.allNotes()

        try await metadata.rebuild(from: try await temp.store.scan())
        let after = try await metadata.allNotes()
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.relativePath) == after.map(\.relativePath))
        #expect(Set(after.map(\.id)).count == after.count, "identities must be unique")
    }
}
