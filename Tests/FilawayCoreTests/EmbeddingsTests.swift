import Foundation
import Testing

@testable import FilawayCore

// MARK: - Fixtures

/// Locations of the artefacts `Tools/embedder/convert.py` produces.
///
/// The vocabulary and the golden fixtures are committed (265 KB), so the
/// tokenizer is checked for parity with Hugging Face on every CI run. The
/// `.mlpackage` files are 43–66 MB and are **not** committed — the Core ML
/// tests below skip themselves when the packages are absent
/// (`Tools/embedder/regenerate.sh` recreates them).
enum EmbeddingFixtures {
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // Tests/FilawayCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    static let vocabularyURL = repositoryRoot
        .appending(path: "Tools/embedder/fixtures/bge-small-en-v1.5.vocab.txt")
    static let goldenURL = repositoryRoot
        .appending(path: "Tools/embedder/fixtures/bge-small-en-v1.5.golden.json")
    static let packageURL = repositoryRoot
        .appending(path: "Tools/embedder/out/bge-small-en-v1.5-s256-b1.mlpackage")

    static var hasVocabulary: Bool { exists(vocabularyURL) && exists(goldenURL) }
    static var hasPackage: Bool { exists(packageURL) }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    struct Golden: Decodable {
        struct TokenizerCase: Decodable {
            let text: String
            let tokens: [String]
            let ids: [Int32]
        }

        struct EmbeddingCase: Decodable {
            let text: String
            let ids: [Int32]
            let coreml: [Float]
        }

        let tokenizer: [TokenizerCase]
        let embeddings: [EmbeddingCase]
    }

    static func golden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
    }

    /// Loading an embedding model costs 40 ms–3 s and a lot of CPU; the suites
    /// below share one instance each so `swift test` does not spend its whole
    /// parallel budget on model loads (and does not starve the highlighter's
    /// timing tests).
    actor Shared {
        static let shared = Shared()
        private var coreML: CoreMLEmbedder?
        private var sentence: NLSentenceEmbedder?
        private var contextual: NLContextualEmbedder?

        func coreMLEmbedder() async throws -> CoreMLEmbedder {
            if let coreML { return coreML }
            let (embedder, _) = try await CoreMLEmbedder.load(packageAt: packageURL)
            coreML = embedder
            return embedder
        }

        func sentenceEmbedder() throws -> NLSentenceEmbedder {
            if let sentence { return sentence }
            let embedder = try NLSentenceEmbedder()
            sentence = embedder
            return embedder
        }

        func contextualEmbedder() throws -> NLContextualEmbedder {
            if let contextual { return contextual }
            let embedder = try NLContextualEmbedder()
            contextual = embedder
            return embedder
        }
    }

    /// A hand-written vocabulary big enough for the WordPiece unit tests.
    static func toyTokenizer(
        _ configuration: WordPieceTokenizer.Configuration = .init()
    ) throws -> WordPieceTokenizer {
        let tokens = [
            "[PAD]", "[UNK]", "[CLS]", "[SEP]",
            "un", "##aff", "##able", "##a", "##b", "##le",
            "hello", "world", "cafe", "naive", "the", "cat", "sat",
            "git", "reset", "soft", "head",
            ",", "!", "-", "~", "1", "生", "活", "好",
        ]
        var vocabulary: [String: Int32] = [:]
        for (index, token) in tokens.enumerated() { vocabulary[token] = Int32(index) }
        return try WordPieceTokenizer(vocabulary: vocabulary, configuration: configuration)
    }
}

// MARK: - WordPiece tokenizer

@Suite("WordPiece tokenizer")
struct WordPieceTokenizerTests {
    @Test("greedy longest-match splits a word into subwords")
    func subwordSplit() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("unaffable") == ["un", "##aff", "##able"])
    }

    @Test("a word with no covering subwords becomes a single [UNK]")
    func unknownWord() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("zzzz") == ["[UNK]"])
        // Partial coverage is still all-or-nothing, as in the reference impl.
        #expect(tokenizer.tokenize("unzz") == ["[UNK]"])
    }

    @Test("punctuation is split off into its own tokens")
    func punctuationSplit() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("hello, world!") == ["hello", ",", "world", "!"])
    }

    @Test("ASCII symbols BERT calls punctuation are split too")
    func symbolsArePunctuation() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("git reset --soft HEAD~1")
            == ["git", "reset", "-", "-", "soft", "head", "~", "1"])
    }

    @Test("lowercasing and accent stripping happen before lookup")
    func accentsAndCase() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("Café") == ["cafe"])
        #expect(tokenizer.tokenize("NAÏVE") == ["naive"])
    }

    @Test("a cased vocabulary keeps case and accents")
    func casedConfiguration() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer(.init(lowercase: false))
        #expect(tokenizer.tokenize("Café") == ["[UNK]"])
        #expect(tokenizer.tokenize("hello") == ["hello"])
    }

    @Test("CJK ideographs become one token each")
    func cjkSplit() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("生活好") == ["生", "活", "好"])
    }

    @Test("control characters vanish and whitespace runs collapse")
    func whitespaceAndControl() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize("  hello \u{0000}\u{200B}\t\n world  ") == ["hello", "world"])
    }

    @Test("a very long word is [UNK] without being searched")
    func longWord() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        #expect(tokenizer.tokenize(String(repeating: "un", count: 60)) == ["[UNK]"])
    }

    @Test("encode wraps in [CLS]/[SEP], pads, and masks the padding")
    func specialTokensAndPadding() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        let encoding = tokenizer.encode("hello world", maxLength: 8)
        #expect(encoding.ids.count == 8)
        #expect(encoding.tokenCount == 4)
        #expect(encoding.truncated == false)
        #expect(encoding.ids[0] == 2) // [CLS]
        #expect(encoding.ids[3] == 3) // [SEP]
        #expect(encoding.attentionMask == [1, 1, 1, 1, 0, 0, 0, 0])
        #expect(encoding.ids[4...].allSatisfy { $0 == tokenizer.padID })
    }

    @Test("an empty string still produces [CLS] [SEP]")
    func emptyInput() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        let encoding = tokenizer.encode("   ", maxLength: 6)
        #expect(encoding.tokenCount == 2)
        #expect(encoding.attentionMask == [1, 1, 0, 0, 0, 0])
    }

    @Test("truncation keeps the head and always closes with [SEP]")
    func truncation() throws {
        let tokenizer = try EmbeddingFixtures.toyTokenizer()
        let encoding = tokenizer.encode("hello world hello world hello", maxLength: 4)
        #expect(encoding.truncated)
        #expect(encoding.tokenCount == 4)
        #expect(encoding.ids[0] == 2)
        #expect(encoding.ids[3] == 3)
        #expect(encoding.attentionMask == [1, 1, 1, 1])
    }

    @Test("vocab.txt loads with line numbers as ids",
          .enabled(if: EmbeddingFixtures.hasVocabulary))
    func realVocabularyLoads() throws {
        let tokenizer = try WordPieceTokenizer(vocabularyAt: EmbeddingFixtures.vocabularyURL)
        #expect(tokenizer.vocabularySize == 30522)
        // una ##ffa ##ble — the ids bert-base-uncased assigns.
        #expect(tokenizer.encodeTokensOnly("unaffable") == [14477, 20961, 3468])
    }

    @Test("matches the Hugging Face tokenizer on the golden cases",
          .enabled(if: EmbeddingFixtures.hasVocabulary))
    func huggingFaceParity() throws {
        let tokenizer = try WordPieceTokenizer(vocabularyAt: EmbeddingFixtures.vocabularyURL)
        for testCase in try EmbeddingFixtures.golden().tokenizer {
            let encoding = tokenizer.encode(testCase.text, maxLength: 256)
            let ids = Array(encoding.ids.prefix(encoding.tokenCount))
            #expect(ids == testCase.ids, "tokenizing \(testCase.text.debugDescription)")
        }
    }
}

// MARK: - Vector helpers

@Suite("Embedding math")
struct EmbeddingMathTests {
    @Test("normalisation produces unit vectors and leaves zero alone")
    func normalization() {
        let vector = EmbeddingMath.normalized([3, 4, 0])
        #expect(abs(EmbeddingMath.norm(vector) - 1) < 1e-6)
        #expect(EmbeddingMath.normalized([0, 0, 0]) == [0, 0, 0])
    }

    @Test("cosine of unit vectors equals their dot product")
    func cosineMatchesDot() {
        let a = EmbeddingMath.normalized([1, 2, 3])
        let b = EmbeddingMath.normalized([3, 2, 1])
        #expect(abs(EmbeddingMath.cosine(a, b) - EmbeddingMath.dot(a, b)) < 1e-6)
    }

    @Test("mean averages element-wise")
    func mean() {
        #expect(EmbeddingMath.mean([[1, 2], [3, 4]]) == [2, 3])
    }
}

// MARK: - BM25 baseline

@Suite("Term-overlap baseline")
struct TermOverlapRankerTests {
    @Test("ranks the document that shares rare terms first")
    func ranksExactTerms() {
        let ranker = TermOverlapRanker(documents: [
            "docker exec -it opens a shell inside a running container",
            "git reset --soft HEAD~1 undoes the last commit",
            "the quick brown fox jumps over the lazy dog",
        ])
        #expect(ranker.ranking(for: "undo the last commit").first == 1)
        #expect(ranker.ranking(for: "shell in a container").first == 0)
    }

    @Test("a query with no shared terms scores everything zero")
    func noOverlap() {
        let ranker = TermOverlapRanker(documents: ["alpha beta", "gamma delta"])
        #expect(ranker.scores(for: "zzz").allSatisfy { $0 == 0 })
    }
}

// MARK: - NaturalLanguage embedders

@Suite("NaturalLanguage embedders", .serialized)
struct NLEmbedderTests {
    /// The three sentences every embedder must order correctly: two ways of
    /// saying the same thing, and one unrelated sentence.
    static let related = ("How do I copy a file to another machine?",
                          "Use scp to transfer a file to a remote host.")
    static let unrelated = "I baked a loaf of sourdough bread yesterday."

    @Test("sentence embeddings are unit-length and correctly dimensioned",
          .enabled(if: NLSentenceEmbedder.isAvailable()))
    func sentenceEmbeddingShape() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.sentenceEmbedder()
        #expect(embedder.dimension > 0)
        #expect(embedder.identifier.hasPrefix("nl-sentence:"))
        let vectors = try await embedder.embed([Self.related.0, Self.related.1])
        #expect(vectors.count == 2)
        for vector in vectors {
            #expect(vector.count == embedder.dimension)
            #expect(abs(EmbeddingMath.norm(vector) - 1) < 1e-4)
        }
    }

    @Test("sentence embeddings put paraphrases closer than unrelated text",
          .enabled(if: NLSentenceEmbedder.isAvailable()))
    func sentenceEmbeddingOrdering() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.sentenceEmbedder()
        let vectors = try await embedder.embed([Self.related.0, Self.related.1, Self.unrelated])
        let paraphrase = EmbeddingMath.dot(vectors[0], vectors[1])
        let distractor = EmbeddingMath.dot(vectors[0], vectors[2])
        #expect(paraphrase > distractor)
    }

    @Test("contextual embeddings are unit-length and correctly dimensioned",
          .enabled(if: NLContextualEmbedder.assetsAvailable()))
    func contextualEmbeddingShape() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.contextualEmbedder()
        #expect(embedder.dimension > 0)
        #expect(embedder.identifier.hasPrefix("nl-contextual:"))
        let vectors = try await embedder.embed([Self.related.0, Self.related.1])
        #expect(vectors.count == 2)
        for vector in vectors {
            #expect(vector.count == embedder.dimension)
            #expect(abs(EmbeddingMath.norm(vector) - 1) < 1e-4)
        }
    }

    @Test("contextual embeddings put paraphrases closer than unrelated text",
          .enabled(if: NLContextualEmbedder.assetsAvailable()))
    func contextualEmbeddingOrdering() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.contextualEmbedder()
        let vectors = try await embedder.embed([Self.related.0, Self.related.1, Self.unrelated])
        let paraphrase = EmbeddingMath.dot(vectors[0], vectors[1])
        let distractor = EmbeddingMath.dot(vectors[0], vectors[2])
        #expect(paraphrase > distractor)
    }

    @Test("empty input yields no vectors", .enabled(if: NLSentenceEmbedder.isAvailable()))
    func emptyBatch() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.sentenceEmbedder()
        #expect(try await embedder.embed([]).isEmpty)
    }
}

// MARK: - Core ML embedder (skipped without the regenerated package)

@Suite("Core ML embedder", .serialized)
struct CoreMLEmbedderTests {
    @Test("compiles the package once and reuses the cache",
          .enabled(if: EmbeddingFixtures.hasPackage))
    func compileAndCache() async throws {
        let cache = URL(filePath: NSTemporaryDirectory())
            .appending(path: "filaway-model-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }

        let cold = try await CompiledModelStore.compiledModel(
            forPackageAt: EmbeddingFixtures.packageURL, cacheDirectory: cache
        )
        #expect(cold.didCompile)
        #expect(cold.compileDuration > 0)
        #expect(FileManager.default.fileExists(atPath: cold.compiledURL.path))

        let warm = try await CompiledModelStore.compiledModel(
            forPackageAt: EmbeddingFixtures.packageURL, cacheDirectory: cache
        )
        #expect(warm.didCompile == false)
        #expect(warm.compiledURL == cold.compiledURL)
    }

    @Test("embeds a batch into unit vectors of the declared dimension",
          .enabled(if: EmbeddingFixtures.hasPackage))
    func embedsBatch() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.coreMLEmbedder()
        #expect(embedder.dimension == 384)
        #expect(embedder.identifier.hasPrefix("coreml:bge-small-en-v1.5"))

        let vectors = try await embedder.embed([
            NLEmbedderTests.related.0, NLEmbedderTests.related.1, NLEmbedderTests.unrelated,
        ])
        #expect(vectors.count == 3)
        for vector in vectors {
            #expect(vector.count == 384)
            #expect(abs(EmbeddingMath.norm(vector) - 1) < 1e-4)
        }
        #expect(EmbeddingMath.dot(vectors[0], vectors[1]) > EmbeddingMath.dot(vectors[0], vectors[2]))
    }

    @Test("matches the vectors the Python converter produced",
          .enabled(if: EmbeddingFixtures.hasPackage && EmbeddingFixtures.hasVocabulary))
    func matchesPythonReference() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.coreMLEmbedder()
        for testCase in try EmbeddingFixtures.golden().embeddings {
            let vector = try await embedder.embed(testCase.text)
            let reference = EmbeddingMath.normalized(testCase.coreml)
            #expect(EmbeddingMath.dot(vector, reference) > 0.999,
                    "drifted on \(testCase.text.debugDescription)")
        }
    }

    @Test("finds the right note for a natural-language query",
          .enabled(if: EmbeddingFixtures.hasPackage))
    func retrievesFromTheSpikeCorpus() async throws {
        let embedder = try await EmbeddingFixtures.Shared.shared.coreMLEmbedder()
        // A subset keeps this a correctness check, not a benchmark —
        // `filaway-bench embed` measures the whole corpus.
        let notes = Array(RetrievalSpikeCorpus.notes.prefix(20))
        let noteVectors = try await embedder.embed(notes.map(\.text))
        let query = try await embedder.embed("get a shell inside a running container")
        let scores = noteVectors.map { EmbeddingMath.dot(query, $0) }
        let best = scores.indices.max { scores[$0] < scores[$1] }
        #expect(notes[best ?? 0].id == "docker-exec-shell")
    }
}
