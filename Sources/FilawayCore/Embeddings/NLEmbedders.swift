import Foundation
import NaturalLanguage

/// Mean-pooled `NLContextualEmbedding` — the zero-download rung of the fallback
/// ladder (plan §8: added because this machine cannot pre-compile Core ML
/// models, and generally because it keeps the app useful before/without the
/// bundled model).
///
/// `NLContextualEmbedding` is a transformer that Apple ships with the OS but
/// whose weights are an on-demand asset: ``prepareAssets(for:)`` must succeed
/// once (it downloads, a few hundred MB, and is shared system-wide) before
/// ``init(language:)`` can load. It returns **per-token** vectors, so this type
/// mean-pools them and L2-normalises the result.
public actor NLContextualEmbedder: Embedder {
    public nonisolated let identifier: String
    public nonisolated let dimension: Int
    private let embedding: NLContextualEmbedding
    private let language: NLLanguage

    /// Whether the OS has the assets on disk right now (no network use).
    public static func assetsAvailable(for language: NLLanguage = .english) -> Bool {
        guard let embedding = NLContextualEmbedding(language: language) else { return false }
        return embedding.hasAvailableAssets
    }

    /// Requests the on-demand assets, returning when they are usable.
    /// Safe to call when they are already present (it returns immediately).
    @discardableResult
    public static func prepareAssets(for language: NLLanguage = .english) async throws -> Bool {
        guard let embedding = NLContextualEmbedding(language: language) else {
            throw EmbedderError.assetsUnavailable("no contextual embedding for \(language.rawValue)")
        }
        if embedding.hasAvailableAssets { return true }
        return try await withCheckedThrowingContinuation { continuation in
            embedding.requestAssets { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result == .available)
                }
            }
        }
    }

    /// Loads the model. Throws ``EmbedderError/assetsUnavailable(_:)`` when the
    /// assets have never been requested — call ``prepareAssets(for:)`` first.
    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLContextualEmbedding(language: language) else {
            throw EmbedderError.assetsUnavailable("no contextual embedding for \(language.rawValue)")
        }
        guard embedding.hasAvailableAssets else {
            throw EmbedderError.assetsUnavailable(
                "contextual embedding assets for \(language.rawValue) are not downloaded"
            )
        }
        do {
            try embedding.load()
        } catch {
            throw EmbedderError.assetsUnavailable("load failed: \(error)")
        }
        self.embedding = embedding
        self.language = language
        dimension = embedding.dimension
        identifier = "nl-contextual:\(embedding.modelIdentifier)/mean/\(embedding.dimension)d"
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try texts.map { try embed(one: $0) }
    }

    private func embed(one text: String) throws -> [Float] {
        let zero = [Float](repeating: 0, count: dimension)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return zero }
        let result = try embedding.embeddingResult(for: text, language: language)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
            guard vector.count == self.dimension else { return true }
            for index in 0 ..< vector.count { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { return zero }
        return EmbeddingMath.normalized(sum.map { Float($0 / Double(count)) })
    }
}

/// `NLEmbedding.sentenceEmbedding` — the last rung before falling back to
/// keyword-only search. Always present on macOS 14 for supported languages,
/// no download, but it is a static (non-contextual) sentence model.
public actor NLSentenceEmbedder: Embedder {
    public nonisolated let identifier: String
    public nonisolated let dimension: Int
    private let embedding: NLEmbedding

    /// Whether the OS can provide a sentence embedding for `language`.
    public static func isAvailable(for language: NLLanguage = .english) -> Bool {
        NLEmbedding.sentenceEmbedding(for: language) != nil
    }

    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            throw EmbedderError.assetsUnavailable("no sentence embedding for \(language.rawValue)")
        }
        self.embedding = embedding
        dimension = embedding.dimension
        identifier = "nl-sentence:\(language.rawValue)/\(embedding.dimension)d"
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            guard let vector = embedding.vector(for: text) else {
                // NLEmbedding refuses some inputs (empty, pure punctuation);
                // a zero vector scores 0 against everything, which is correct.
                return [Float](repeating: 0, count: dimension)
            }
            return EmbeddingMath.normalized(vector.map(Float.init))
        }
    }
}
