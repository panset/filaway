import CoreML
import Foundation

/// Embedder backed by a converted BERT-family model running on Core ML.
///
/// The Core ML graph owns tokenisation-independent work only: encoder →
/// pooling → L2 normalise. Everything before it (WordPiece, padding, the
/// attention mask) is ``WordPieceTokenizer``; everything after it is a memcpy.
///
/// The package is traced at a **fixed** `[batchSize, maxSequenceLength]` shape
/// (plan §8 / spike M1-08), so:
/// * short and long inputs cost the same — the M3 chunker should therefore aim
///   at chunks near `maxSequenceLength` rather than many tiny ones, or ship a
///   second short-sequence package and route by token count;
/// * a `batchSize > 1` package needs its final partial batch padded, which
///   ``embed(_:)`` does transparently.
public actor CoreMLEmbedder: Embedder {
    public nonisolated let identifier: String
    public nonisolated let dimension: Int
    public nonisolated let maxSequenceLength: Int
    /// Fixed batch dimension of the underlying package.
    public nonisolated let modelBatchSize: Int
    public nonisolated let queryPrefix: String
    /// The descriptor the package was converted with.
    public nonisolated let descriptor: EmbeddingModelDescriptor

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let inputIDsKey = "input_ids"
    private let attentionMaskKey = "attention_mask"
    private let outputKey = "embeddings"

    /// A model that has already been compiled (`.mlmodelc`).
    public init(
        compiledModelAt compiledURL: URL,
        vocabularyAt vocabularyURL: URL,
        descriptor: EmbeddingModelDescriptor,
        computeUnits: MLComputeUnits = .all
    ) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        tokenizer = try WordPieceTokenizer(
            vocabularyAt: vocabularyURL, configuration: descriptor.tokenizerConfiguration
        )
        identifier = descriptor.embedderIdentifier
        dimension = descriptor.dimension
        maxSequenceLength = descriptor.maxSequenceLength
        modelBatchSize = descriptor.batchSize
        queryPrefix = descriptor.queryPrefix
        self.descriptor = descriptor
    }

    /// What the app does at first launch: compile the `.mlpackage` if the cache
    /// is cold, then open it. Returns the compile timing alongside the embedder
    /// so callers can log/measure it (spike question 3).
    public static func load(
        packageAt packageURL: URL,
        vocabularyAt vocabularyURL: URL,
        descriptor: EmbeddingModelDescriptor,
        computeUnits: MLComputeUnits = .all,
        cacheDirectory: URL? = nil
    ) async throws -> (embedder: CoreMLEmbedder, compilation: CompiledModelStore.Outcome) {
        let outcome = try await CompiledModelStore.compiledModel(
            forPackageAt: packageURL, cacheDirectory: cacheDirectory
        )
        let embedder = try CoreMLEmbedder(
            compiledModelAt: outcome.compiledURL,
            vocabularyAt: vocabularyURL,
            descriptor: descriptor,
            computeUnits: computeUnits
        )
        return (embedder, outcome)
    }

    /// Convenience for the layout `Tools/embedder/convert.py` produces:
    /// `<stem>.mlpackage` + `<stem>.json` + `<name>.vocab.txt` in one folder.
    public static func load(
        packageAt packageURL: URL,
        computeUnits: MLComputeUnits = .all,
        cacheDirectory: URL? = nil
    ) async throws -> (embedder: CoreMLEmbedder, compilation: CompiledModelStore.Outcome) {
        let folder = packageURL.deletingLastPathComponent()
        let stem = packageURL.deletingPathExtension().lastPathComponent
        let descriptorURL = folder.appendingPathComponent("\(stem).json")
        guard let descriptor = try? EmbeddingModelDescriptor(contentsOf: descriptorURL) else {
            throw EmbedderError.modelUnavailable("missing descriptor \(descriptorURL.lastPathComponent)")
        }
        let vocabularyURL = folder.appendingPathComponent("\(descriptor.name).vocab.txt")
        guard FileManager.default.fileExists(atPath: vocabularyURL.path) else {
            throw EmbedderError.modelUnavailable("missing \(vocabularyURL.lastPathComponent)")
        }
        return try await load(
            packageAt: packageURL,
            vocabularyAt: vocabularyURL,
            descriptor: descriptor,
            computeUnits: computeUnits,
            cacheDirectory: cacheDirectory
        )
    }

    // MARK: - Embedder

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let encodings = texts.map { tokenizer.encode($0, maxLength: maxSequenceLength) }

        if modelBatchSize == 1 {
            // Core ML pipelines an MLArrayBatchProvider itself, which is faster
            // than N separate predictions even at batch shape 1.
            let providers = try encodings.map { try featureProvider(for: [$0]) }
            let results = try model.predictions(
                from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions()
            )
            var vectors: [[Float]] = []
            vectors.reserveCapacity(texts.count)
            for index in 0 ..< results.count {
                vectors.append(contentsOf: try readVectors(results.features(at: index), rows: 1))
            }
            return vectors
        }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var offset = 0
        while offset < encodings.count {
            let slice = Array(encodings[offset ..< min(offset + modelBatchSize, encodings.count)])
            let padded = slice + Array(
                repeating: tokenizer.encode("", maxLength: maxSequenceLength),
                count: modelBatchSize - slice.count
            )
            let output = try model.predictions(
                from: MLArrayBatchProvider(array: [try featureProvider(for: padded)]),
                options: MLPredictionOptions()
            ).features(at: 0)
            vectors.append(contentsOf: try readVectors(output, rows: modelBatchSize).prefix(slice.count))
            offset += modelBatchSize
        }
        return vectors
    }

    /// Token count for `text` including the special tokens — exposed so the M3
    /// chunker can size chunks against the same tokenizer the model uses.
    public func tokenCount(_ text: String) -> Int {
        tokenizer.tokenCount(text)
    }

    // MARK: - Core ML plumbing

    private func featureProvider(
        for encodings: [WordPieceTokenizer.Encoding]
    ) throws -> MLDictionaryFeatureProvider {
        let shape = [NSNumber(value: encodings.count), NSNumber(value: maxSequenceLength)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for (row, encoding) in encodings.enumerated() {
                let base = row * maxSequenceLength
                for (column, value) in encoding.ids.enumerated() { buffer[base + column] = value }
            }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for (row, encoding) in encodings.enumerated() {
                let base = row * maxSequenceLength
                for (column, value) in encoding.attentionMask.enumerated() {
                    buffer[base + column] = value
                }
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            inputIDsKey: MLFeatureValue(multiArray: ids),
            attentionMaskKey: MLFeatureValue(multiArray: mask),
        ])
    }

    private func readVectors(_ features: MLFeatureProvider, rows: Int) throws -> [[Float]] {
        guard let array = features.featureValue(for: outputKey)?.multiArrayValue else {
            throw EmbedderError.unexpectedModelOutput(
                "no '\(outputKey)' feature (got \(features.featureNames.sorted()))"
            )
        }
        guard array.count == rows * dimension else {
            throw EmbedderError.unexpectedModelOutput(
                "expected \(rows)×\(dimension) values, got \(array.count)"
            )
        }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(rows)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for row in 0 ..< rows {
                    vectors.append(Array(buffer[row * dimension ..< (row + 1) * dimension]))
                }
            }
        case .double, .float16, .int32:
            // Slow NSNumber path. The converter asks for float32 outputs, so
            // this only runs if someone re-converts with different settings.
            for row in 0 ..< rows {
                vectors.append((0 ..< dimension).map { column in
                    array[[NSNumber(value: row), NSNumber(value: column)]].floatValue
                })
            }
        @unknown default:
            throw EmbedderError.unexpectedModelOutput("unsupported dataType \(array.dataType)")
        }
        // The graph normalises already; re-normalising costs ~nothing and makes
        // fp16 round-off in the last digit irrelevant to the index.
        return vectors.map(EmbeddingMath.normalized)
    }
}
