import Foundation
import GRDB

/// Query-side spelling repair for the semantic arm (M4-07; the gap M3-07 §5
/// left open).
///
/// The retrieval benchmark's weakest category is typos: **57% top-1**, four of
/// seven queries missed, because `"crul"`, `"rsyncc"` and `"pdo"` defeat both
/// retrievers at once. FTS5 matches terms exactly, so a misspelling contributes
/// nothing to BM25; and WordPiece splits a misspelling into subword soup that
/// embeds nowhere near the correct word, so it poisons the vector arm as well.
///
/// The repair is deliberately narrow: **only a term the library has never seen
/// is touched.** A term with a document frequency of zero cannot match anything
/// in FTS5 by construction, so replacing it can only add recall; a term that
/// does occur is left exactly as typed, however odd it looks. That is what
/// keeps the lever from costing the other 82 queries anything — there is no
/// threshold to tune and no "did they mean" judgement to get wrong.
///
/// The vocabulary is FTS5's own term index, read through the `notes_vocab`
/// `fts5vocab` view (`v6-vocab`). It stores nothing: the view is a projection
/// of the index `notes_fts` already maintains, so the whole lever costs one
/// schema row and no bytes.
///
/// ```swift
/// let vocabulary = try TypoExpansion.Vocabulary.load(db)
/// let repair = vocabulary.repair(["crul", "command", "stagign", "docs"])
/// repair.corrections           // ["crul": ["curl"], "stagign": ["staging"]]
/// repair.rewrite("the crul command for stagign docs")
/// // "the curl command for staging docs"
/// ```
public enum TypoExpansion {

    /// How far a term of a given length may be wrong: **one edit, ever.**
    ///
    /// Tighter than ``Fuzzy/tolerance(forLength:)``, which is tuned for
    /// *titles* — a handful of short strings, where two edits is affordable.
    /// Here the haystack is every word in the library, and the measurement is
    /// unambiguous. Every misspelling in the M3-07 query set is a single edit
    /// or a single transposition (`crul`, `pdo`, `loggs`, `rebuidl`, `pluled`,
    /// `rsyncc`, `sever`, `rebse`, `mian`, `opnessl`, `certificat`, `chek`),
    /// so a two-edit budget buys no recall at all — and it costs precision,
    /// because the gate cannot tell a *typo* from a word that is spelt
    /// correctly and simply is not in this library. Two edits on long words
    /// turned `"upgrading"` and `"squash"` into other people's words and lost
    /// two paraphrase queries; at one edit the typo category still goes
    /// 57% to 100% and paraphrase does not move (M4-07).
    public static func tolerance(forLength length: Int) -> Int {
        length < minimumTermLength ? 0 : 1
    }

    /// Terms shorter than this are never repaired: at two characters an edit
    /// reaches most of the alphabet.
    public static let minimumTermLength = 3

    /// FTS5's term index, flattened for scanning.
    ///
    /// Laid out the way ``SearchService`` lays out titles: one contiguous byte
    /// buffer plus parallel arrays, so the scan is a pointer walk with no
    /// retain traffic and no `String` bridging. At 20,000 notes the vocabulary
    /// is on the order of 10⁵ terms and this costs a couple of megabytes.
    public struct Vocabulary: Sendable {
        /// Every term's UTF-8 bytes, end to end.
        private var bytes: [UInt8] = []
        /// `offsets[i] ..< offsets[i + 1]` is term `i`.
        private var offsets: [Int32] = [0]
        /// ``Fuzzy/signature(_:_:)`` per term — the prefilter that makes the
        /// scan affordable.
        private var signatures: [UInt64] = []
        /// How many notes each term occurs in. Ranks the candidates: between
        /// two words a typo could have been, the commoner one wins.
        private var documents: [Int32] = []
        /// Exact membership, for the "has the library ever seen this?" test.
        private var known: Set<String> = []

        public var count: Int { signatures.count }
        public var isEmpty: Bool { signatures.isEmpty }

        /// `true` when the term occurs in at least one note.
        public func contains(_ term: String) -> Bool { known.contains(term) }

        /// FTS5's term index, exposed by the `v6-vocab` migration.
        ///
        /// A migration rather than a `temp.` table created on demand, because
        /// GRDB's reader connections run with `PRAGMA query_only = 1` and
        /// refuse DDL even in the temp schema. `fts5vocab` stores nothing, so
        /// the migration costs a schema row and no bytes.
        static let viewName = DatabaseSchema.vocabularyTable

        /// Which of `terms` the library has never indexed.
        ///
        /// The gate in front of everything else here, and the reason typo
        /// repair costs a normal query nothing: this is one indexed point
        /// lookup per term, whereas ``load(_:minimumDocuments:maximumTerms:)``
        /// walks the whole term index. A query with no misspelling in it pays
        /// only for the lookups and stops.
        public static func unknownTerms(_ db: Database, terms: [String]) throws -> [String] {
            let candidates = terms.filter { $0.utf8.count >= minimumTermLength }
            guard !candidates.isEmpty else { return [] }
            var unknown: [String] = []
            for term in candidates {
                let documents = try Int.fetchOne(
                    db, sql: "SELECT doc FROM \(viewName) WHERE term = ?", arguments: [term]
                ) ?? 0
                if documents == 0 { unknown.append(term) }
            }
            return unknown
        }

        /// Reads `notes_fts`'s term index.
        ///
        /// - Parameters:
        ///   - minimumDocuments: terms rarer than this are dropped. The
        ///     default keeps everything, and it has to: the word a
        ///     misspelling is reaching for is very often the rare one — the
        ///     single note that names `openssl` is exactly the note the query
        ///     wants. Raising this to 2 to keep the vocabulary tidy costs
        ///     precisely the queries this lever exists for.
        ///   - maximumTerms: a hard cap, so a pathological library cannot turn
        ///     one query into a hundred-megabyte allocation.
        public static func load(
            _ db: Database,
            minimumDocuments: Int = 1,
            maximumTerms: Int = 250_000
        ) throws -> Vocabulary {
            var vocabulary = Vocabulary()
            let rows = try Row.fetchCursor(db, sql: """
                SELECT term, doc FROM \(viewName)
                WHERE doc >= ? ORDER BY doc DESC LIMIT ?
                """, arguments: [minimumDocuments, maximumTerms])
            while let row = try rows.next() {
                let term: String = row["term"]
                let documents: Int = row["doc"] ?? 0
                guard term.utf8.count >= minimumTermLength else { continue }
                vocabulary.append(term, documents: documents)
            }
            return vocabulary
        }

        mutating func append(_ term: String, documents count: Int) {
            let utf8 = Array(term.utf8)
            bytes.append(contentsOf: utf8)
            offsets.append(Int32(bytes.count))
            signatures.append(Fuzzy.signature(utf8))
            documents.append(Int32(count))
            known.insert(term)
        }

        /// Builds a vocabulary from terms in memory. Tests and the bench.
        public static func make(_ terms: [(term: String, documents: Int)]) -> Vocabulary {
            var vocabulary = Vocabulary()
            for entry in terms where entry.term.utf8.count >= minimumTermLength {
                vocabulary.append(entry.term, documents: entry.documents)
            }
            return vocabulary
        }

        // MARK: - The scan

        /// The nearest known terms to `term`, commonest first.
        ///
        /// Two prefilters keep this off the profile even though it walks the
        /// whole vocabulary: a length band (`|Δlen| ≤ budget`) and
        /// ``Fuzzy/signature(_:_:)`` (`popcount(a & ~b) > budget` proves the
        /// distance exceeds the budget in one instruction). Only what survives
        /// both reaches the edit-distance matrix.
        public func nearest(to term: String, limit: Int = 3) -> [String] {
            let needle = Array(term.utf8)
            let budget = tolerance(forLength: needle.count)
            guard budget > 0, limit > 0, !signatures.isEmpty else { return [] }
            let needleSignature = Fuzzy.signature(needle)

            // (distance, -documents, index): nearest first, then commonest.
            var best: [(distance: Int, documents: Int32, index: Int)] = []
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                needle.withUnsafeBufferPointer { needleBuffer in
                    guard let needleBase = needleBuffer.baseAddress else { return }
                    for index in 0 ..< signatures.count {
                        let start = Int(offsets[index])
                        let length = Int(offsets[index + 1]) - start
                        guard abs(length - needle.count) <= budget else { continue }
                        guard (needleSignature & ~signatures[index]).nonzeroBitCount <= budget else { continue }
                        guard let distance = Fuzzy.distance(
                            base + start, length, needleBase, needle.count, maxDistance: budget
                        ), distance > 0 else { continue }
                        best.append((distance, documents[index], index))
                    }
                }
            }
            guard !best.isEmpty else { return [] }
            best.sort {
                $0.distance != $1.distance ? $0.distance < $1.distance : $0.documents > $1.documents
            }
            return best.prefix(limit).map { self.term(at: $0.index) }
        }

        private func term(at index: Int) -> String {
            let start = Int(offsets[index])
            let end = Int(offsets[index + 1])
            return String(decoding: bytes[start ..< end], as: UTF8.self)
        }

        // MARK: - Repair

        /// Corrections for every term the library has never seen.
        public func repair(
            _ terms: [String],
            expansionsPerTerm: Int = 2,
            maximumTerms: Int = 4
        ) -> Repair {
            guard !isEmpty else { return Repair(corrections: [:]) }
            var corrections: [String: [String]] = [:]
            for term in terms {
                guard corrections.count < maximumTerms else { break }
                guard term.utf8.count >= minimumTermLength, !contains(term) else { continue }
                let candidates = nearest(to: term, limit: expansionsPerTerm)
                guard !candidates.isEmpty else { continue }
                corrections[term] = candidates
            }
            return Repair(corrections: corrections)
        }
    }

    /// What the repair found, and the two ways to spend it.
    public struct Repair: Sendable, Equatable {
        /// Misspelt term → the known terms it is nearest to, commonest first.
        public let corrections: [String: [String]]

        public var isEmpty: Bool { corrections.isEmpty }

        public init(corrections: [String: [String]]) {
            self.corrections = corrections
        }

        /// The terms to add to the keyword arm's `OR` expression.
        ///
        /// Additive, never a replacement: the original term stays in the
        /// expression, so a word that turns out to be a real (if rare) term
        /// still matches itself.
        public var extraTerms: [String] {
            var seen = Set<String>()
            var out: [String] = []
            for term in corrections.keys.sorted() {
                for candidate in corrections[term] ?? [] where seen.insert(candidate).inserted {
                    out.append(candidate)
                }
            }
            return out
        }

        /// The query with each misspelling swapped for its best candidate —
        /// what the **vector** arm embeds.
        ///
        /// This is the half that matters most. FTS5 simply ignores a term it
        /// has never indexed, but a sentence embedder does not ignore anything:
        /// `"crul"` tokenises to `cr ##ul` and drags the whole sentence vector
        /// away from the note that answers it. One substitution puts it back.
        ///
        /// Case and punctuation around the word are preserved; only the word
        /// itself is replaced, and only whole words are matched.
        public func rewrite(_ query: String) -> String {
            guard !corrections.isEmpty else { return query }
            var out = ""
            out.reserveCapacity(query.count)
            var word = ""
            for character in query {
                if character.isLetter || character.isNumber {
                    word.append(character)
                } else {
                    out += replacement(for: word)
                    word = ""
                    out.append(character)
                }
            }
            out += replacement(for: word)
            return out
        }

        private func replacement(for word: String) -> String {
            guard !word.isEmpty else { return word }
            guard let best = corrections[SearchQuery.fold(word)]?.first else { return word }
            return best
        }
    }
}
