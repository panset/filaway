import Foundation

@testable import FilawayCore

/// A deterministic, dependency-free stand-in for the Core ML embedder.
///
/// The chunker, indexer, vector store, RRF fusion and temporal parser must all
/// be covered on a machine (or a CI runner) with no `.mlpackage`, so those
/// suites run against this instead: a signed hashed bag-of-words projection,
/// L2-normalised, with a stable FNV-1a hash rather than Swift's per-process
/// seeded `Hasher`. Two texts that share vocabulary score high; two that do not
/// score near zero — enough structure for ranking assertions, and identical on
/// every run and every machine.
struct HashedEmbedder: Embedder {
    let identifier: String
    let dimension: Int
    /// A prefix reported through ``Embedder/queryPrefix`` — used to prove the
    /// hybrid layer applies it to queries and never to documents.
    let queryPrefix: String

    init(identifier: String = "test:hashed/64d/v1", dimension: Int = 64, queryPrefix: String = "") {
        self.identifier = identifier
        self.dimension = dimension
        self.queryPrefix = queryPrefix
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { Self.vector(for: $0, dimension: dimension) }
    }

    /// Synchronous form, for tests that need a query vector without `await`.
    func vector(for text: String) -> [Float] {
        Self.vector(for: text, dimension: dimension)
    }

    static func vector(for text: String, dimension: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dimension)
        for token in tokens(in: text) {
            let hash = fnv1a(token)
            let bucket = Int(hash % UInt64(dimension))
            // A signed projection keeps unrelated documents near orthogonal
            // instead of all-positive and all-similar.
            out[bucket] += (hash >> 40) & 1 == 0 ? 1 : -1
        }
        let normalized = EmbeddingMath.normalized(out)
        // An empty text must still be a valid unit vector, or cosine ordering
        // becomes undefined for a blank chunk.
        return normalized.allSatisfy { $0 == 0 } ? unitFallback(dimension) : normalized
    }

    private static func unitFallback(_ dimension: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dimension)
        out[0] = 1
        return out
    }

    static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
