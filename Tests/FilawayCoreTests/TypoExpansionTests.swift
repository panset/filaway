import Foundation
import Testing

@testable import FilawayCore

/// M4-07's typo lever: query words the library has never indexed are repaired
/// from FTS5's own term index (see `TypoExpansion`).
@Suite("Typo expansion (M4-07)")
struct TypoExpansionTests {

    /// Two notes, chunked and embedded, so the whole hybrid path is real.
    private func fixture() async throws -> HybridSearchTests.Fixture {
        let fixture = try HybridSearchTests.Fixture()
        try await fixture.addNote("Commands/curl/Staging docs endpoint.md", """
            Fetch the staging documents with an authorization header.

            ```bash
            curl -H "Authorization: Bearer $STAGING_TOKEN" https://api.staging/docs
            ```
            """)
        try await fixture.addNote("Infra/ssh/Deploying the built site.md", """
            Push the built site to the server once the build is green.

            ```bash
            rsync -avz --delete build/ deploy@server:/srv/site
            ```
            """)
        try await fixture.indexEverything()
        return fixture
    }

    @Test("the FTS term index is readable, and names the word a typo is near")
    func vocabularyLoads() async throws {
        let fixture = try await self.fixture()

        let vocabulary = try await fixture.metadata.reader.read { db in
            try TypoExpansion.Vocabulary.load(db, minimumDocuments: 1)
        }
        #expect(!vocabulary.isEmpty)
        #expect(vocabulary.contains("curl"))
        #expect(vocabulary.contains("staging"))
        #expect(vocabulary.nearest(to: "crul").first == "curl")
        #expect(vocabulary.nearest(to: "stagign").first == "staging")
        #expect(vocabulary.nearest(to: "rsyncc").first == "rsync")
        // A word the library really does contain is never "corrected".
        #expect(vocabulary.contains("rsync"))
    }

    @Test("the gate is exactly the words the library has never indexed")
    func unknownTermsGate() async throws {
        let fixture = try await self.fixture()

        let unknown = try await fixture.metadata.reader.read { db in
            try TypoExpansion.Vocabulary.unknownTerms(
                db, terms: ["crul", "curl", "stagign", "staging", "docs"]
            )
        }
        #expect(Set(unknown) == ["crul", "stagign"])
    }

    @Test("a repair rewrites the sentence for the embedder and widens the OR for FTS5")
    func repairShape() {
        let vocabulary = TypoExpansion.Vocabulary.make([
            ("curl", 40), ("staging", 30), ("docs", 90), ("command", 120), ("curly", 2),
        ])
        let repair = vocabulary.repair(["crul", "stagign"])
        #expect(repair.corrections["crul"]?.first == "curl")
        #expect(repair.corrections["stagign"]?.first == "staging")
        #expect(Set(repair.extraTerms).isSuperset(of: ["curl", "staging"]))
        #expect(repair.rewrite("the crul command for stagign docs")
            == "the curl command for staging docs")
    }

    @Test("nothing to repair is the common case, and it is free")
    func noRepair() {
        let vocabulary = TypoExpansion.Vocabulary.make([("curl", 40), ("staging", 30)])
        let repair = vocabulary.repair(["curl", "staging"])
        #expect(repair.isEmpty)
        #expect(repair.extraTerms.isEmpty)
        #expect(repair.rewrite("curl staging") == "curl staging")
    }

    @Test("two characters is too short to repair, and one edit is the whole budget")
    func theBudgetIsOneEdit() {
        let vocabulary = TypoExpansion.Vocabulary.make([("curl", 40), ("pod", 12), ("pdf", 30)])
        #expect(vocabulary.nearest(to: "cu").isEmpty)
        #expect(TypoExpansion.tolerance(forLength: 2) == 0)
        #expect(TypoExpansion.tolerance(forLength: 5) == 1)
        // Never two, however long the word: a two-edit budget finds no extra
        // typo in the M3-07 set and turns correctly-spelt words the library
        // happens not to contain into other people's words (M4-07).
        #expect(TypoExpansion.tolerance(forLength: 12) == 1)
        #expect(vocabulary.nearest(to: "curllll").isEmpty)
        // Between two words a three-letter typo could be, the commoner wins.
        #expect(vocabulary.nearest(to: "pdo").first == "pdf")
    }

    @Test("a misspelt query reaches the note the correct spelling would have")
    func misspeltQueryFindsTheNote() async throws {
        let fixture = try await self.fixture()

        let repaired = await fixture.hybrid.semanticCandidates("the crul command for stagign docs")
        #expect(repaired.notes.first?.title == "Staging docs endpoint")

        // The misspelt words really did reach the keyword arm: with the lever
        // off the query has no term FTS5 has ever seen except the common ones,
        // so the BM25 arm contributes nothing.
        let unrepaired = await fixture.hybrid.semanticCandidates(
            "crul stagign",
            options: HybridSearch.Options(typoExpansion: false)
        )
        #expect(unrepaired.chunks.allSatisfy { $0.keywordRank == nil })

        let repairedTerms = await fixture.hybrid.semanticCandidates("crul stagign")
        #expect(repairedTerms.notes.first?.title == "Staging docs endpoint")
        #expect(repairedTerms.chunks.contains { $0.keywordRank != nil })
    }
}
