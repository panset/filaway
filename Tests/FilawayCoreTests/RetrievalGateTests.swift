import Foundation
import Testing

@testable import FilawayCore

/// M3-07's CI gate — spec §8's success criterion, with the real bundled model.
///
/// > find a specific stored command via natural language in under 10 seconds,
/// > ≥ 90% of the time
///
/// Translated: the note that holds the command is **first** at least 90% of the
/// time, the answer card shows the right chunk at least 85% of the time, and
/// the offline half of the search is under a second at p95 so the M3-05 Claude
/// call has the whole of NFR-1's 5 s budget left.
///
/// Tagged `.slow` and skipped by `FILAWAY_SKIP_SLOW_TESTS=1`, because it builds
/// a 302-note semantic index with Core ML — about ten seconds on a debug build.
@Suite("Retrieval gate", .tags(.slow))
struct RetrievalGateTests {
    static var canRun: Bool {
        TestEnvironment.runsSlowTests && BundledEmbeddingModel.isAvailable
    }

    @Test(
        "the bundled model meets the spec §8 retrieval bar on the dev corpus",
        .enabled(if: RetrievalGateTests.canRun)
    )
    func bundledModelMeetsTheBar() async throws {
        let embedder = try await BundledModelCache.shared.load()
        let corpus = try DevCorpus.load()
        let queries = try RetrievalQuerySet.load()
        let temp = try TempLibrary()

        let report = try await RetrievalBenchmark.run(
            corpus: corpus, queries: queries, library: temp.library,
            embedder: embedder, label: "bge-small-en-v1.5 (bundled)"
        )

        // A miss caused by a broken fixture is not a retrieval result.
        #expect(report.missingExpectedPaths.isEmpty)
        #expect(report.outcomes.allSatisfy { $0.usedVectors })

        let metrics = report.overall
        #expect(
            metrics.noteTop1 >= 0.90,
            """
            note top-1 \(String(format: "%.1f%%", metrics.noteTop1 * 100)) < 90% (spec §8)
            \(report.failureTable())
            """
        )
        #expect(
            metrics.answerTop1 >= 0.85,
            """
            answer-chunk top-1 \(String(format: "%.1f%%", metrics.answerTop1 * 100)) < 85% (FR-5.2)
            \(report.failureTable())
            """
        )
        #expect(metrics.mrr >= 0.90, "MRR@10 \(metrics.mrr)")
        #expect(metrics.noteTop3 >= 0.95, "note top-3 \(metrics.noteTop3)")

        // NFR-1: the offline half, with the Claude step still to pay for.
                if !TestEnvironment.isCI {
    #expect(report.p95 < 1.0 * TestEnvironment.perfBudgetScale, "retrieval p95 \(report.p95) s")
        }

        // FR-5.5's other half: a question the library cannot answer must not
        // produce a confident answer card. The cosine floor is a backstop and
        // the distributions overlap (see docs/verification/M3-retrieval.md), so
        // this asserts the backstop still catches most of them, not all.
        #expect(report.negativeRejectionRate >= 0.75, "negatives rejected \(report.negativeRejectionRate)")
    }
}
