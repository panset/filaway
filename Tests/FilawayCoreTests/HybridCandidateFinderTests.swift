import Foundation
import Testing

@testable import FilawayCore

/// M3-08 — the organizer's merge-target retrieval, on the hybrid index.
@Suite("HybridCandidateFinder (M3-08)")
struct HybridCandidateFinderTests {

    struct Fixture {
        let temp: TempLibrary
        let metadata: MetadataStore
        let embedder: HashedEmbedder
        let vectors: VectorStore
        let indexer: Indexer
        let hybrid: HybridSearch
        var notes: [String: NoteSummary] = [:]

        init(excluding exclusions: ExclusionFilter = .none) throws {
            temp = try TempLibrary()
            metadata = try temp.metadataStore()
            embedder = HashedEmbedder(dimension: 256)
            vectors = VectorStore(
                reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
            )
            indexer = Indexer(
                metadata: metadata, embedder: embedder, vectorStore: vectors,
                configuration: .init(debounce: .zero),
                isExcluded: { exclusions.isExcluded(path: $0) }
            )
            hybrid = HybridSearch(metadata: metadata, embedder: embedder, vectorStore: vectors)
        }

        mutating func load(_ corpus: [(String, String)]) async throws {
            for (path, body) in corpus { try temp.writeExternal(body, to: path) }
            let snapshot = try await temp.store.scan()
            try await metadata.upsert(snapshot.notes)
            for note in snapshot.notes { notes[note.relativePath] = note }
            _ = try await indexer.catchUp()
            try await vectors.reload()
            await hybrid.invalidate()
        }

        /// The snapshot the organizer would build, with bodies.
        func context(excludedFolders: [String] = []) async throws -> OrganizeContext {
            let snapshot = try await temp.store.scan()
            var bodies: [NoteID: String] = [:]
            for note in snapshot.notes {
                bodies[note.id] = try await temp.store.read(note.relativePath).body
            }
            return OrganizeContext(
                snapshot: snapshot, excludedFolders: excludedFolders, bodies: bodies
            )
        }
    }

    static let corpus: [(String, String)] = [
        ("Commands/curl.md", """
        # curl

        Handy invocations for the documents API.

        ```sh
        curl -sS -H "Accept: application/json" https://example.test/documents
        ```
        """),
        ("Commands/Kubernetes.md", """
        # Kubernetes

        Rollouts and probes.

        ```sh
        kubectl rollout restart deployment/api
        kubectl rollout status deployment/api
        ```
        """),
        ("Standup.md", "# Standup\n\n- shipped the markdown parser\n- reviewed the sidebar\n"),
        ("Scratch.md", """
        kubernetes rollout notes:

        ```sh
        kubectl rollout restart deployment/web
        ```

        the readiness probe needs a longer initial delay
        """),
    ]

    static func query(_ text: String, excluding: Set<NoteID> = [], limit: Int = 6) -> CandidateQuery {
        CandidateQuery(text: text, excluding: excluding, limit: limit)
    }

    @Test("the session's subject finds the note about it, title overlap or not")
    func findsTopicalNote() async throws {
        var fixture = try Fixture()
        try await fixture.load(Self.corpus)
        let context = try await fixture.context()
        let scratch = try #require(fixture.notes["Scratch.md"])

        let finder = HybridCandidateFinder(hybrid: fixture.hybrid)
        let candidates = try await finder.candidates(
            for: Self.query(Self.corpus[3].1, excluding: [scratch.id]), in: context
        )

        #expect(!candidates.isEmpty)
        let best = try #require(candidates.first)
        #expect(context.note(id: best.noteID)?.relativePath == "Commands/Kubernetes.md")
        #expect(!candidates.contains { $0.noteID == scratch.id }, "a session note is never its own target")
    }

    @Test("the title finder would have missed it")
    func beatsTheTitleFinder() async throws {
        var fixture = try Fixture()
        try await fixture.load(Self.corpus)
        let context = try await fixture.context()
        let scratch = try #require(fixture.notes["Scratch.md"])
        // The word "kubectl" appears in no title; only bodies carry it.
        let query = Self.query("kubectl rollout restart the api deployment", excluding: [scratch.id])

        let title = try await TitleOverlapCandidateFinder().candidates(for: query, in: context)
        let hybrid = try await HybridCandidateFinder(hybrid: fixture.hybrid)
            .candidates(for: query, in: context)

        #expect(title.isEmpty || context.note(id: title[0].noteID)?.relativePath != "Commands/Kubernetes.md")
        #expect(context.note(id: hybrid[0].noteID)?.relativePath == "Commands/Kubernetes.md")
    }

    @Test("an empty index falls through to the title finder rather than to nothing")
    func fallsBackWhenTheIndexIsEmpty() async throws {
        var fixture = try Fixture()
        // Notes in the database, nothing indexed.
        for (path, body) in Self.corpus { try fixture.temp.writeExternal(body, to: path) }
        let snapshot = try await fixture.temp.store.scan()
        try await fixture.metadata.upsert(snapshot.notes)
        let context = try await fixture.context()

        let finder = HybridCandidateFinder(hybrid: fixture.hybrid)
        let candidates = try await finder.candidates(
            for: Self.query("kubernetes rollout restart deployment notes"), in: context
        )
        #expect(!candidates.isEmpty, "the organizer must still see merge targets")
        #expect(context.note(id: candidates[0].noteID)?.relativePath == "Commands/Kubernetes.md")
    }

    @Test("an excluded folder is never a candidate (FR-4.5)")
    func exclusions() async throws {
        var fixture = try Fixture(excluding: ExclusionFilter(excludedFolders: ["Private"]))
        try await fixture.load(Self.corpus + [
            ("Private/Kubernetes pay.md", """
            # Kubernetes pay

            kubectl rollout restart deployment/api — and the compensation figure is 88888
            """),
        ])
        // The organizer's context has already been filtered.
        let context = try await fixture.context(excludedFolders: ["Private"])
        #expect(context.notes.allSatisfy { !$0.relativePath.hasPrefix("Private/") })

        let finder = HybridCandidateFinder(hybrid: fixture.hybrid)
        let candidates = try await finder.candidates(
            for: Self.query("kubectl rollout restart deployment/api"), in: context
        )
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { candidate in
            context.note(id: candidate.noteID)?.relativePath.hasPrefix("Private/") == false
        })
    }

    @Test("the limit is honoured and a zero limit asks nothing")
    func limits() async throws {
        var fixture = try Fixture()
        try await fixture.load(Self.corpus)
        let context = try await fixture.context()
        let finder = HybridCandidateFinder(hybrid: fixture.hybrid)

        let one = try await finder.candidates(for: Self.query("kubectl rollout", limit: 1), in: context)
        #expect(one.count <= 1)
        let none = try await finder.candidates(for: Self.query("kubectl rollout", limit: 0), in: context)
        #expect(none.isEmpty)
    }

    @Test("only notes the organizer can name come back")
    func candidatesAreInTheContext() async throws {
        var fixture = try Fixture()
        try await fixture.load(Self.corpus)
        // A context that has forgotten one indexed note — a snapshot taken
        // before it was deleted, say.
        let full = try await fixture.context()
        let trimmed = OrganizeContext(
            notes: full.notes.filter { $0.relativePath != "Commands/Kubernetes.md" },
            folderPaths: full.folderPaths,
            excludedFolders: [],
            bodies: full.bodies
        )
        let finder = HybridCandidateFinder(hybrid: fixture.hybrid)
        let candidates = try await finder.candidates(
            for: Self.query("kubectl rollout restart deployment/api"), in: trimmed
        )
        #expect(candidates.allSatisfy { trimmed.note(id: $0.noteID) != nil })
    }

    @Test("the query is capped, titles first")
    func queryText() {
        let query = CandidateQuery(
            text: String(repeating: "a", count: 5_000), titles: ["Scratch", PathRules.untitled]
        )
        let text = HybridCandidateFinder.queryText(query, limit: 100)
        #expect(text.count == 100)
        #expect(text.hasPrefix("Scratch"))
        #expect(!text.contains(PathRules.untitled), "an untitled note's title says nothing")
    }
}
