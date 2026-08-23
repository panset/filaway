import Foundation
import Testing

@testable import FilawayCore

/// The pieces keyword search is built from, tested without a database.
@Suite("Search internals (M1-06)")
struct SearchUnitTests {
    // MARK: - Query parsing and FTS5 escaping

    @Test("A query is split into folded alphanumeric terms")
    func terms() {
        #expect(SearchQuery("Docker Compose").terms == ["docker", "compose"])
        #expect(SearchQuery("  curl -sSL  ").terms == ["curl", "ssl"])
        #expect(SearchQuery("Café ☕").terms == ["cafe"])
        #expect(SearchQuery("🙈").terms.isEmpty)
        #expect(SearchQuery("   ").isEmpty)
        #expect(SearchQuery(" trimmed ").raw == "trimmed")
    }

    @Test("Every term reaches FTS5 quoted, and the last one is a prefix")
    func expressions() {
        #expect(SearchQuery("docker").unicode61Expression == "\"docker\"*")
        #expect(SearchQuery("docker compose").unicode61Expression == "\"docker\" AND \"compose\"*")
        // FTS5 syntax typed by the user is data, not grammar.
        #expect(SearchQuery("NOT docker").unicode61Expression == "\"not\" AND \"docker\"*")
        #expect(SearchQuery("a*b").unicode61Expression == "\"a\" AND \"b\"*")
        #expect(SearchQuery("🙈").unicode61Expression == nil)
        // The only escape FTS5 has is a doubled quote.
        #expect(SearchQuery.quote("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(SearchQuery("say \"hi\"").trigramExpression == "\"say \"\"hi\"\"\"")
    }

    @Test("Trigram queries need three characters")
    func trigramFloor() {
        #expect(SearchQuery("ab").trigramExpression == nil)
        #expect(SearchQuery("abc").trigramExpression == "\"abc\"")
    }

    @Test("Folding makes case, diacritics and width irrelevant")
    func folding() {
        #expect(SearchQuery.fold("CAFÉ") == SearchQuery.fold("cafe"))
        #expect(SearchQuery.fold("naïve") == "naive")
    }

    // MARK: - Fuzzy (titles only)

    @Test("Edit distance counts substitutions, insertions and transpositions")
    func distance() {
        #expect(Fuzzy.distance("docker", "docker", maxDistance: 2) == 0)
        #expect(Fuzzy.distance("dcoker", "docker", maxDistance: 2) == 1)   // transposition
        #expect(Fuzzy.distance("dokcer", "docker", maxDistance: 2) == 1)
        #expect(Fuzzy.distance("dokker", "docker", maxDistance: 2) == 1)   // substitution
        #expect(Fuzzy.distance("docer", "docker", maxDistance: 2) == 1)    // deletion
        #expect(Fuzzy.distance("dockker", "docker", maxDistance: 2) == 1)  // insertion
        #expect(Fuzzy.distance("kayak", "docker", maxDistance: 2) == nil)  // beyond budget
        #expect(Fuzzy.distance("", "ab", maxDistance: 2) == 2)
        #expect(Fuzzy.distance("", "abc", maxDistance: 2) == nil)
    }

    @Test("The typo budget grows with the length of the query")
    func tolerance() {
        #expect(Fuzzy.tolerance(forLength: 3) == 0)
        #expect(Fuzzy.tolerance(forLength: 4) == 1)
        #expect(Fuzzy.tolerance(forLength: 7) == 1)
        #expect(Fuzzy.tolerance(forLength: 8) == 2)
    }

    @Test("The signature prefilter never rejects a pair that is actually close")
    func signature() {
        // The prefilter's contract: if it rejects, the distance really is
        // greater than the budget. Fuzzed against the real distance.
        var random = SplitMix64(seed: 0xF177_1234)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz 0123456789".utf8)
        for _ in 0 ..< 2_000 {
            let length = 4 + Int(random.next() % 14)
            var left = (0 ..< length).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }
            var right = left
            for _ in 0 ..< Int(random.next() % 4) {
                let index = Int(random.next() % UInt64(right.count))
                right[index] = alphabet[Int(random.next() % UInt64(alphabet.count))]
            }
            if random.next() % 2 == 0 { swap(&left, &right) }

            let tolerance = 2
            let rejected = (Fuzzy.signature(left) & ~Fuzzy.signature(right)).nonzeroBitCount > tolerance
            if rejected {
                #expect(
                    Fuzzy.distance(left, right, maxDistance: tolerance) == nil,
                    "prefilter rejected a pair within \(tolerance) edits"
                )
            }
        }
    }

    @Test("A word-level typo is found inside a longer title")
    func wordDistance() {
        let title = Array("docker compose cheatsheet".utf8)
        #expect(Fuzzy.wordDistance(title, Array("dcoker".utf8), maxDistance: 1) == 1)
        #expect(Fuzzy.wordDistance(title, Array("compose".utf8), maxDistance: 1) == 0)
        #expect(Fuzzy.wordDistance(title, Array("kayak".utf8), maxDistance: 1) == nil)
    }

    @Test("Byte matching agrees with String matching on folded text")
    func byteMatch() {
        let haystack = Array("docker compose".utf8)
        #expect(ByteMatch.hasPrefix(haystack, Array("docker".utf8)))
        #expect(!ByteMatch.hasPrefix(haystack, Array("compose".utf8)))
        #expect(ByteMatch.startsWord(haystack, Array("comp".utf8)))
        #expect(!ByteMatch.startsWord(haystack, Array("ompose".utf8)))
        #expect(ByteMatch.contains(haystack, Array("ompose".utf8)))
        #expect(!ByteMatch.contains(haystack, Array("zeppelin".utf8)))
        #expect(ByteMatch.equal(haystack, haystack))
        #expect(!ByteMatch.contains([], Array("x".utf8)))
    }

    // MARK: - Snippets and ranges

    @Test("A snippet is one line, elided at both ends when it was cut")
    func snippet() {
        let body = "alpha beta\n\n  gamma   delta\nepsilon\n"
        let match = try? #require(body.range(of: "gamma"))
        let snippet = SnippetBuilder.snippet(of: body, around: match)
        #expect(!snippet.text.contains("\n"))
        #expect(snippet.text == "alpha beta gamma delta epsilon")
        let range = try? #require(snippet.range)
        #expect(range?.substring(in: snippet.text) == "gamma")
    }

    @Test("A long body is trimmed with ellipses around the match")
    func longSnippet() {
        let body = String(repeating: "padding ", count: 100) + "needle" + String(repeating: " tail", count: 100)
        let match = body.range(of: "needle")
        let snippet = SnippetBuilder.snippet(of: body, around: match)
        #expect(snippet.text.hasPrefix("…"))
        #expect(snippet.text.hasSuffix("…"))
        #expect(snippet.range?.substring(in: snippet.text) == "needle")
        #expect(snippet.text.count < 250)
    }

    @Test("A UTF-16 range survives astral-plane characters")
    func astralRange() {
        // 🚀 is two UTF-16 units; a range measured in Characters would be wrong.
        let body = "🚀🚀 needle here"
        let match = try? #require(body.range(of: "needle"))
        let range = try? #require(match.flatMap { MatchRange($0, in: body) })
        #expect(range?.location == 5)
        #expect(range?.substring(in: body) == "needle")
        #expect(range?.nsRange == NSRange(location: 5, length: 6))
    }
}


/// The launch probe (M1-07). Its state is process-global, so this suite is
/// serialized — two tests resetting it at once would measure each other.
@Suite("Launch timing (M1-07)", .serialized)
struct LaunchTimerTests {
    @Test("LaunchTimer measures from the process start it was given")
    func launchTimer() {
        LaunchTimer.reset()
        let start = Date()
        LaunchTimer.mark(.processStart, at: start)
        LaunchTimer.mark(.windowVisible, at: start.addingTimeInterval(0.4))
        LaunchTimer.mark(.editorReady, at: start.addingTimeInterval(0.9))

        #expect(LaunchTimer.elapsed(to: .processStart) == 0)
        #expect(abs((LaunchTimer.elapsed(to: .windowVisible) ?? 0) - 0.4) < 0.001)
        #expect(abs((LaunchTimer.elapsed(to: .editorReady) ?? 0) - 0.9) < 0.001)
        #expect(LaunchTimer.report() == "processStart +0 ms, windowVisible +400 ms, editorReady +900 ms")

        LaunchTimer.reset()
        #expect(LaunchTimer.elapsed(to: .editorReady) == nil)
        #expect(LaunchTimer.report().isEmpty)
    }

    @Test("Marking without a process start falls back to the kernel's record")
    func launchTimerFallback() {
        LaunchTimer.reset()
        LaunchTimer.mark(.windowVisible)
        let elapsed = try? #require(LaunchTimer.elapsed(to: .windowVisible))
        // The test process has been alive for a moment, and not for a week.
        #expect((elapsed ?? -1) >= 0)
        #expect((elapsed ?? .infinity) < 3_600)
        LaunchTimer.reset()
    }
}
