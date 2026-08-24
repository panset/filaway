import Foundation
import Testing
@testable import FilawayCore

/// Regression for the `semantic` smoke phase's offline sub-checks
/// (`offline-card-is-local`): with no provider, ``AnswerHeuristic`` must still
/// produce the Figure-2b answer card for the canonical query on the canonical
/// three-note smoke corpus (Tools/smoke.sh `seed_search_corpus`). Broke after
/// M4-07's ranking changes. Uses the bundled Core ML embedder.
@Suite("Offline answer card (semantic smoke regression)")
struct OfflineAnswerRegressionTests {

    static let curl = #"curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs"#
    static let query = "curl command to fetch documents"

    @Test("the canonical offline query still yields a local card",
          .enabled(if: BundledEmbeddingModel.isAvailable))
    func offlineCard() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let embedder = try await BundledModelCache.shared.load()
        let vectors = VectorStore(
            reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
        )
        let indexer = Indexer(
            metadata: metadata, embedder: embedder, vectorStore: vectors,
            configuration: .init(debounce: .zero)
        )
        let hybrid = HybridSearch(metadata: metadata, embedder: embedder, vectorStore: vectors)

        var staging = "Notes from the staging spike.\n\n"
        for i in 1...160 {
            staging += "Line \(i) — background on the staging environment and its quirks.\n"
        }
        staging += "\ncurl to fetch docs from staging:\n\n```bash\n\(Self.curl)\n```\n\nremember: token expires hourly\n"
        try temp.writeExternal(staging, to: "Commands/Staging docs.md")
        try temp.writeExternal(
            "The 401 only happens after the bearer token rotates.\n\n- [ ] rotate the staging token\n- [ ] check the refresh window\n",
            to: "Auth API debug.md")
        try temp.writeExternal(
            "Handy container commands.\n\n```bash\ncurl -fsS http://localhost:8080/healthz\n```\n",
            to: "Docker cheats.md")

        // Tools/smoke.sh sets these with `touch -t`: staging -10d, auth -2d, docker -20d.
        func setAge(_ path: String, days: Int) throws {
            let url = temp.root.appendingPathComponent(path)
            let date = Date(timeIntervalSinceNow: -Double(days) * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try setAge("Commands/Staging docs.md", days: 10)
        try setAge("Auth API debug.md", days: 2)
        try setAge("Docker cheats.md", days: 20)

        let snapshot = try await temp.store.scan()
        try await metadata.upsert(snapshot.notes)
        _ = try await indexer.catchUp()
        try await vectors.reload()
        await hybrid.invalidate()

        let results = await hybrid.semanticCandidates(Self.query)
        let heuristic = AnswerHeuristic()
        let margin = heuristic.margin(of: results.chunks)
        let coverage = results.chunks.first.map { heuristic.coverage(of: Self.query, in: $0.text) } ?? -1
        print("DIAG margin=\(margin) coverage=\(coverage)")
        for (i, c) in results.chunks.prefix(4).enumerated() {
            print("DIAG #\(i) score=\(c.score) kind=\(c.kind) note=\(c.title) vr=\(String(describing: c.vectorRank)) kr=\(String(describing: c.keywordRank)) text=\(c.text.prefix(44))")
        }
        let card = heuristic.card(query: Self.query, chunks: results.chunks)
        #expect(card != nil, "no local card (margin \(margin), coverage \(coverage))")
        #expect(card?.snippetText.contains("api.st.app") == true)
    }
}
