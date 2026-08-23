import Foundation

/// A range in note text, in **UTF-16 offsets** so `NSTextView` can use it
/// directly (FR-5.2: clicking a result opens the note scrolled to the match).
///
/// `FilawayCore` never imports AppKit, so this is a plain value; the app layer
/// reads ``nsRange``.
public struct MatchRange: Sendable, Equatable, Hashable {
    /// UTF-16 offset of the first matched unit.
    public let location: Int
    /// Length in UTF-16 units.
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var upperBound: Int { location + length }
    public var isEmpty: Bool { length == 0 }
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    /// The matched substring, or `nil` if the range does not fit the text —
    /// which is what a correctness test should assert never happens.
    public func substring(in text: String) -> String? {
        guard let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }

    init?(_ range: Range<String.Index>, in text: String) {
        let ns = NSRange(range, in: text)
        guard ns.location != NSNotFound else { return nil }
        self.init(location: ns.location, length: ns.length)
    }
}

/// Finding the best place in a body to send the reader, and the snippet that
/// shows it.
enum SnippetBuilder {
    /// Characters of context kept before and after the match.
    static let leading = 48
    static let trailing = 130

    /// Locates the query in a body, preferring the whole phrase and falling
    /// back to its longest term.
    ///
    /// Comparison is case- and diacritic-insensitive, so the range comes back
    /// from Foundation's own matcher rather than from arithmetic on a folded
    /// copy — folding can change length (ﬁ → fi), and a range that is off by a
    /// character would scroll the editor to the wrong word.
    static func bestMatch(of query: SearchQuery, in body: String) -> Range<String.Index>? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if !query.raw.isEmpty, let range = body.range(of: query.raw, options: options) {
            return range
        }
        for term in query.terms.sorted(by: { $0.count > $1.count }) {
            if let range = body.range(of: term, options: options) { return range }
        }
        return nil
    }

    /// A one-line excerpt around `match` (or the head of the body when there is
    /// none), plus where the match sits inside that excerpt.
    static func snippet(of body: String, around match: Range<String.Index>?) -> (text: String, range: MatchRange?) {
        guard let match else {
            return (head(of: body), nil)
        }
        var start = match.lowerBound
        var count = 0
        while start > body.startIndex, count < leading {
            start = body.index(before: start)
            count += 1
        }
        var end = match.upperBound
        count = 0
        while end < body.endIndex, count < trailing {
            end = body.index(after: end)
            count += 1
        }

        // Collapsing each part separately would eat the space *between* them —
        // "# " before "Groceries" would become "#Groceries" — so a boundary
        // that was whitespace is put back explicitly.
        let rawPrefix = String(body[start ..< match.lowerBound])
        let rawSuffix = String(body[match.upperBound ..< end])
        var prefix = collapse(rawPrefix)
        var suffix = collapse(rawSuffix)
        let matched = collapse(String(body[match]))
        if !prefix.isEmpty, rawPrefix.last?.isWhitespace == true { prefix += " " }
        if !suffix.isEmpty, rawSuffix.first?.isWhitespace == true { suffix = " " + suffix }

        let ellipsisPrefix = start > body.startIndex ? "…" : ""
        let ellipsisSuffix = end < body.endIndex ? "…" : ""
        let text = ellipsisPrefix + prefix + matched + suffix + ellipsisSuffix
        let location = (ellipsisPrefix + prefix).utf16.count
        return (text, MatchRange(location: location, length: matched.utf16.count))
    }

    /// The first line or so of a body — the snippet for a title-only hit.
    static func head(of body: String) -> String {
        let trimmed = body.drop(while: { $0 == "#" || $0 == " " || $0.isNewline })
        return collapse(String(trimmed.prefix(leading + trailing)))
            + (trimmed.count > leading + trailing ? "…" : "")
    }

    /// Newlines and runs of whitespace become single spaces so a snippet is
    /// always one line, whatever it was cut from.
    static func collapse(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(character)
            }
        }
        return out
    }
}
