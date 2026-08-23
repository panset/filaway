import Foundation
import Testing

@testable import FilawayCore

/// NFR-1: keyword search stays under 100 ms as the user types. NFR-2: 5,000
/// notes are smooth and 20,000 degrade gracefully.
///
/// These are the automated half of the M1 DoD's perf line; `filaway-bench
/// keyword --notes 5000|20000` reports the same numbers on a release build,
/// where they are roughly twice as fast. Tagged `.slow` and skipped by
/// `FILAWAY_SKIP_SLOW_TESTS=1`.
@Suite("Search scale (NFR-1, NFR-2)", .tags(.slow), .serialized)
struct SearchScaleTests {
    /// The five shapes FR-5.1 promises, on the vocabulary `SyntheticCorpus`
    /// actually generates. The typo case is derived from a real title so the
    /// gate cannot end up measuring a search that matches nothing.
    static func queries(mistyping title: String) -> [String] {
        var characters = Array(title)
        if characters.count > 4 {
            let middle = characters.count / 2
            characters.swapAt(middle, middle - 1)
        }
        return [
            "tokens",              // single word
            "docum",               // prefix, mid-typing
            "token budget",        // two words
            String(characters),    // a misremembered title (transposition)
            "pplication/json",     // a substring inside a curl command
        ]
    }

    /// Debug builds are the pessimistic case, and the one CI runs.
    static let budget: TimeInterval = 0.100

    private func measure(
        notes: Int,
        repeats: Int
    ) async throws -> (rebuild: TimeInterval, samples: [TimeInterval], hits: [String: Int]) {
        let temp = try TempLibrary()
        try SyntheticCorpus.generate(noteCount: notes, into: temp.library)
        let metadata = try temp.metadataStore()
        let snapshot = try await temp.store.scan()

        let rebuildStart = Date()
        try await metadata.rebuild(from: snapshot)
        let rebuild = Date().timeIntervalSince(rebuildStart)
        #expect(try await metadata.textIndexCount() == notes, "every note must be indexed")

        let search = SearchService(metadata: metadata)
        _ = await search.keyword("warm up")  // first call folds and caches the titles

        let title = try #require(snapshot.notes.first(where: { $0.title.count > 12 })?.title)
        let queries = Self.queries(mistyping: title)
        var samples: [TimeInterval] = []
        var hits: [String: Int] = [:]
        for round in 0 ..< repeats {
            for query in queries {
                let start = Date()
                let results = await search.keyword(query, limit: 25)
                samples.append(Date().timeIntervalSince(start))
                if round == 0 { hits[query] = results.count }
            }
        }
        withExtendedLifetime(temp) {}
        return (rebuild, samples, hits)
    }

    private func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    @Test(
        "Keyword search over 5,000 notes stays under 100 ms at p95",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(3))
    )
    func fiveThousand() async throws {
        let result = try await measure(notes: 5_000, repeats: 8)
        let p50 = percentile(result.samples, 0.5)
        let p95 = percentile(result.samples, 0.95)
        print("""
        [search] 5,000 notes — index rebuild \(Int(result.rebuild * 1000)) ms; \
        \(result.samples.count) searches p50 \(Int(p50 * 1000)) ms, p95 \(Int(p95 * 1000)) ms, \
        max \(Int((result.samples.max() ?? 0) * 1000)) ms
        """)

        for (query, count) in result.hits {
            #expect(count > 0, "\(query) found nothing — the gate would be measuring an empty search")
        }
        #expect(p95 < Self.budget, "p95 was \(Int(p95 * 1000)) ms, budget \(Int(Self.budget * 1000)) ms (NFR-1)")
    }

    @Test(
        "Keyword search over 20,000 notes degrades gracefully",
        .enabled(if: TestEnvironment.runsSlowTests),
        .timeLimit(.minutes(10))
    )
    func twentyThousand() async throws {
        // NFR-2 asks only that this stays usable. The number is reported; the
        // assertion is the loose one, because 20,000 notes is four times the
        // supported-smooth size and this is an unoptimised build.
        let result = try await measure(notes: 20_000, repeats: 4)
        let p95 = percentile(result.samples, 0.95)
        print("""
        [search] 20,000 notes — index rebuild \(Int(result.rebuild * 1000)) ms; \
        \(result.samples.count) searches p50 \(Int(percentile(result.samples, 0.5) * 1000)) ms, \
        p95 \(Int(p95 * 1000)) ms, max \(Int((result.samples.max() ?? 0) * 1000)) ms
        """)
        #expect(p95 < 0.500, "20,000 notes must stay usable; p95 was \(Int(p95 * 1000)) ms")
    }
}
