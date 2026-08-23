import Foundation
import Testing

@testable import FilawayCore

/// M4-02 — FR-4.5's second half: excluding a folder in Settings has to *remove*
/// what is already in the semantic index, not merely stop adding to it.
///
/// The app side of this lives in `SemanticSearchCoordinator.purgeExcluded(_:)`,
/// which walks the library and re-indexes every note the new filter covers —
/// `Indexer.index(noteID:)` purges an excluded note. What is pinned here is the
/// two Core facts that makes it work, both of which are easy to break by
/// accident:
///
/// 1. `Indexer.catchUp()` *cannot* do this job. An indexed note whose bytes have
///    not changed is not stale, so it is never revisited — which is exactly the
///    note a newly excluded folder is full of.
/// 2. `MetadataStore.chunkCount(inFolder:)` is what "the chunks are gone" is
///    asserted with, in the tests and in the `settings-wiring` smoke phase.
@Suite("Exclusion purge (FR-4.5)")
struct ExclusionPurgeTests {

    /// The exclusion list a test flips, behind the `@Sendable` closure the
    /// `Indexer` holds for the life of the process.
    private final class ExclusionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var filter = ExclusionFilter.none

        var current: ExclusionFilter {
            lock.lock()
            defer { lock.unlock() }
            return filter
        }

        func set(_ folders: [String]) {
            lock.lock()
            defer { lock.unlock() }
            filter = ExclusionFilter(excludedFolders: folders)
        }
    }

    private static let body = """
    # A note with something to say

    A first paragraph, long enough that the chunker has real text to work with
    rather than a single line it might merge away.

    ## A second section

    And a second paragraph, so every note here produces more than one chunk and
    a count of zero afterwards means something.
    """

    private func fixture(_ box: ExclusionBox) throws -> IndexerTests.Fixture {
        try IndexerTests.Fixture(isExcluded: { [box] path in box.current.isExcluded(path: path) })
    }

    @Test("chunkCount sees the whole library and one folder's share of it")
    func chunkCountScopes() async throws {
        let box = ExclusionBox()
        let fixture = try fixture(box)
        try await fixture.addNote("Personal/Weekend.md", Self.body)
        try await fixture.addNote("Personal/Deeper/Garden.md", Self.body)
        try await fixture.addNote("Commands/curl.md", Self.body)
        _ = try await fixture.indexer.catchUp()

        let all = try await fixture.metadata.chunkCount()
        let personal = try await fixture.metadata.chunkCount(inFolder: "Personal")
        let commands = try await fixture.metadata.chunkCount(inFolder: "Commands")

        #expect(all > 0)
        #expect(personal > 0)
        #expect(commands > 0)
        // A folder's count includes its subfolders — exclusion is a prefix rule,
        // and a count that stopped at one level would quietly under-report.
        #expect(personal + commands == all)
        #expect(try await fixture.metadata.chunkCount(inFolder: "Personal/Deeper") > 0)
    }

    @Test("catchUp alone leaves a newly excluded folder indexed")
    func catchUpDoesNotPurge() async throws {
        let box = ExclusionBox()
        let fixture = try fixture(box)
        try await fixture.addNote("Personal/Weekend.md", Self.body)
        try await fixture.addNote("Commands/curl.md", Self.body)
        _ = try await fixture.indexer.catchUp()
        #expect(try await fixture.metadata.chunkCount(inFolder: "Personal") > 0)

        box.set(["Personal"])
        _ = try await fixture.indexer.catchUp()

        // Nothing changed on disk, so nothing is stale, so nothing is revisited.
        // This is the reason `purgeExcluded` exists at all.
        #expect(try await fixture.metadata.chunkCount(inFolder: "Personal") > 0)
    }

    @Test("re-indexing each excluded note purges its chunks and leaves the rest")
    func purgingExcludedNotes() async throws {
        let box = ExclusionBox()
        let fixture = try fixture(box)
        try await fixture.addNote("Personal/Weekend.md", Self.body)
        try await fixture.addNote("Personal/Deeper/Garden.md", Self.body)
        try await fixture.addNote("Commands/curl.md", Self.body)
        _ = try await fixture.indexer.catchUp()
        let elsewhereBefore = try await fixture.metadata.chunkCount(inFolder: "Commands")
        #expect(elsewhereBefore > 0)

        box.set(["Personal"])
        let filter = box.current
        var purged = 0
        for note in try await fixture.metadata.allNotes()
        where filter.isExcluded(path: note.relativePath) {
            purged += try await fixture.indexer.index(noteID: note.id).notesPurged
        }

        #expect(purged == 2)
        #expect(try await fixture.metadata.chunkCount(inFolder: "Personal") == 0)
        #expect(try await fixture.metadata.chunkCount(inFolder: "Commands") == elsewhereBefore)
    }

    @Test("un-excluding a folder makes its notes stale again, so catchUp indexes them")
    func unExcludingReindexes() async throws {
        let box = ExclusionBox()
        box.set(["Personal"])
        let fixture = try fixture(box)
        try await fixture.addNote("Personal/Weekend.md", Self.body)
        try await fixture.addNote("Commands/curl.md", Self.body)
        _ = try await fixture.indexer.catchUp()
        #expect(try await fixture.metadata.chunkCount(inFolder: "Personal") == 0)

        box.set([])
        _ = try await fixture.indexer.catchUp()

        #expect(try await fixture.metadata.chunkCount(inFolder: "Personal") > 0)
    }
}
