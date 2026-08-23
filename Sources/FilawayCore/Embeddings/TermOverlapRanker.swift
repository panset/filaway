import Foundation

/// A dependency-free BM25 ranker, used as the **baseline** the embedders have
/// to beat in the M1-08 spike.
///
/// Real keyword search in Filaway is SQLite FTS5 with its own BM25 (M1-06);
/// this exists so the spike can compare "semantic" against "lexical" without
/// standing up a database, and so a future test can assert that the semantic
/// model actually adds something.
public struct TermOverlapRanker: Sendable {
    private let documents: [[String: Int]]
    private let lengths: [Double]
    private let averageLength: Double
    private let inverseDocumentFrequency: [String: Double]
    private let k1: Double
    private let b: Double

    public init(documents texts: [String], k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
        let tokenized = texts.map(Self.tokenize)
        documents = tokenized.map { tokens in
            tokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        }
        lengths = tokenized.map { Double($0.count) }
        averageLength = lengths.isEmpty ? 0 : lengths.reduce(0, +) / Double(lengths.count)

        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in document.keys { documentFrequency[term, default: 0] += 1 }
        }
        let total = Double(max(documents.count, 1))
        inverseDocumentFrequency = documentFrequency.mapValues { frequency in
            log(1 + (total - Double(frequency) + 0.5) / (Double(frequency) + 0.5))
        }
    }

    /// BM25 score of every document against `query`, in document order.
    public func scores(for query: String) -> [Double] {
        let terms = Self.tokenize(query)
        return documents.indices.map { index in
            let document = documents[index]
            let length = lengths[index]
            var score = 0.0
            for term in terms {
                guard let frequency = document[term], let idf = inverseDocumentFrequency[term] else {
                    continue
                }
                let tf = Double(frequency)
                let denominator = tf + k1 * (1 - b + b * length / max(averageLength, 1e-9))
                score += idf * (tf * (k1 + 1)) / denominator
            }
            return score
        }
    }

    /// Document indices ordered best-first.
    public func ranking(for query: String) -> [Int] {
        let scores = scores(for: query)
        return scores.indices.sorted { scores[$0] > scores[$1] }
    }

    /// Lowercased runs of letters/digits. Underscores and hyphens split, which
    /// is what makes `--tail`, `kube-system` and `id_ed25519` behave.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
