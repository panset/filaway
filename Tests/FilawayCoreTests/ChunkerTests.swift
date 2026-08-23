import Foundation
import Testing

@testable import FilawayCore

/// M3-02 — chunking (FR-5.4, and the unit FR-5.2's answer card is built from).
@Suite("Chunker")
struct ChunkerTests {
    /// The Figure-1 note: a title, prose, and the curl command the whole spec
    /// is about.
    static let figureOne = """
    Notes on fetching documents from the API. The endpoint is paginated and the
    token lives in the environment.

    ## Fetching

    Use this when you need the raw JSON rather than the SDK's model objects.

    ```sh
    curl -sSL -H 'Accept: application/json' \\
         -H "Authorization: Bearer $API_TOKEN" \\
         https://example.com/api/documents | jq '.items[]'
    ```

    Remember that `jq` is not installed on the build boxes.

    ## Pagination

    The cursor comes back in the `Link` header.
    """

    // MARK: - Shape

    @Test("a fenced code block becomes its own chunk")
    func codeBlockIsItsOwnChunk() {
        let chunks = Chunker().chunk(Self.figureOne, title: "Fetch documents")
        let code = chunks.filter { $0.kind == .code }
        #expect(code.count == 1)
        #expect(code[0].language == "sh")
        #expect(code[0].text.contains("curl -sSL"))
        #expect(code[0].text.contains("jq '.items[]'"))
    }

    @Test("a code chunk carries its heading path and the paragraph above it")
    func codeChunkCarriesContext() {
        let chunks = Chunker().chunk(Self.figureOne, title: "Fetch documents")
        let code = try! #require(chunks.first { $0.kind == .code })
        #expect(code.headingPath == ["Fetch documents", "Fetching"])
        #expect(code.text.contains("Fetch documents › Fetching"))
        // The nearest preceding paragraph, verbatim.
        #expect(code.text.contains("raw JSON"))
        // Not the paragraph *after* it, and not the other section.
        #expect(!code.text.contains("build boxes"))
        #expect(!code.text.contains("cursor comes back"))
    }

    @Test("every chunk's range points at the text it came from")
    func rangesRoundTrip() {
        let body = Self.figureOne
        for chunk in Chunker().chunk(body, title: "Fetch documents") {
            let slice = try! #require(chunk.range.substring(in: body))
            #expect(!slice.isEmpty)
            if chunk.kind == .code {
                #expect(slice.hasPrefix("```sh"))
                #expect(slice.hasSuffix("```"))
            }
        }
    }

    @Test("ranges are ordered and never overlap")
    func rangesAreOrdered() {
        let chunks = Chunker().chunk(Self.figureOne, title: "Fetch documents")
        for (index, chunk) in chunks.enumerated() {
            #expect(chunk.ordinal == index)
            if index > 0 {
                #expect(chunks[index - 1].range.upperBound <= chunk.range.location)
            }
        }
    }

    @Test("chunking is deterministic")
    func deterministic() {
        let first = Chunker().chunk(Self.figureOne, title: "T")
        let second = Chunker().chunk(Self.figureOne, title: "T")
        #expect(first == second)
        #expect(first.map(\.textHash) == second.map(\.textHash))
    }

    // MARK: - Headings

    @Test("nested headings build a path, and a sibling pops it")
    func nestedHeadingPath() {
        let body = """
        # Top

        Intro paragraph that is long enough to survive the minimum-token merge rule easily.

        ## Middle

        Some middle prose that also carries enough words to stand as its own chunk here.

        ### Deep

        Deep prose with plenty of words so that it is not folded into the section above it.

        ## Other

        Other prose with plenty of words so that it is not folded into the section above it.
        """
        let paths = Chunker(configuration: .init(minTokens: 0))
            .chunk(body, title: "Note")
            .map(\.headingPath)
        #expect(paths.contains(["Note", "Top"]))
        #expect(paths.contains(["Note", "Top", "Middle"]))
        #expect(paths.contains(["Note", "Top", "Middle", "Deep"]))
        #expect(paths.contains(["Note", "Top", "Other"]))
        #expect(!paths.contains(["Note", "Top", "Middle", "Deep", "Other"]))
    }

    @Test("a note with no headings still chunks")
    func noHeadings() {
        let chunks = Chunker().chunk("Just one paragraph of prose, nothing more.", title: "Flat")
        #expect(chunks.count == 1)
        #expect(chunks[0].kind == .prose)
        #expect(chunks[0].headingPath == ["Flat"])
    }

    // MARK: - Degenerate input

    @Test("empty and whitespace-only bodies produce nothing")
    func emptyBody() {
        #expect(Chunker().chunk("").isEmpty)
        #expect(Chunker().chunk("   \n\n\t\n").isEmpty)
    }

    @Test("an unterminated fence still yields one code chunk that reaches the end")
    func unterminatedFence() {
        let body = """
        # Broken

        Here is a command I never closed:

        ```sh
        docker compose up -d --build
        docker compose logs -f app
        """
        let chunks = Chunker().chunk(body, title: "Broken note")
        let code = try! #require(chunks.first { $0.kind == .code })
        #expect(code.language == "sh")
        #expect(code.text.contains("docker compose logs"))
        // Its range must still be inside the body.
        #expect(code.range.upperBound <= body.utf16.count)
        #expect(code.range.substring(in: body) != nil)
    }

    @Test("a fence with no language has no language")
    func fenceWithoutLanguage() {
        let chunks = Chunker().chunk("```\nplain text block\n```", title: "T")
        let code = try! #require(chunks.first { $0.kind == .code })
        #expect(code.language == nil)
    }

    @Test("a code block inside a list item is still its own chunk")
    func codeInsideList() {
        let body = """
        # Steps

        1. First, log in:

           ```sh
           gh auth login
           ```

        2. Then push.
        """
        let chunks = Chunker().chunk(body, title: "Steps note")
        let code = chunks.filter { $0.kind == .code }
        #expect(code.count == 1)
        #expect(code[0].text.contains("gh auth login"))
    }

    // MARK: - Budgets

    @Test("long sections are split at paragraph boundaries under the budget")
    func longSectionSplits() {
        let paragraph = String(
            repeating: "The deployment stops picking up the changed config map every single time. ",
            count: 6
        )
        let body = "# Big\n\n" + (0 ..< 12).map { "\($0). \(paragraph)" }.joined(separator: "\n\n")
        let chunker = Chunker(configuration: .init(maxTokens: 120))
        let chunks = chunker.chunk(body, title: "Big note")
        #expect(chunks.count > 3)
        for chunk in chunks {
            // The estimate is what the budget is expressed in; allow the last
            // block that pushed past it plus the heading-path preamble.
            #expect(TokenEstimate.wordPiece(chunk.text) <= 120 * 2)
        }
        // Every chunk of a split section keeps the section's heading path.
        #expect(chunks.allSatisfy { $0.headingPath == ["Big note", "Big"] })
    }

    @Test("a single paragraph larger than the budget is split by lines")
    func oversizedParagraphSplits() {
        let line = "kubectl rollout restart deployment/checkout and then wait for the replica set\n"
        let chunks = Chunker(configuration: .init(maxTokens: 60))
            .chunk("# One\n\n" + String(repeating: line, count: 40), title: "N")
        #expect(chunks.count > 4)
        #expect(chunks.allSatisfy { !$0.text.isEmpty })
    }

    @Test("a huge note is capped and still returns in reasonable time", .timeLimit(.minutes(1)))
    func hugeNoteIsCapped() {
        var body = "# Huge\n\n"
        for index in 0 ..< 4_000 {
            body += "## Section \(index)\n\nSome prose about section \(index) and its many details.\n\n"
            body += "```sh\necho section-\(index)\n```\n\n"
        }
        let chunks = Chunker(configuration: .init(maxChunks: 400)).chunk(body, title: "Huge")
        #expect(chunks.count <= 400)
        #expect(chunks.count > 100)
    }

    @Test("a tiny trailing section is merged back rather than embedded alone")
    func tinyTailMerges() {
        let body = """
        # Title

        A first paragraph with a decent number of words in it so that it clears the minimum.

        ok
        """
        let chunks = Chunker(configuration: .init(minTokens: 8)).chunk(body, title: "T")
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("ok"))
    }

    // MARK: - Unicode

    @Test("ranges are UTF-16 correct across astral characters")
    func astralRanges() {
        let body = """
        # 🚀 Launch

        Prose with an emoji 🎉 and a café, plus enough words to make a real chunk.

        ```sh
        echo "🚀"
        ```
        """
        let chunks = Chunker().chunk(body, title: "Unicode")
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            let slice = try! #require(chunk.range.substring(in: body))
            #expect(body.utf16.count >= chunk.range.upperBound)
            #expect(!slice.isEmpty)
        }
        let code = try! #require(chunks.first { $0.kind == .code })
        #expect(code.range.substring(in: body)?.contains("🚀") == true)
    }

    @Test("CRLF bodies keep their ranges inside the body")
    func carriageReturns() {
        let body = "# Title\r\n\r\nA paragraph.\r\n\r\n```sh\r\nls -la\r\n```\r\n"
        let chunks = Chunker().chunk(body, title: "CRLF")
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.range.upperBound <= body.utf16.count)
            #expect(chunk.range.substring(in: body) != nil)
        }
    }

    // MARK: - Token estimate

    @Test("the token estimate is in the right ballpark for prose and code")
    func tokenEstimateSanity() {
        #expect(TokenEstimate.wordPiece("") == 2)
        let prose = "The quick brown fox jumps over the lazy dog."
        #expect((10 ... 20).contains(TokenEstimate.wordPiece(prose)))
        let code = "curl -sSL -H 'Accept: application/json' https://example.com/api"
        #expect(TokenEstimate.wordPiece(code) > TokenEstimate.wordPiece("curl example"))
    }

    @Test("the estimate does not undershoot the real WordPiece count by much",
          .enabled(if: EmbeddingFixtures.hasVocabulary))
    func tokenEstimateVersusWordPiece() throws {
        let tokenizer = try WordPieceTokenizer(vocabularyAt: EmbeddingFixtures.vocabularyURL)
        for sample in [
            "The tricky part is that the token budget is shared across the whole session.",
            "curl -sS -H 'Accept: application/json' https://example.com/api/documents | jq '.items[]'",
            "docker compose up -d --build && docker compose logs -f app",
        ] {
            let real = tokenizer.tokenCount(sample)
            let estimate = TokenEstimate.wordPiece(sample)
            // Over-estimating is the safe direction; never be wildly under.
            #expect(Double(estimate) >= Double(real) * 0.6)
            #expect(Double(estimate) <= Double(real) * 2.0)
        }
    }
}
