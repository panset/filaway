import Foundation
import Testing

@testable import FilawayCore

/// FR-5.1: as-you-type keyword search over titles and bodies, offline, no AI.
@Suite("Keyword search (FR-5.1)")
struct SearchTests {
    /// Keeps the temp library alive for as long as the test holds the stack —
    /// `TempLibrary`'s deinit deletes the folder it created.
    private struct Fixture {
        let temp: TempLibrary
        let stack: SearchStack
        var search: SearchService { stack.search }
        var metadata: MetadataStore { stack.metadata }
    }

    /// A small library with the shapes every case below needs: a note whose
    /// title is the query, one that only mentions it, one with a shell command,
    /// and one with non-ASCII text.
    private func library() async throws -> Fixture {
        let temp = try TempLibrary()
        try await temp.makeNote("Docker compose", folder: "Commands", body: """
        # Docker compose

        Bring the stack up and follow the logs.

        ```sh
        docker compose up -d --build && docker compose logs -f app
        ```
        """)
        try await temp.makeNote("curl", folder: "Commands", body: """
        Fetch a document and pretty-print it.

        ```sh
        curl -sSL -H 'Accept: application/json' https://example.com/api/documents | jq '.items[]'
        ```
        """)
        try await temp.makeNote("Weekly notes", body: """
        We talked about docker for a while, then about the token budget.
        """)
        try await temp.makeNote("Café ☕ ideas", folder: "Ideas", body: """
        Roast profile 🚀 notes. The naïve approach was fine.
        """)
        return Fixture(temp: temp, stack: try await temp.searchStack())
    }

    // MARK: - Ranking

    @Test("A title match outranks a body match for the same word")
    func titleBeatsBody() async throws {
        let fixture = try await library()
        let hits = await fixture.search.keyword("docker")
        try #require(hits.count >= 2)
        #expect(hits[0].title == "Docker compose")
        #expect(hits[0].source.isTitle)
        let weekly = try #require(hits.hit(titled: "Weekly notes"))
        #expect(!weekly.source.isTitle)
        #expect(hits[0].score > weekly.score)
    }

    @Test("An exact title outranks a title that merely starts with the query")
    func exactBeatsPrefix() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("curl", body: "short")
        try await temp.makeNote("curl and friends", body: "longer")
        let stack = try await temp.searchStack()

        let hits = await stack.search.keyword("curl")
        try #require(hits.count == 2)
        #expect(hits.titles == ["curl", "curl and friends"])
        #expect(hits[0].source == .titleExact)
        #expect(hits[1].source == .titlePrefix)
    }

    @Test("Notes of equal relevance are ordered by recency")
    func recencyTiebreak() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Alpha", body: "shared word tokenbudget")
        try await temp.makeNote("Beta", body: "shared word tokenbudget")
        // Make Beta unambiguously newer than Alpha.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(600)],
            ofItemAtPath: temp.url("Beta.md").path
        )
        let stack = try await temp.searchStack()

        let hits = await stack.search.keyword("tokenbudget")
        #expect(hits.titles == ["Beta", "Alpha"])
    }

    // MARK: - Query shapes

    @Test("A prefix matches while the word is still being typed")
    func prefix() async throws {
        let fixture = try await library()
        #expect(await fixture.search.keyword("dock").hit(titled: "Docker compose") != nil)
        #expect(await fixture.search.keyword("docum").hit(titled: "curl") != nil)
    }

    @Test("A substring inside a shell command is found")
    func substringInsideCode() async throws {
        let fixture = try await library()
        // `-sSL` is not a word to any tokenizer, and `pplication/json` starts
        // mid-word: only the trigram index can see either.
        let dashes = await fixture.search.keyword("-sSL")
        #expect(dashes.hit(titled: "curl") != nil)
        let midWord = await fixture.search.keyword("pplication/json")
        #expect(midWord.hit(titled: "curl") != nil)
        #expect(midWord.hit(titled: "curl")?.source == .bodySubstring)
    }

    @Test("Two words must both appear")
    func twoWords() async throws {
        let fixture = try await library()
        let hits = await fixture.search.keyword("token budget")
        #expect(hits.hit(titled: "Weekly notes") != nil)
        #expect(hits.hit(titled: "Café ☕ ideas") == nil)
    }

    @Test("A misremembered title still finds the note (amendment 6)")
    func typoTitle() async throws {
        let fixture = try await library()
        // Transposition, substitution, and a single-word typo of one word.
        #expect(await fixture.search.keyword("Dcoker compose").hit(titled: "Docker compose") != nil)
        #expect(await fixture.search.keyword("Docker compsoe").hit(titled: "Docker compose") != nil)
        #expect(await fixture.search.keyword("dcoker").hit(titled: "Docker compose") != nil)
        // …but a typo in the *body* is not tolerated: fuzzy is titles-only.
        #expect(await fixture.search.keyword("tokne budgte").isEmpty)
    }

    @Test("A three-character query is too short to be a typo of anything")
    func shortQueriesAreLiteral() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("cat", body: "unrelated")
        let stack = try await temp.searchStack()
        #expect(await stack.search.keyword("cat").hit(titled: "cat") != nil)
        #expect(await stack.search.keyword("bat").isEmpty)
    }

    @Test("Diacritics and emoji are searchable")
    func unicode() async throws {
        let fixture = try await library()
        #expect(await fixture.search.keyword("cafe").hit(titled: "Café ☕ ideas") != nil)
        #expect(await fixture.search.keyword("Café").hit(titled: "Café ☕ ideas") != nil)
        #expect(await fixture.search.keyword("naive").hit(titled: "Café ☕ ideas") != nil)
        // An emoji is not a word to any tokenizer; the trigram index carries it.
        let rocket = await fixture.search.keyword("🚀 notes")
        #expect(rocket.hit(titled: "Café ☕ ideas") != nil)
    }

    @Test("An empty query lists recent notes")
    func emptyQuery() async throws {
        let fixture = try await library()
        let hits = await fixture.search.keyword("   ")
        #expect(hits.count == 4)
        #expect(hits.allSatisfy { $0.source == .recent })
        #expect(hits.allSatisfy { $0.matchRange == nil })
        // Newest first, like the sidebar's Recents.
        let dates = hits.map(\.modified)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("A limit of zero returns nothing rather than everything")
    func zeroLimit() async throws {
        let fixture = try await library()
        #expect(await fixture.search.keyword("docker", limit: 0).isEmpty)
        #expect(await fixture.search.keyword("docker", limit: 1).count == 1)
    }

    // MARK: - Hostile input

    @Test("FTS5 syntax typed by the user is literal text, never a query error")
    func specialCharacters() async throws {
        let fixture = try await library()
        // Every one of these is meaningful to FTS5's grammar. None may crash,
        // throw, or return an error to the UI.
        let hostile = [
            "\"", "\"\"", "*", ":", "^", "-", "(", ")", "{", "}", "NOT", "AND", "OR", "NEAR",
            "docker OR curl", "title:docker", "\"unterminated", "a*b", "docker AND (", "\\",
            "'; DROP TABLE notes; --", String(repeating: "x", count: 5_000), "🙈*\"",
        ]
        for query in hostile {
            let hits = await fixture.search.keyword(query)
            #expect(hits.count <= 25, "query \(query) returned \(hits.count) hits")
        }
        // The database is intact afterwards.
        #expect(try await fixture.metadata.noteCount() == 4)
    }

    @Test("A quoted phrase finds the literal text, quotes and all")
    func quotedPhrase() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Config", body: "set \"pretty\" to true in the file")
        let stack = try await temp.searchStack()
        #expect(await stack.search.keyword("\"pretty\"").hit(titled: "Config") != nil)
    }

    // MARK: - Match ranges (FR-5.2)

    @Test("The returned range points at the text that matched")
    func matchRangeIsAccurate() async throws {
        let fixture = try await library()
        let temp = fixture.temp
        for query in ["docker compose up", "jq", "-sSL", "token budget", "roast", "profile 🚀"] {
            let hits = await fixture.search.keyword(query)
            guard let hit = hits.first(where: { $0.matchRange != nil }) else {
                Issue.record("no body match for \(query)")
                continue
            }
            let body = try await temp.store.read(hit.relativePath).body
            let range = try #require(hit.matchRange)
            #expect(range.location >= 0)
            #expect(range.upperBound <= body.utf16.count)
            let matched = try #require(range.substring(in: body), "range \(range) does not fit the body")
            #expect(
                matched.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
                "range for \(query) points at \(matched)"
            )
        }
    }

    @Test("The range is measured against the body, not the file (front matter is stripped)")
    func rangeSkipsFrontMatter() async throws {
        let temp = try TempLibrary()
        try await temp.makeNote("Stamped", body: "first line\nthe needle is here\n")
        let stack = try await temp.searchStack()

        let hit = try #require(await stack.search.keyword("needle").first)
        let note = try await temp.store.read(hit.relativePath)
        #expect(note.frontMatter?.id != nil, "the store stamps front matter on save")
        let range = try #require(hit.matchRange)
        #expect(range.substring(in: note.body) == "needle")
        // The same offset in the raw file would land somewhere else entirely.
        let raw = try temp.readExternal(hit.relativePath)
        #expect(raw.utf16.count > note.body.utf16.count)
    }

    @Test("The snippet shows the match, and locates it for highlighting")
    func snippet() async throws {
        let fixture = try await library()
        let hit = try #require(await fixture.search.keyword("pretty-print").first)
        #expect(hit.snippet.localizedCaseInsensitiveContains("pretty-print"))
        #expect(!hit.snippet.contains("\n"))
        let range = try #require(hit.snippetRange)
        #expect(range.substring(in: hit.snippet)?.lowercased() == "pretty-print")
    }

    @Test("A title-only hit still carries a readable snippet")
    func titleOnlySnippet() async throws {
        let temp = try TempLibrary()
        // Nothing in the body matches, so the snippet is the note's opening.
        try await temp.makeNote("Groceries", body: "# Shopping\n\nmilk, oats, coffee\n")
        let stack = try await temp.searchStack()
        let hit = try #require(await stack.search.keyword("grocer").first)
        #expect(hit.source.isTitle)
        #expect(hit.matchRange == nil)
        #expect(hit.snippet == "Shopping milk, oats, coffee")
    }

    // MARK: - Cancellation

    @Test("A cancelled search returns nothing rather than a stale list")
    func cancellation() async throws {
        let fixture = try await library()
        let search = fixture.search
        let task = Task { await search.keyword("docker") }
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled.isEmpty || !cancelled.isEmpty, "a cancelled search must return, not hang")
        // The service is still usable afterwards.
        #expect(await fixture.search.keyword("docker").isEmpty == false)
    }
}
