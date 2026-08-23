import Foundation

/// A user's raw search text, reduced to the pieces the FTS layer can use
/// safely (FR-5.1).
///
/// FTS5's query language is a real grammar: `"`, `*`, `:`, `^`, `(`, `-`, `NOT`
/// and friends all mean something, and feeding a half-typed query straight to
/// `MATCH` is a syntax error per keystroke. So nothing the user types is ever
/// interpreted as syntax — the query is split into literal terms and every term
/// is re-quoted. `"` inside a term becomes `""`, which is the only escape FTS5
/// has.
struct SearchQuery: Sendable, Equatable {
    /// Whitespace-trimmed input, exactly as typed.
    let raw: String
    /// Case- and diacritic-folded `raw`, for literal comparisons.
    let folded: String
    /// Alphanumeric runs, folded. Emoji and punctuation are not terms — they
    /// reach the index through the trigram table instead.
    let terms: [String]

    init(_ text: String) {
        raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = Self.fold(raw)
        terms = raw
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { Self.fold(String($0)) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { raw.isEmpty }

    /// Folding used everywhere a literal comparison happens, so "CURL", "curl"
    /// and "cürl" all agree.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// An FTS5 `MATCH` expression for the `unicode61` table: every term quoted,
    /// combined with `AND`, and the last term treated as a prefix so results
    /// appear while the word is still being typed.
    ///
    /// `nil` when there is nothing a word tokenizer could match (an emoji-only
    /// or punctuation-only query).
    var unicode61Expression: String? {
        guard let last = terms.last else { return nil }
        var parts = terms.dropLast().map { Self.quote($0) }
        parts.append(Self.quote(last) + "*")
        return parts.joined(separator: " AND ")
    }

    /// The same, restricted to the title column.
    var titleExpression: String? {
        unicode61Expression.map { "{title} : (\($0))" }
    }

    /// An FTS5 phrase for the `trigram` table — the whole raw query as one
    /// literal substring. `nil` below three characters, which is the trigram
    /// tokenizer's floor.
    var trigramExpression: String? {
        guard raw.count >= 3 else { return nil }
        return Self.quote(raw)
    }

    /// Wraps a literal in FTS5 double quotes, doubling any it contains.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
