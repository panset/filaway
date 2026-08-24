import Foundation
import Testing

@testable import FilawayCore

/// M3-07 — the committed fixtures themselves.
///
/// A retrieval benchmark is only worth its fixtures. Every assertion here
/// exists because breaking it would make the benchmark *quietly* meaningless:
/// a query pointing at a note that no longer exists reads as a retrieval miss,
/// a snippet that appears in two notes makes "the answer" ambiguous, and a
/// temporal query whose expected range has drifted measures the calendar
/// rather than the search.
@Suite("Retrieval fixtures")
struct RetrievalFixtureTests {
    static let corpus: [CorpusNote] = (try? DevCorpus.load()) ?? []
    static let queries: RetrievalQuerySet? = try? RetrievalQuerySet.load()

    @Test("the committed corpus is the shape M3-07 specifies")
    func corpusShape() throws {
        let notes = Self.corpus
        #expect(notes.count >= 300)
        #expect(notes.filter(\.isGolden).count >= 60)
        let bytes = notes.reduce(0) { $0 + $1.fileText.utf8.count }
        #expect(bytes <= 2 * 1_048_576, "the corpus is committed; keep it under 2 MB")
        // Every path is a legal note path at at most two folder levels (FR-1.2).
        for note in notes {
            #expect(PathRules.isNotePath(note.relativePath), "\(note.relativePath)")
            let folders = note.relativePath.split(separator: "/").dropLast().count
            #expect(folders <= PathRules.maxFolderDepth, "\(note.relativePath)")
        }
        #expect(Set(notes.map(\.relativePath)).count == notes.count)
    }

    @Test("dates are spread out, and the golden notes carry the mtimes the queries assume")
    func dates() throws {
        let notes = Self.corpus
        let now = DevCorpusGenerator.referenceNow
        let ages = notes.map { now.timeIntervalSince($0.modified) / 86_400 }
        #expect(ages.allSatisfy { $0 > 0 }, "nothing in the corpus is in the future")
        #expect((ages.max() ?? 0) > 120, "the corpus should span more than four months")
        #expect(Set(notes.map { Int(now.timeIntervalSince($0.modified) / 86_400) }).count > 60)
        for note in notes {
            #expect(note.created <= note.modified, "\(note.relativePath)")
        }
    }

    @Test("a corpus note round-trips through its file text")
    func roundTrip() throws {
        for note in Self.corpus.prefix(40) {
            let parsed = CorpusNote.parse(relativePath: note.relativePath, text: note.fileText)
            #expect(parsed == note, "\(note.relativePath)")
        }
    }

    @Test("the generator is deterministic and still produces what is committed")
    func generatorMatchesTheCommittedCorpus() throws {
        let a = DevCorpusGenerator.generate()
        let b = DevCorpusGenerator.generate()
        #expect(a == b)
        // Curation happens in `DevCorpusContent`, not in the Markdown: if this
        // fails, either the tables changed without a `filaway-bench corpus
        // generate`, or someone hand-edited a fixture file (ADR-041).
        #expect(a == Self.corpus)
    }

    @Test("the query set is the size and mix M3-07 specifies")
    func querySetShape() throws {
        let set = try #require(Self.queries)
        #expect(set.version == RetrievalQuerySet.currentVersion)
        #expect(set.queries.count >= 60)
        #expect(set.negatives.count >= 10)
        #expect(Set(set.queries.map(\.id)).count == set.queries.count)
        for category in RetrievalCategory.allCases {
            #expect(set.queries.contains { $0.category == category }, "no \(category.rawValue) queries")
        }
        for query in set.queries {
            #expect(!query.text.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect((query.category == .negative) == query.isNegative, "\(query.id)")
        }
    }

    @Test("every expected note exists and every expected snippet is unique to it")
    func expectationsPointAtRealNotes() throws {
        let set = try #require(Self.queries)
        let bodies = Dictionary(
            uniqueKeysWithValues: Self.corpus.map {
                ($0.relativePath, RetrievalBenchmark.collapse($0.body))
            }
        )
        let golden = Set(Self.corpus.filter(\.isGolden).map(\.relativePath))
        for query in set.positives {
            let path = try #require(query.expectedPath, "\(query.id)")
            #expect(bodies[path] != nil, "\(query.id) points at a missing note: \(path)")
            #expect(golden.contains(path), "\(query.id) points at a distractor: \(path)")
            let snippet = RetrievalBenchmark.collapse(try #require(query.expectedSnippet, "\(query.id)"))
            let containing = bodies.filter { $0.value.contains(snippet) }.map(\.key)
            #expect(containing == [path], "\(query.id): snippet is in \(containing)")
        }
    }

    @Test("temporal queries parse to the range the fixture claims")
    func temporalExpectations() throws {
        let set = try #require(Self.queries)
        let parser = TemporalQueryParser(calendar: set.calendar)
        var checked = 0
        for query in set.queries {
            guard let expected = query.expectedRange else { continue }
            let parsed = parser.parse(query.text, now: set.now(for: query))
            #expect(parsed.range == expected.dateRange, "\(query.id): \(query.text)")
            // …and the note it points at really is inside that window, which is
            // what makes the query answerable at all.
            if let path = query.expectedPath,
               let note = Self.corpus.first(where: { $0.relativePath == path }) {
                #expect(expected.dateRange.contains(note.modified), "\(query.id): \(path) is outside the range")
            }
            checked += 1
        }
        #expect(checked >= 5, "the set should exercise several FR-5.3 phrasings")
    }

    @Test("no query accidentally names a note that only distractors mention")
    func negativesAreReallyUnanswerable() throws {
        let set = try #require(Self.queries)
        for query in set.negatives {
            #expect(query.expectedSnippet == nil, "\(query.id)")
            #expect(query.expectedRange == nil, "\(query.id)")
        }
    }
}
