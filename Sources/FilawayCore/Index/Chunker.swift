import Foundation
import Markdown

/// What a chunk is made of. Code is kept apart from prose because FR-5.2's
/// answer card is usually *a command*, and because a fenced block embedded
/// with three paragraphs of prose around it stops looking like a command.
public enum ChunkKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// Headings, paragraphs, lists, quotes, tables.
    case prose
    /// One fenced (or indented) code block, plus the context line above it.
    case code
}

/// One embeddable piece of a note (M3-02, FR-5.4).
///
/// ``range`` is a UTF-16 range **in the note body** — the same coordinate
/// system as ``KeywordHit/matchRange`` — so a search result can open the note
/// scrolled to the chunk (FR-5.2). ``text`` is what actually goes to the
/// embedder, which is *not* the same thing: a code chunk's text carries the
/// heading path and the sentence that introduced the command, while its range
/// covers only the fence.
public struct NoteChunk: Sendable, Equatable {
    /// Position in the note, 0-based. Stable for a given body.
    public let ordinal: Int
    public let kind: ChunkKind
    /// Enclosing headings, outermost first (the note title is prepended by
    /// ``Chunker/chunk(_:)-(NoteText)``).
    public let headingPath: [String]
    /// Where the chunk sits in the body, in UTF-16 units, whole lines.
    public let range: MatchRange
    /// The text handed to the embedder.
    public let text: String
    /// Info string of a fenced block (`sh`, `swift`, …); `nil` for prose and
    /// for indented code.
    public let language: String?
    /// SHA-256 of ``text`` — the incremental indexer's diff key.
    public let textHash: String

    public init(
        ordinal: Int,
        kind: ChunkKind,
        headingPath: [String],
        range: MatchRange,
        text: String,
        language: String?
    ) {
        self.ordinal = ordinal
        self.kind = kind
        self.headingPath = headingPath
        self.range = range
        self.text = text
        self.language = language
        textHash = Hashing.sha256Hex(text)
    }

    /// `"Commands › Docker"`, for the result row's breadcrumb.
    public var headingBreadcrumb: String {
        headingPath.joined(separator: " › ")
    }
}

/// Splits a note body into embeddable chunks.
///
/// The shape is dictated by ADR-012 rather than by prose aesthetics: the
/// bundled model runs at a **fixed** sequence length of 256, so a 40-token
/// chunk costs exactly as much to embed as a 250-token one. Many small chunks
/// are therefore pure waste, and the target is 180–250 tokens.
///
/// Rules:
/// 1. **A heading starts a new chunk.** A section that fits the budget is one
///    chunk; a longer one is split at paragraph boundaries, and a single
///    paragraph too long for the budget is split at line boundaries.
/// 2. **Every code block is its own chunk**, carrying its language, its
///    heading path and the nearest preceding paragraph as context. That is the
///    FR-5.2 unit: "the curl command to fetch documents" must match the fence,
///    not the essay around it.
/// 3. **Ranges are whole lines**, so scroll-to never lands mid-word, and so
///    the mapping never depends on cmark's byte columns.
///
/// `Chunker` is a value: it holds no model and no state, so tests run it
/// without Core ML. Token counting is injectable and defaults to
/// ``TokenEstimate/wordPiece(_:)``; the indexer can pass
/// `CoreMLEmbedder.tokenCount` when exact budgeting matters.
public struct Chunker: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Upper bound for a chunk, in tokens. 220 leaves room under the
        /// model's 256 for `[CLS]`/`[SEP]` and the heading-path preamble.
        public var maxTokens: Int
        /// The floor for a chunk worth embedding on its own. A section smaller
        /// than this keeps accumulating across the next heading, and a trailing
        /// chunk smaller than this is merged back into the previous one.
        public var minTokens: Int
        /// Token budget for the context a code chunk carries.
        public var contextTokens: Int
        /// Hard cap, so one pathological 10 MB note cannot fill the index.
        public var maxChunks: Int
        /// Prepend the heading path to every chunk's text.
        public var includeHeadingPath: Bool

        public init(
            maxTokens: Int = 220,
            minTokens: Int = 64,
            contextTokens: Int = 60,
            maxChunks: Int = 400,
            includeHeadingPath: Bool = true
        ) {
            self.maxTokens = max(16, maxTokens)
            self.minTokens = max(0, min(minTokens, maxTokens / 2))
            self.contextTokens = max(0, contextTokens)
            self.maxChunks = max(1, maxChunks)
            self.includeHeadingPath = includeHeadingPath
        }
    }

    public let configuration: Configuration
    private let countTokens: @Sendable (String) -> Int

    public init(
        configuration: Configuration = .init(),
        countTokens: (@Sendable (String) -> Int)? = nil
    ) {
        self.configuration = configuration
        self.countTokens = countTokens ?? { TokenEstimate.wordPiece($0) }
    }

    /// Chunks an indexed note, seeding the heading path with its title.
    public func chunk(_ note: NoteText) -> [NoteChunk] {
        chunk(note.body, title: note.title)
    }

    /// Chunks a body.
    ///
    /// - Parameter title: prepended to every chunk's heading path. DS-1 makes
    ///   the filename the title, so it is often the only topical word in a
    ///   note full of commands.
    public func chunk(_ body: String, title: String? = nil) -> [NoteChunk] {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var builder = Builder(
            body: body,
            title: title,
            configuration: configuration,
            countTokens: countTokens
        )
        // `Document(parsing:)` gives every block a 1-based line range. Only the
        // lines are used (columns are UTF-8 byte offsets, which would need a
        // second mapping to reach UTF-16), so a chunk is always whole lines.
        let document = Document(parsing: body, options: [])
        builder.walk(blocks: Array(document.blockChildren))
        return builder.finish()
    }
}

// MARK: - The walk

extension Chunker {
    /// Accumulates blocks into chunks. A `struct` so the whole chunker stays a
    /// value type and trivially `Sendable`.
    fileprivate struct Builder {
        let lines: LineIndex
        let title: String?
        let configuration: Configuration
        let countTokens: @Sendable (String) -> Int

        private var headingPath: [String] = []
        private var headingLevels: [Int] = []
        /// Blocks waiting to become a prose chunk: (first line, last line).
        private var pending: [(first: Int, last: Int)] = []
        private var pendingTokens = 0
        /// The heading path in force when the pending run started — a chunk
        /// that spans two small sections is filed under the first of them.
        private var pendingHeadingPath: [String] = []
        /// Text of the most recent paragraph — a code block's context line.
        private var lastParagraph: String?
        private var chunks: [NoteChunk] = []

        init(
            body: String,
            title: String?,
            configuration: Configuration,
            countTokens: @escaping @Sendable (String) -> Int
        ) {
            lines = LineIndex(body)
            self.title = title
            self.configuration = configuration
            self.countTokens = countTokens
        }

        var fullHeadingPath: [String] {
            if let title, !title.isEmpty { return [title] + headingPath }
            return headingPath
        }

        mutating func walk(blocks: [any BlockMarkup]) {
            for block in blocks {
                guard chunks.count < configuration.maxChunks else { return }
                guard let span = lines.span(of: block) else { continue }

                switch block {
                case let heading as Heading:
                    // A heading normally starts a chunk — but only if the one
                    // in progress is worth embedding on its own. Notes full of
                    // one-line sections (release notes, command scratchpads)
                    // would otherwise produce dozens of 30-token chunks, each
                    // costing a full 256-token inference (ADR-012).
                    if pendingTokens >= configuration.minTokens { flushPending() }
                    push(heading: heading.plainText, level: heading.level)
                    // When the run in progress was too small to flush, whatever
                    // follows this heading is the chunk's real subject, so the
                    // breadcrumb follows the heading rather than the scrap
                    // above it.
                    if !pending.isEmpty { pendingHeadingPath = fullHeadingPath }
                    // The heading line itself opens the next prose chunk, so a
                    // section with nothing but a heading is still findable.
                    append(span)

                case let code as CodeBlock:
                    emitCode(span: span, language: code.language)

                case let html as HTMLBlock:
                    // Raw HTML is prose as far as retrieval is concerned.
                    _ = html
                    append(span)

                default:
                    if containsCodeBlock(block), let children = blockChildren(of: block) {
                        // A fenced block inside a list item or a quote is still
                        // "the command", so descend rather than swallowing it
                        // into one large prose chunk.
                        walk(blocks: children)
                    } else {
                        if let paragraph = block as? Paragraph {
                            lastParagraph = paragraph.plainText
                        }
                        append(span)
                    }
                }
            }
        }

        mutating func finish() -> [NoteChunk] {
            flushPending()
            return renumbered()
        }

        // MARK: Heading stack

        private mutating func push(heading: String, level: Int) {
            while let last = headingLevels.last, last >= level {
                headingLevels.removeLast()
                headingPath.removeLast()
            }
            headingLevels.append(level)
            headingPath.append(heading.trimmingCharacters(in: .whitespacesAndNewlines))
            lastParagraph = nil
        }

        // MARK: Prose

        private mutating func append(_ span: LineSpan) {
            let tokens = countTokens(lines.text(span))
            if pendingTokens + tokens > configuration.maxTokens, !pending.isEmpty {
                flushPending()
            }
            if tokens > configuration.maxTokens {
                // One block bigger than the whole budget: split it by lines so
                // a 4,000-word paragraph does not become a single truncated
                // chunk (the model would silently drop everything past 256).
                let path = fullHeadingPath
                for piece in splitByLines(span) { emitProse(span: piece, headingPath: path) }
                return
            }
            if pending.isEmpty { pendingHeadingPath = fullHeadingPath }
            pending.append((span.first, span.last))
            pendingTokens += tokens
        }

        private mutating func flushPending() {
            guard let first = pending.first, let last = pending.last else { return }
            emitProse(
                span: LineSpan(first: first.first, last: last.last), headingPath: pendingHeadingPath
            )
            pending.removeAll(keepingCapacity: true)
            pendingTokens = 0
        }

        private mutating func emitProse(span: LineSpan, headingPath path: [String]) {
            let source = lines.text(span)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // A tail too small to say anything on its own is folded back into
            // the previous chunk of the same section.
            if countTokens(source) < configuration.minTokens,
               let previous = chunks.last,
               previous.kind == .prose,
               previous.headingPath == path,
               previous.range.upperBound <= lines.location(ofLine: span.first) {
                let merged = LineSpan(first: lines.line(containingLocation: previous.range.location), last: span.last)
                chunks.removeLast()
                emit(kind: .prose, span: merged, text: decorated(lines.text(merged), path: path),
                     language: nil, headingPath: path)
                return
            }
            emit(kind: .prose, span: span, text: decorated(source, path: path),
                 language: nil, headingPath: path)
        }

        private func splitByLines(_ span: LineSpan) -> [LineSpan] {
            var out: [LineSpan] = []
            var start = span.first
            var tokens = 0
            for line in span.first ... span.last {
                let cost = countTokens(lines.line(line))
                if tokens > 0, tokens + cost > configuration.maxTokens {
                    out.append(LineSpan(first: start, last: line - 1))
                    start = line
                    tokens = 0
                }
                tokens += cost
            }
            out.append(LineSpan(first: start, last: span.last))
            return out
        }

        // MARK: Code

        private mutating func emitCode(span: LineSpan, language: String?) {
            // The prose that led up to the fence is the context, so flush it
            // *after* reading `lastParagraph` but before the code chunk, to
            // keep ordinals in source order.
            let context = lastParagraph
            flushPending()

            var header: [String] = []
            if configuration.includeHeadingPath, !fullHeadingPath.isEmpty {
                header.append(fullHeadingPath.joined(separator: " › "))
            }
            if let context, !context.isEmpty {
                header.append(truncate(context, toTokens: configuration.contextTokens))
            }
            let fence = truncate(lines.text(span), toTokens: configuration.maxTokens)
            let text = (header + [fence]).joined(separator: "\n")
            emit(
                kind: .code,
                span: span,
                text: text,
                language: language.flatMap { $0.isEmpty ? nil : $0.lowercased() },
                headingPath: fullHeadingPath
            )
        }

        // MARK: Emission

        private mutating func emit(
            kind: ChunkKind, span: LineSpan, text: String, language: String?, headingPath: [String]
        ) {
            guard chunks.count < configuration.maxChunks else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            chunks.append(NoteChunk(
                ordinal: chunks.count,
                kind: kind,
                headingPath: headingPath,
                range: lines.range(of: span),
                text: text,
                language: language
            ))
        }

        private func renumbered() -> [NoteChunk] {
            chunks.enumerated().map { index, chunk in
                chunk.ordinal == index ? chunk : NoteChunk(
                    ordinal: index,
                    kind: chunk.kind,
                    headingPath: chunk.headingPath,
                    range: chunk.range,
                    text: chunk.text,
                    language: chunk.language
                )
            }
        }

        private func decorated(_ source: String, path: [String]) -> String {
            guard configuration.includeHeadingPath, !path.isEmpty else { return source }
            let breadcrumb = path.joined(separator: " › ")
            // A chunk that already opens with its own heading does not need it
            // twice; the ancestors still help.
            return breadcrumb + "\n" + source
        }

        private func truncate(_ text: String, toTokens budget: Int) -> String {
            guard budget > 0, countTokens(text) > budget else { return text }
            var kept: [Substring] = []
            var tokens = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let cost = countTokens(String(line))
                if tokens > 0, tokens + cost > budget { break }
                kept.append(line)
                tokens += cost
                if tokens >= budget { break }
            }
            if kept.isEmpty, let first = text.split(separator: "\n", omittingEmptySubsequences: false).first {
                kept = [first]
            }
            return kept.joined(separator: "\n")
        }

        // MARK: Structure helpers

        private func blockChildren(of block: any Markup) -> [any BlockMarkup]? {
            let children = block.children.compactMap { $0 as? any BlockMarkup }
            return children.isEmpty ? nil : children
        }

        private func containsCodeBlock(_ block: any Markup) -> Bool {
            if block is CodeBlock { return true }
            for child in block.children where containsCodeBlock(child) { return true }
            return false
        }
    }
}

// MARK: - Lines

/// A closed range of 1-based source lines.
struct LineSpan: Equatable {
    var first: Int
    var last: Int
}

/// UTF-16 offsets of every line in a body.
///
/// swift-markdown reports positions as (line, column) where the column counts
/// **UTF-8 bytes**; the editor wants **UTF-16** offsets. Rather than carry two
/// mappings, chunks are whole lines and only the line table is needed — which
/// also means a chunk boundary can never land inside a grapheme.
struct LineIndex {
    /// UTF-16 offset of the first unit of each line (index 0 == line 1).
    private(set) var starts: [Int] = []
    /// UTF-16 offset just past the last *content* unit of each line
    /// (the newline, and a preceding `\r`, are excluded).
    private(set) var ends: [Int] = []
    private let source: [String]

    var count: Int { starts.count }

    init(_ body: String) {
        var lines: [String] = []
        var offset = 0
        // One pass over the string; `split` keeps the pieces as Substrings, so
        // the whole table costs one copy of the body and no index arithmetic
        // over Characters.
        for piece in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let width = piece.utf16.count
            var content = String(piece)
            if content.hasSuffix("\r") { content.removeLast() }
            starts.append(offset)
            ends.append(offset + content.utf16.count)
            lines.append(content)
            offset += width + 1  // + the newline that was consumed
        }
        if lines.isEmpty {
            starts = [0]
            ends = [0]
            lines = [""]
        }
        source = lines
    }

    /// The 1-based line span a markup element occupies, clamped to the body.
    func span(of markup: any Markup) -> LineSpan? {
        guard let range = markup.range else { return nil }
        let first = max(1, min(range.lowerBound.line, count))
        // An element's upper bound is exclusive in column terms but its `line`
        // is the last line it touches when the column is > 1; cmark reports the
        // end of a block as (lastLine, lastColumn+1), so no adjustment is
        // needed beyond clamping.
        let last = max(first, min(range.upperBound.line, count))
        return LineSpan(first: first, last: last)
    }

    func line(_ number: Int) -> String {
        source[max(0, min(number - 1, source.count - 1))]
    }

    func text(_ span: LineSpan) -> String {
        let first = max(1, min(span.first, count))
        let last = max(first, min(span.last, count))
        return source[(first - 1) ... (last - 1)].joined(separator: "\n")
    }

    func location(ofLine number: Int) -> Int {
        starts[max(0, min(number - 1, starts.count - 1))]
    }

    /// The 1-based line holding a UTF-16 offset.
    func line(containingLocation location: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    func range(of span: LineSpan) -> MatchRange {
        let first = max(1, min(span.first, count))
        let last = max(first, min(span.last, count))
        let location = starts[first - 1]
        return MatchRange(location: location, length: max(0, ends[last - 1] - location))
    }
}

// MARK: - Token estimation

/// A tokenizer-free estimate of WordPiece length.
///
/// The real count needs the model's vocabulary, which the chunker deliberately
/// does not depend on (tests must run without Core ML). This over-estimates
/// slightly for English prose and is close for code — the safe direction,
/// since overshooting the budget means truncation at the model.
public enum TokenEstimate {
    /// Approximate `[CLS] … [SEP]` WordPiece length of `text`.
    public static func wordPiece(_ text: String) -> Int {
        var total = 2  // [CLS] and [SEP]
        var wordLength = 0
        var wordIsWord = true

        func flush() {
            guard wordLength > 0 else { return }
            // Short alphanumeric words are one piece; longer or mixed ones get
            // split roughly every four characters, which is what WordPiece
            // does to identifiers, flags and paths.
            total += wordIsWord && wordLength <= 6 ? 1 : max(1, (wordLength + 3) / 4)
            wordLength = 0
            wordIsWord = true
        }

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar == "\n" {
                flush()
            } else if CharacterSet.alphanumerics.contains(scalar) {
                wordLength += 1
            } else {
                // Punctuation is always its own WordPiece token.
                flush()
                total += 1
            }
        }
        flush()
        return total
    }
}
