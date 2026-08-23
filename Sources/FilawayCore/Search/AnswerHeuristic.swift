import Foundation

/// The offline answer card (M3-05, FR-5.5).
///
/// When Claude is unreachable, disabled, slow or simply not configured, the
/// panel still has a ranked list — and quite often the answer is sitting at the
/// top of it. This picks the top chunk when one of two things is true:
///
/// 1. **It is a code chunk and it won clearly.** A fenced block whose fused
///    score beats the runner-up by ``scoreMargin`` is the "curl command to
///    fetch documents" case: FR-5.2's card exists precisely for it.
/// 2. **The query's content words are mostly in it.** A prose chunk that
///    contains ``wordCoverage`` of what was asked is a defensible best match
///    even without a model to confirm it.
///
/// Everything else returns `nil`, which the panel renders as "No good match"
/// above the list. Guessing badly is worse than not guessing: a wrong card is
/// read as an answer, whereas a missing card is read as "look at the list".
public struct AnswerHeuristic: Sendable, Hashable {
    /// Relative margin the top chunk needs over the runner-up, `0 ... 1`.
    public var scoreMargin: Double
    /// Fraction of the query's content words that must appear in the chunk.
    public var wordCoverage: Double
    /// A card's snippet never gets longer than this.
    public var maxSnippetLines: Int
    /// Words that say nothing about topic, so they never count against
    /// coverage. Shared with ``TitleOverlapCandidateFinder``.
    public var stopWords: Set<String>

    public init(
        scoreMargin: Double = 0.15,
        wordCoverage: Double = 0.6,
        maxSnippetLines: Int = 24,
        stopWords: Set<String>? = nil
    ) {
        self.scoreMargin = max(0, scoreMargin)
        self.wordCoverage = min(max(wordCoverage, 0), 1)
        self.maxSnippetLines = max(1, maxSnippetLines)
        self.stopWords = stopWords ?? Self.defaultStopWords
    }

    /// Question words and filler that carry no topic — a query is judged on
    /// what is left after these come out.
    public static let defaultStopWords: Set<String> = TitleOverlapCandidateFinder.stopWords
        .union([
            "command", "commands", "find", "show", "tell", "give", "need", "want", "about",
            "where", "which", "who", "did", "does", "was", "were", "into", "onto", "some",
            "thing", "things", "again", "there", "here", "make", "made", "one", "two",
        ])

    /// The card, or `nil` when nothing in the list is convincing enough.
    public func card(query: String, chunks: [RankedChunk]) -> AnswerCard? {
        guard let top = chunks.first else { return nil }
        guard accepts(query: query, chunks: chunks) else { return nil }
        return Self.card(for: top, snippet: snippet(for: top))
    }

    /// The acceptance rule, exposed so the tests can assert each arm.
    public func accepts(query: String, chunks: [RankedChunk]) -> Bool {
        guard let top = chunks.first else { return false }
        if top.kind == .code, margin(of: chunks) >= scoreMargin { return true }
        return coverage(of: query, in: top.text) >= wordCoverage
    }

    /// `(top - second) / top`, or `1` when the top chunk stands alone.
    public func margin(of chunks: [RankedChunk]) -> Double {
        guard let top = chunks.first, top.score > 0 else { return 0 }
        guard chunks.count > 1 else { return 1 }
        return max(0, (top.score - chunks[1].score) / top.score)
    }

    /// Fraction of the query's content words present in the text. A query with
    /// nothing but stop words in it covers nothing, by definition.
    public func coverage(of query: String, in text: String) -> Double {
        let wanted = words(in: query)
        guard !wanted.isEmpty else { return 0 }
        let present = words(in: text)
        let hits = wanted.filter { word in
            present.contains(word) || present.contains { $0.hasPrefix(word) || word.hasPrefix($0) }
        }
        return Double(hits.count) / Double(wanted.count)
    }

    func words(in text: String) -> Set<String> {
        var out: Set<String> = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3, !stopWords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }

    /// What Copy puts on the pasteboard: the fenced body for a code chunk, the
    /// leading paragraph for prose — never the heading breadcrumb the chunker
    /// glued on the front for the embedder's benefit.
    public func snippet(for chunk: RankedChunk) -> String {
        let body = chunk.kind == .code
            ? (AnswerSnippet.fencedBody(in: chunk.text) ?? AnswerSnippet.strippedContext(of: chunk.text))
            : AnswerSnippet.leadingParagraph(of: chunk.text)
        return AnswerSnippet.limit(body, lines: maxSnippetLines)
    }

    /// Builds a card for a chunk with a snippet already chosen. Used by both
    /// the heuristic and the Claude path, so the two produce the same shape.
    public static func card(for chunk: RankedChunk, snippet: String) -> AnswerCard {
        AnswerCard(
            noteID: chunk.noteID,
            title: chunk.title,
            relativePath: chunk.relativePath,
            modified: chunk.modified,
            chunkID: chunk.id,
            chunkRange: chunk.range,
            snippetText: snippet,
            language: chunk.language,
            isCode: chunk.kind == .code,
            headingPath: chunk.headingPath
        )
    }
}

/// Pulling a showable snippet out of a chunk.
///
/// The chunker's `text` is built for the *embedder*: a code chunk carries its
/// heading trail and the paragraph above the fence so the vector knows what the
/// command is for. None of that belongs on the pasteboard when the user hits
/// Copy (FR-5.2: "one-click Copy" copies the snippet, not its context).
public enum AnswerSnippet {
    /// The lines between the first fence and its closer, or `nil` when the text
    /// has no fence.
    public static func fencedBody(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let opening = lines.firstIndex(where: { isFence($0) }) else { return nil }
        let marker = fenceMarker(lines[opening])
        var body: [String] = []
        var index = opening + 1
        while index < lines.count {
            let line = lines[index]
            if isFence(line), fenceMarker(line) == marker { break }
            body.append(line)
            index += 1
        }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Everything after the chunker's context header — used when a "code" chunk
    /// turns out to be an indented block with no fence at all.
    public static func strippedContext(of text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        guard paragraphs.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return paragraphs.dropFirst().joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first real paragraph, skipping a leading heading breadcrumb line.
    public static func leadingParagraph(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let candidate = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            return candidate
        }
        return trimmed
    }

    /// Caps a snippet at `lines`, keeping whole lines.
    public static func limit(_ text: String, lines limit: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > limit else { return text }
        return lines.prefix(limit).joined(separator: "\n") + "\n…"
    }

    /// `true` when `candidate` really is in `haystack`, ignoring indentation
    /// and trailing whitespace.
    ///
    /// This is the "never invent commands" check: the model's snippet is only
    /// shown when it can be found in the chunk it claimed to take it from.
    public static func isVerbatim(_ candidate: String, in haystack: String) -> Bool {
        let needle = normalize(candidate)
        guard !needle.isEmpty else { return false }
        return normalize(haystack).contains(needle)
    }

    static func normalize(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    static func fenceMarker(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("~~~") ? "~~~" : "```"
    }
}
