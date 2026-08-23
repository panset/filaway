import Accelerate
import Foundation

/// A source of dense sentence embeddings.
///
/// Every implementation returns **L2-normalised** vectors, so cosine similarity
/// is a plain dot product (``EmbeddingMath/cosine(_:_:)``) and the M3 index can
/// store them as-is.
///
/// Plan §1 "Semantic index": the concrete model is a swap behind this protocol —
/// `CoreMLEmbedder` (bundled bge-small), with `NLContextualEmbedder` and
/// `NLSentenceEmbedder` as zero-download fallbacks (plan §5 risk #4 ladder).
public protocol Embedder: Sendable {
    /// Stable identifier recorded next to every stored vector, so a model swap
    /// can invalidate exactly the rows it has to. Include the dimension and any
    /// pooling/precision detail that changes the numbers.
    var identifier: String { get }

    /// Dimension of every vector returned by ``embed(_:)``.
    var dimension: Int { get }

    /// Embeds `texts` in order. The result has one vector per input.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder {
    /// Convenience for the single-text case.
    public func embed(_ text: String) async throws -> [Float] {
        guard let vector = try await embed([text]).first else {
            throw EmbedderError.emptyResult
        }
        return vector
    }
}

/// Failures shared by the embedder implementations.
public enum EmbedderError: Error, CustomStringConvertible, Equatable {
    /// The Core ML package or its vocabulary is missing from the bundle/cache.
    case modelUnavailable(String)
    /// `NLContextualEmbedding`/`NLEmbedding` assets are not installed and could
    /// not be downloaded.
    case assetsUnavailable(String)
    /// The model produced a feature the reader did not understand.
    case unexpectedModelOutput(String)
    /// A batch came back with the wrong number of rows.
    case emptyResult

    public var description: String {
        switch self {
        case let .modelUnavailable(detail): "embedding model unavailable: \(detail)"
        case let .assetsUnavailable(detail): "embedding assets unavailable: \(detail)"
        case let .unexpectedModelOutput(detail): "unexpected model output: \(detail)"
        case .emptyResult: "embedder returned no vectors"
        }
    }
}

/// Small vector helpers shared by the embedders and the retrieval bench.
public enum EmbeddingMath {
    /// Dot product. For unit-length vectors this *is* cosine similarity.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch: \(a.count) vs \(b.count)")
        return vDSP.dot(a, b)
    }

    /// Cosine similarity that does not assume normalised input.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let denominator = norm(a) * norm(b)
        return denominator > 0 ? dot(a, b) / denominator : 0
    }

    /// Euclidean norm.
    public static func norm(_ a: [Float]) -> Float {
        sqrt(vDSP.sum(vDSP.multiply(a, a)))
    }

    /// Returns `a` scaled to unit length; a zero vector is returned unchanged.
    public static func normalized(_ a: [Float]) -> [Float] {
        let n = norm(a)
        guard n > 1e-12 else { return a }
        return vDSP.divide(a, n)
    }

    /// Element-wise mean of `vectors`, which must be non-empty and same-length.
    public static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        guard vectors.count > 1 else { return first }
        var accumulator = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            vDSP.add(accumulator, vector, result: &accumulator)
        }
        return vDSP.divide(accumulator, Float(vectors.count))
    }
}
