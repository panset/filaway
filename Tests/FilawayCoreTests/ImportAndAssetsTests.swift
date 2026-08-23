import Foundation
import Testing

@testable import FilawayCore

/// M4-10 — the deferred-feature stubs: FR-7.2's importer contract and FR-2.5's
/// reserved `_assets/` folder.
@Suite("Importer stub (FR-7.2)")
struct ImporterStubTests {

    @Test("Apple Notes reports itself unavailable rather than pretending")
    func unavailable() {
        let importer = AppleNotesImporter()
        #expect(!importer.isAvailable)
        #expect(importer.displayName == "Apple Notes…")
    }

    @Test("discover throws the Phase 1.x message")
    func discoverThrows() async {
        let importer = AppleNotesImporter()
        await #expect(throws: ImportError.notAvailableInThisVersion(AppleNotesImporter.unavailableMessage)) {
            _ = try await importer.discover()
        }
    }

    @Test("importNotes throws the same message")
    func importThrows() async throws {
        let temp = try TempLibrary()
        let importer = AppleNotesImporter()
        let candidate = ImportCandidate(id: "x", title: "Auth API debug", body: "the 401 again")
        await #expect(throws: ImportError.self) {
            _ = try await importer.importNotes([candidate], into: temp.store, progress: nil)
        }
    }

    @Test("the message points at the workaround, not at a dead end")
    func message() {
        #expect(AppleNotesImporter.unavailableMessage.contains("Phase 1.x"))
        #expect(AppleNotesImporter.unavailableMessage.contains(".md"))
    }

    @Test("ImportReport counts what landed")
    func report() {
        let report = ImportReport(imported: ["a.md", "b.md"], skipped: ["c"], failed: [])
        #expect(report.count == 2)
        #expect(ImportReport().count == 0)
    }
}

@Suite("Reserved _assets/ folder (FR-2.5)")
struct AssetsFolderTests {

    @Test("_assets is reserved at the root only")
    func reserved() {
        #expect(PathRules.isReservedPath("_assets"))
        #expect(PathRules.isReservedPath("_assets/shot.png"))
        #expect(PathRules.isReservedPath("_assets/2026/shot.png"))
        #expect(!PathRules.isReservedPath("Commands/_assets/shot.png"))
        #expect(!PathRules.isReservedPath("Commands"))
        #expect(!PathRules.isReservedPath(""))
    }

    @Test("nothing inside _assets is a note")
    func notANote() {
        #expect(!PathRules.isNotePath("_assets/notes.md"))
        #expect(!PathRules.isNotePath("_assets/deep/notes.md"))
        #expect(PathRules.isNotePath("Commands/curl.md"))
        #expect(PathRules.isNotePath("Commands/_assets/curl.md"))
    }

    @Test("the scanner skips _assets entirely")
    func scanSkipsAssets() throws {
        let temp = try TempLibrary()
        let root = temp.library.root
        let assets = root.appendingPathComponent("_assets/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: assets.appendingPathComponent("shot.png"))
        // Even a Markdown file in there is not a note.
        try Data("# not a note".utf8).write(to: assets.appendingPathComponent("caption.md"))

        let commands = root.appendingPathComponent("Commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try Data("curl -sS https://api.st.app".utf8).write(to: commands.appendingPathComponent("curl.md"))

        let snapshot = try NoteStore.scan(library: temp.library, settleWindow: 0)
        #expect(snapshot.notes.map(\.relativePath) == ["Commands/curl.md"])
        #expect(snapshot.folderPaths == ["Commands"])
        #expect(!snapshot.folderPaths.contains("_assets"))
    }
}
