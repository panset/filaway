import Foundation

/// Sidecar metadata written next to a converted `.mlpackage` by
/// `Tools/embedder/convert.py` (`out/<name>-s<seq>-b<batch>.json`).
///
/// It is the single source of truth for everything the Swift side must agree
/// with the converter about: sequence length, batch shape, pooling, casing.
/// Shipping it beside the model means a re-conversion with different settings
/// cannot silently desynchronise the tokenizer.
public struct EmbeddingModelDescriptor: Codable, Sendable, Equatable {
    /// Hugging Face model id, e.g. `BAAI/bge-small-en-v1.5`.
    public var model: String
    /// Short file basename, e.g. `bge-small-en-v1.5`.
    public var name: String
    /// Output vector length.
    public var dimension: Int
    /// `cls` or `mean` — baked into the graph, recorded here for the identifier.
    public var pooling: String
    /// Fixed input sequence length the package was traced at.
    public var maxSequenceLength: Int
    /// Fixed batch dimension of the input tensors.
    public var batchSize: Int
    /// `fp16` or `fp32`.
    public var precision: String
    /// Whether the graph already L2-normalises its output.
    public var normalized: Bool
    /// Whether the vocabulary is uncased.
    public var lowercase: Bool
    public var vocabSize: Int?
    public var packageBytes: Int?
    public var vocabBytes: Int?

    public init(
        model: String,
        name: String,
        dimension: Int,
        pooling: String,
        maxSequenceLength: Int,
        batchSize: Int,
        precision: String,
        normalized: Bool,
        lowercase: Bool,
        vocabSize: Int? = nil,
        packageBytes: Int? = nil,
        vocabBytes: Int? = nil
    ) {
        self.model = model
        self.name = name
        self.dimension = dimension
        self.pooling = pooling
        self.maxSequenceLength = maxSequenceLength
        self.batchSize = batchSize
        self.precision = precision
        self.normalized = normalized
        self.lowercase = lowercase
        self.vocabSize = vocabSize
        self.packageBytes = packageBytes
        self.vocabBytes = vocabBytes
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    /// Version of the *identifier scheme* below. Bumping it forces every
    /// library to re-embed even when the model itself did not change — the
    /// escape hatch for "we changed how text reaches the model" (a new
    /// chunk-context convention, a pooling fix in `convert.py`, a tokenizer
    /// bug). It is not the model's version; that is ``model``/``name``.
    public static let identifierVersion = 1

    /// Identifier stored next to every vector: changing any of these fields
    /// changes the numbers, so it must invalidate the index (M3-02 re-embeds
    /// every chunk whose `embeddings.model_id` differs from the active one).
    public var embedderIdentifier: String {
        "coreml:\(name)/\(pooling)/\(dimension)d/s\(maxSequenceLength)/\(precision)/v\(Self.identifierVersion)"
    }

    /// The query prefix this model family expects, or `""`.
    ///
    /// `bge-*-en-v1.5` is an asymmetric retriever; MiniLM and the
    /// NaturalLanguage models are symmetric.
    public var queryPrefix: String {
        name.hasPrefix("bge-") ? "Represent this sentence for searching relevant passages: " : ""
    }

    /// Tokenizer settings implied by this model.
    public var tokenizerConfiguration: WordPieceTokenizer.Configuration {
        .init(lowercase: lowercase)
    }
}
