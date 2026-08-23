import Foundation

// MARK: - Public model

/// A style class produced by ``MarkdownHighlighter``.
///
/// The highlighter is deliberately UI-agnostic: it says *what* a span is, never
/// how it should look. `FilawayApp` maps these onto `NSAttributedString`
/// attributes (see `MarkdownTheme` / `MarkdownStyler`).
public enum MarkdownStyle: Equatable, Hashable, Sendable {
    /// Body text of an ATX heading, `level` in 1...6.
    case heading(level: Int)
    /// A syntax mark that stays visible but dimmed: `#`, `**`, `` ` ``, ```` ``` ````, `>`, `[`, `](`, `)`.
    case syntaxMarker
    case bold
    case italic
    case boldItalic
    case strikethrough
    /// Text of an inline code span, *excluding* the backticks.
    case inlineCode
    /// The whole opening/closing fence line of a fenced code block.
    case codeFence
    /// The info string (language tag) that follows an opening fence.
    case codeLanguage
    /// A content line inside a fenced code block.
    case codeBlock
    /// The `-`, `*`, `+` or `1.` that opens a list item.
    case listMarker
    /// The `[ ]` / `[x]` of a task-list item (the brackets included).
    case taskMarker(checked: Bool)
    /// Body text of a block quote line.
    case blockQuote
    /// A `---` / `***` thematic break line.
    case thematicBreak
    /// The visible text of a `[text](url)` link.
    case link
    /// The URL part of a `[text](url)` link.
    case linkURL
}

/// A styled range, in **UTF-16 offsets** — the coordinate system `NSTextStorage`
/// and `NSRange` use, so the app layer can apply spans without conversion.
///
/// Spans are returned in *application order*: block-level spans for a line come
/// before the inline spans nested inside them, so a consumer can simply apply
/// them front to back and let later attributes win.
public struct MarkdownSpan: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let style: MarkdownStyle

    public init(location: Int, length: Int, style: MarkdownStyle) {
        self.location = location
        self.length = length
        self.style = style
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    public var upperBound: Int { location + length }
}

/// The outcome of a (re)highlight: the range whose attributes the caller must
/// reset, and the spans to apply inside it.
public struct MarkdownHighlightResult: Equatable, Sendable {
    /// UTF-16 range covering every line that was restyled.
    public let invalidatedLocation: Int
    public let invalidatedLength: Int
    public let spans: [MarkdownSpan]

    public var invalidatedRange: NSRange {
        NSRange(location: invalidatedLocation, length: invalidatedLength)
    }

    public init(invalidatedLocation: Int, invalidatedLength: Int, spans: [MarkdownSpan]) {
        self.invalidatedLocation = invalidatedLocation
        self.invalidatedLength = invalidatedLength
        self.spans = spans
    }
}

/// A fenced code block, as needed by the editor's background + hover `Copy`
/// overlay (FR-2.2).
public struct MarkdownCodeBlock: Equatable, Sendable {
    /// Whole block including both fence lines (and the closing fence's newline).
    public let location: Int
    public let length: Int
    /// The code itself: everything between the fence lines, excluding the
    /// opening fence's newline and the closing fence line.
    public let contentLocation: Int
    public let contentLength: Int
    /// Info string of the opening fence, `nil` when absent.
    public let language: String?
    /// `false` for a fence that runs to the end of the document unterminated.
    public let isClosed: Bool

    public var range: NSRange { NSRange(location: location, length: length) }
    public var contentRange: NSRange { NSRange(location: contentLocation, length: contentLength) }

    public init(
        location: Int, length: Int,
        contentLocation: Int, contentLength: Int,
        language: String?, isClosed: Bool
    ) {
        self.location = location
        self.length = length
        self.contentLocation = contentLocation
        self.contentLength = contentLength
        self.language = language
        self.isClosed = isClosed
    }
}

/// A task-list checkbox found on a single line.
public struct MarkdownTaskMarker: Equatable, Sendable {
    /// Offset of `[` **relative to the start of the line**, in UTF-16 units.
    public let location: Int
    /// Always 3 (`[ ]`), kept explicit for callers that splice text.
    public let length: Int
    public let isChecked: Bool

    public var range: NSRange { NSRange(location: location, length: length) }
}

// MARK: - Highlighter

/// Incremental, line-oriented Markdown highlighter for the editor's typing path.
///
/// Not a Markdown *parser*: `swift-markdown` does structure (chunking, code
/// extraction). This exists because cmark is not incremental and the keystroke
/// path must be O(changed lines), never O(document) (plan §1, "Markdown
/// parsing").
///
/// It keeps its own mirror of the document as a UTF-16 code-unit array plus a
/// line index carrying the fenced-code state at each line start. An edit
/// re-tokenizes only the lines it touches; when the fence state at the end of
/// those lines changes (typing an opening ```` ``` ````), tokenization continues
/// forward until the state re-converges — the only case where a single edit can
/// cost O(document).
///
/// Not thread-safe by design: it is owned by the editor on the main actor.
public final class MarkdownHighlighter {

    // MARK: Line index

    fileprivate struct FenceState: Equatable {
        /// 0 when not inside a fence, otherwise the fence character (`` ` `` or `~`).
        var char: UInt16 = 0
        var count: Int = 0
        var indent: Int = 0

        static let none = FenceState()
        var isOpen: Bool { char != 0 }
    }

    fileprivate struct Line {
        /// UTF-16 offset of the first character of the line.
        var start: Int
        /// Length including the line terminator, if any.
        var length: Int
        /// Length of the line terminator (0, 1 for `\n`/`\r`, 2 for `\r\n`).
        var terminator: Int
        /// Fenced-code state *entering* this line.
        var state: FenceState

        var end: Int { start + length }
        var contentEnd: Int { start + length - terminator }
    }

    private var chars: [UInt16] = []
    private var lines: [Line] = [Line(start: 0, length: 0, terminator: 0, state: .none)]
    private var codeBlockCache: [MarkdownCodeBlock]?

    public init() {}

    public convenience init(text: String) {
        self.init()
        _ = setText(text)
    }

    /// Total document length in UTF-16 units, as the highlighter sees it.
    public var length: Int { chars.count }

    /// The document the highlighter currently mirrors. Mostly for tests — the
    /// editor's `NSTextStorage` is the real source of truth.
    public var text: String {
        String(decoding: chars, as: UTF16.self)
    }

    // MARK: Entry points

    /// Full (re)parse. Use on note switch or when loading a file.
    @discardableResult
    public func setText(_ text: String) -> MarkdownHighlightResult {
        chars = Array(text.utf16)
        lines = []
        codeBlockCache = nil
        var spans: [MarkdownSpan] = []
        spans.reserveCapacity(chars.count / 24 + 8)
        var state = FenceState.none
        var pos = 0
        while pos < chars.count {
            let line = makeLine(at: pos, state: state)
            lines.append(line)
            state = tokenize(line: line, into: &spans)
            pos = line.end
        }
        // Trailing empty line (document ends with a newline, or is empty).
        lines.append(Line(start: chars.count, length: 0, terminator: 0, state: state))
        return MarkdownHighlightResult(
            invalidatedLocation: 0, invalidatedLength: chars.count, spans: spans
        )
    }

    /// Incremental edit — the fast path. `range` is in **old** coordinates
    /// (exactly what `NSTextStorageDelegate` / `textView(_:shouldChangeTextIn:)`
    /// hand you before the edit lands).
    @discardableResult
    public func replace(range: NSRange, with replacement: String) -> MarkdownHighlightResult {
        replace(range: range, withUTF16: Array(replacement.utf16))
    }

    /// Convenience for callers holding only the *new* full text plus the edited
    /// range in new coordinates (`NSTextStorage.editedRange` + `changeInLength`).
    ///
    /// Slower than ``replace(range:with:)`` because it has to slice the new text
    /// out of a `String`; prefer the other entry point on the keystroke path.
    @discardableResult
    public func update(text: String, editedRange: NSRange, changeInLength delta: Int) -> MarkdownHighlightResult {
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        guard oldRange.length >= 0, editedRange.length >= 0 else { return setText(text) }
        let utf16 = Array(text.utf16)
        guard editedRange.upperBound <= utf16.count, oldRange.upperBound <= chars.count else {
            return setText(text)
        }
        let replacement = Array(utf16[editedRange.location ..< editedRange.upperBound])
        let result = replace(range: oldRange, withUTF16: replacement)
        return result
    }

    @discardableResult
    private func replace(range: NSRange, withUTF16 replacement: [UInt16]) -> MarkdownHighlightResult {
        // Clamp rather than trap if a caller ever hands us a stale range.
        let lower = min(max(range.location, 0), chars.count)
        let upper = min(max(range.upperBound, lower), chars.count)
        codeBlockCache = nil

        let delta = replacement.count - (upper - lower)
        let firstLine = lineIndex(containing: lower)
        var lastLine = lineIndex(containing: upper)
        if lastLine >= lines.count { lastLine = lines.count - 1 }

        let regionStart = lines[firstLine].start
        let newRegionEnd = lines[lastLine].end + delta

        chars.replaceSubrange(lower ..< upper, with: replacement)

        // Re-scan lines from the start of the first touched line until we pass
        // the end of the touched region on a line boundary.
        var rebuilt: [Line] = []
        var spans: [MarkdownSpan] = []
        var state = lines[firstLine].state
        var pos = regionStart
        while pos < chars.count && (pos < newRegionEnd || rebuilt.isEmpty) {
            let line = makeLine(at: pos, state: state)
            rebuilt.append(line)
            state = tokenize(line: line, into: &spans)
            pos = line.end
        }
        if pos >= chars.count {
            rebuilt.append(Line(start: chars.count, length: 0, terminator: 0, state: state))
        }

        // Which old lines did the re-scan consume? `pos` sits on a boundary that
        // maps back to an old boundary because pos >= newRegionEnd >= edit end.
        let consumedOldEnd = pos - delta
        var lastConsumed = firstLine
        while lastConsumed + 1 < lines.count && lines[lastConsumed].end < consumedOldEnd {
            lastConsumed += 1
        }
        if pos >= chars.count { lastConsumed = lines.count - 1 }

        lines.replaceSubrange(firstLine ... lastConsumed, with: rebuilt)

        // Shift everything after the rebuilt region.
        let firstUntouched = firstLine + rebuilt.count
        if delta != 0 && firstUntouched < lines.count {
            for i in firstUntouched ..< lines.count { lines[i].start += delta }
        }

        var invalidatedEnd = pos

        // Fence state spilled past the edited lines? Keep re-tokenizing forward
        // until the state re-converges with what the index already recorded.
        var incoming = state
        var i = firstUntouched
        while i < lines.count, lines[i].state != incoming {
            lines[i].state = incoming
            if lines[i].length == 0 { break } // trailing sentinel line
            incoming = tokenize(line: lines[i], into: &spans)
            invalidatedEnd = lines[i].end
            i += 1
        }

        return MarkdownHighlightResult(
            invalidatedLocation: regionStart,
            invalidatedLength: invalidatedEnd - regionStart,
            spans: spans
        )
    }

    /// Re-tokenize an arbitrary UTF-16 range without editing (used when the view
    /// needs spans for a viewport it has not styled yet).
    public func spans(in range: NSRange) -> MarkdownHighlightResult {
        let lo = min(max(range.location, 0), chars.count)
        let hi = min(max(range.upperBound, lo), chars.count)
        let first = lineIndex(containing: lo)
        var last = lineIndex(containing: hi)
        if last >= lines.count { last = lines.count - 1 }
        var spans: [MarkdownSpan] = []
        var i = first
        while i <= last && i < lines.count {
            if lines[i].length > 0 { _ = tokenize(line: lines[i], into: &spans) }
            i += 1
        }
        let start = lines[first].start
        let end = min(lines[last].end, chars.count)
        return MarkdownHighlightResult(
            invalidatedLocation: start, invalidatedLength: max(0, end - start), spans: spans
        )
    }

    // MARK: Derived views

    /// Every fenced code block in the document, in order. Computed lazily from
    /// the line index (no re-scan of the text body) and cached until the next
    /// edit.
    public var codeBlocks: [MarkdownCodeBlock] {
        if let cached = codeBlockCache { return cached }
        var blocks: [MarkdownCodeBlock] = []
        var openLine: Int?
        // The last entry is always a zero-length sentinel; skip it.
        for i in 0 ..< lines.count where lines[i].length > 0 && i + 1 < lines.count {
            let line = lines[i]
            let wasOpen = line.state.isOpen
            let nextState = lines[i + 1].state
            if !wasOpen && nextState.isOpen {
                openLine = i
            } else if wasOpen && !nextState.isOpen, let open = openLine {
                blocks.append(makeCodeBlock(openLine: open, closeLine: i, isClosed: true))
                openLine = nil
            }
        }
        if let open = openLine {
            blocks.append(makeCodeBlock(openLine: open, closeLine: nil, isClosed: false))
        }
        codeBlockCache = blocks
        return blocks
    }

    /// The fenced code block containing `index`, if any.
    public func codeBlock(containing index: Int) -> MarkdownCodeBlock? {
        codeBlocks.first { index >= $0.location && index < $0.location + $0.length }
    }

    /// UTF-16 range of the line containing `index` (terminator included), mirroring
    /// `NSString.lineRange(for:)` but without touching the text storage.
    public func lineRange(containing index: Int) -> NSRange {
        let i = lineIndex(containing: min(max(index, 0), chars.count))
        let line = lines[min(i, lines.count - 1)]
        return NSRange(location: line.start, length: line.length)
    }

    private func makeCodeBlock(openLine: Int, closeLine: Int?, isClosed: Bool) -> MarkdownCodeBlock {
        let open = lines[openLine]
        let language = fenceInfoString(line: open)
        let contentStart = open.end
        let contentEnd: Int
        let blockEnd: Int
        if let closeLine {
            contentEnd = lines[closeLine].start
            blockEnd = lines[closeLine].end
        } else {
            contentEnd = chars.count
            blockEnd = chars.count
        }
        return MarkdownCodeBlock(
            location: open.start,
            length: blockEnd - open.start,
            contentLocation: min(contentStart, contentEnd),
            contentLength: max(0, contentEnd - contentStart),
            language: language,
            isClosed: isClosed
        )
    }

    // MARK: Line index helpers

    private func lineIndex(containing offset: Int) -> Int {
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= offset { lo = mid } else { hi = mid - 1 }
        }
        // An offset exactly on a line boundary belongs to the line that starts
        // there — unless the previous line has no terminator (it is the last
        // line of a document that does not end in a newline, and the boundary is
        // the zero-length sentinel). Text inserted there *extends* that line.
        if lo > 0, lines[lo].start == offset, lines[lo - 1].terminator == 0 { lo -= 1 }
        return lo
    }

    private func makeLine(at start: Int, state: FenceState) -> Line {
        var i = start
        while i < chars.count && chars[i] != Ch.lf && chars[i] != Ch.cr { i += 1 }
        var terminator = 0
        if i < chars.count {
            if chars[i] == Ch.cr && i + 1 < chars.count && chars[i + 1] == Ch.lf {
                terminator = 2
            } else {
                terminator = 1
            }
        }
        return Line(start: start, length: i - start + terminator, terminator: terminator, state: state)
    }
}

// MARK: - Tokenizer

private enum Ch {
    static let lf: UInt16 = 0x0A
    static let cr: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let hash: UInt16 = 0x23
    static let backtick: UInt16 = 0x60
    static let tilde: UInt16 = 0x7E
    static let star: UInt16 = 0x2A
    static let underscore: UInt16 = 0x5F
    static let dash: UInt16 = 0x2D
    static let plus: UInt16 = 0x2B
    static let gt: UInt16 = 0x3E
    static let lbracket: UInt16 = 0x5B
    static let rbracket: UInt16 = 0x5D
    static let lparen: UInt16 = 0x28
    static let rparen: UInt16 = 0x29
    static let bang: UInt16 = 0x21
    static let dot: UInt16 = 0x2E
    static let backslash: UInt16 = 0x5C
    static let x: UInt16 = 0x78
    static let X: UInt16 = 0x58
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39

    static func isDigit(_ c: UInt16) -> Bool { c >= zero && c <= nine }
    static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }
    static func isAlnum(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
}

extension MarkdownHighlighter {

    /// Style one line and return the fenced-code state *leaving* it.
    fileprivate func tokenize(line: Line, into spans: inout [MarkdownSpan]) -> FenceState {
        let start = line.start
        let end = line.contentEnd
        guard end >= start else { return line.state }

        if line.state.isOpen {
            // Inside a fenced block: only a matching closing fence ends it.
            if let fence = scanFence(from: start, to: end), fence.char == line.state.char,
               fence.count >= line.state.count, fence.infoEnd == fence.infoStart {
                if line.length > 0 {
                    spans.append(MarkdownSpan(location: start, length: line.length, style: .codeFence))
                }
                return .none
            }
            if line.length > 0 {
                spans.append(MarkdownSpan(location: start, length: line.length, style: .codeBlock))
            }
            return line.state
        }

        if let fence = scanFence(from: start, to: end) {
            spans.append(MarkdownSpan(location: start, length: max(line.length, 0), style: .codeFence))
            spans.append(MarkdownSpan(
                location: fence.markerStart, length: fence.count, style: .syntaxMarker
            ))
            if fence.infoEnd > fence.infoStart {
                spans.append(MarkdownSpan(
                    location: fence.infoStart, length: fence.infoEnd - fence.infoStart,
                    style: .codeLanguage
                ))
            }
            return FenceState(char: fence.char, count: fence.count, indent: fence.indent)
        }

        var cursor = start
        var indent = 0
        while cursor < end && Ch.isSpace(chars[cursor]) && indent < 3 {
            cursor += 1
            indent += 1
        }

        // Thematic break: --- *** ___
        if let breakEnd = scanThematicBreak(from: cursor, to: end), breakEnd == end {
            spans.append(MarkdownSpan(location: start, length: line.length, style: .thematicBreak))
            return .none
        }

        // ATX heading
        if cursor < end && chars[cursor] == Ch.hash {
            var hashes = 0
            var i = cursor
            while i < end && chars[i] == Ch.hash && hashes < 7 { i += 1; hashes += 1 }
            if hashes >= 1 && hashes <= 6 && (i == end || Ch.isSpace(chars[i])) {
                var body = i
                while body < end && Ch.isSpace(chars[body]) { body += 1 }
                spans.append(MarkdownSpan(
                    location: start, length: line.length, style: .heading(level: hashes)
                ))
                spans.append(MarkdownSpan(
                    location: cursor, length: body - cursor, style: .syntaxMarker
                ))
                scanInline(from: body, to: end, into: &spans)
                return .none
            }
        }

        // Block quote (possibly nested `> >`)
        var quoted = false
        while cursor < end && chars[cursor] == Ch.gt {
            spans.append(MarkdownSpan(location: cursor, length: 1, style: .syntaxMarker))
            cursor += 1
            if cursor < end && Ch.isSpace(chars[cursor]) { cursor += 1 }
            quoted = true
        }
        if quoted {
            spans.append(MarkdownSpan(location: cursor, length: end - cursor, style: .blockQuote))
        }

        // List item (any indent: nesting is a visual concern, not ours)
        var listCursor = cursor
        var listIndent = 0
        while listCursor < end && Ch.isSpace(chars[listCursor]) { listCursor += 1; listIndent += 1 }
        if let marker = scanListMarker(from: listCursor, to: end) {
            spans.append(MarkdownSpan(
                location: listCursor, length: marker.markerLength, style: .listMarker
            ))
            var body = marker.contentStart
            if let checked = scanTaskMarker(from: body, to: end) {
                spans.append(MarkdownSpan(
                    location: body, length: 3, style: .taskMarker(checked: checked)
                ))
                body += 3
                while body < end && Ch.isSpace(chars[body]) { body += 1 }
            }
            scanInline(from: body, to: end, into: &spans)
            return .none
        }

        scanInline(from: cursor, to: end, into: &spans)
        return .none
    }

    // MARK: Block scanners

    fileprivate struct FenceScan {
        var char: UInt16
        var count: Int
        var indent: Int
        var markerStart: Int
        var infoStart: Int
        var infoEnd: Int
    }

    fileprivate func scanFence(from start: Int, to end: Int) -> FenceScan? {
        var i = start
        var indent = 0
        while i < end && Ch.isSpace(chars[i]) && indent < 3 { i += 1; indent += 1 }
        guard i < end else { return nil }
        let ch = chars[i]
        guard ch == Ch.backtick || ch == Ch.tilde else { return nil }
        let markerStart = i
        var count = 0
        while i < end && chars[i] == ch { i += 1; count += 1 }
        guard count >= 3 else { return nil }
        var infoStart = i
        while infoStart < end && Ch.isSpace(chars[infoStart]) { infoStart += 1 }
        var infoEnd = end
        while infoEnd > infoStart && Ch.isSpace(chars[infoEnd - 1]) { infoEnd -= 1 }
        if ch == Ch.backtick {
            // A backtick fence's info string may not contain a backtick.
            for k in infoStart ..< infoEnd where chars[k] == Ch.backtick { return nil }
        }
        return FenceScan(
            char: ch, count: count, indent: indent,
            markerStart: markerStart, infoStart: infoStart, infoEnd: infoEnd
        )
    }

    fileprivate func fenceInfoString(line: Line) -> String? {
        guard let fence = scanFence(from: line.start, to: line.contentEnd),
              fence.infoEnd > fence.infoStart else { return nil }
        var word = fence.infoStart
        while word < fence.infoEnd && !Ch.isSpace(chars[word]) { word += 1 }
        return String(decoding: chars[fence.infoStart ..< word], as: UTF16.self)
    }

    private func scanThematicBreak(from start: Int, to end: Int) -> Int? {
        guard start < end else { return nil }
        let ch = chars[start]
        guard ch == Ch.dash || ch == Ch.star || ch == Ch.underscore else { return nil }
        var count = 0
        var i = start
        while i < end {
            if chars[i] == ch { count += 1 } else if !Ch.isSpace(chars[i]) { return nil }
            i += 1
        }
        return count >= 3 ? end : nil
    }

    private struct ListMarkerScan {
        var markerLength: Int
        var contentStart: Int
    }

    private func scanListMarker(from start: Int, to end: Int) -> ListMarkerScan? {
        guard start < end else { return nil }
        let ch = chars[start]
        if ch == Ch.dash || ch == Ch.star || ch == Ch.plus {
            // `- ` but never `---` (already handled) and never a bare `-`.
            guard start + 1 < end, Ch.isSpace(chars[start + 1]) else { return nil }
            var body = start + 1
            while body < end && Ch.isSpace(chars[body]) { body += 1 }
            return ListMarkerScan(markerLength: 1, contentStart: body)
        }
        if Ch.isDigit(ch) {
            var i = start
            var digits = 0
            while i < end && Ch.isDigit(chars[i]) && digits < 9 { i += 1; digits += 1 }
            guard i < end, chars[i] == Ch.dot || chars[i] == Ch.rparen else { return nil }
            i += 1
            guard i < end, Ch.isSpace(chars[i]) else { return nil }
            let markerLength = i - start
            var body = i
            while body < end && Ch.isSpace(chars[body]) { body += 1 }
            return ListMarkerScan(markerLength: markerLength, contentStart: body)
        }
        return nil
    }

    /// `true`/`false` = checked/unchecked task marker at `start`; `nil` = not one.
    private func scanTaskMarker(from start: Int, to end: Int) -> Bool? {
        guard start + 2 < end, chars[start] == Ch.lbracket, chars[start + 2] == Ch.rbracket else {
            return nil
        }
        let inner = chars[start + 1]
        if inner == Ch.space { return false }
        if inner == Ch.x || inner == Ch.X { return true }
        return nil
    }

    // MARK: Inline scanner

    private func scanInline(from start: Int, to end: Int, into spans: inout [MarkdownSpan]) {
        var i = start
        while i < end {
            let ch = chars[i]
            switch ch {
            case Ch.backslash:
                i += 2 // escaped character: skip both

            case Ch.backtick:
                if let close = scanInlineCode(from: i, to: end) {
                    let runLength = close.runLength
                    spans.append(MarkdownSpan(
                        location: i + runLength,
                        length: close.closeStart - (i + runLength),
                        style: .inlineCode
                    ))
                    spans.append(MarkdownSpan(location: i, length: runLength, style: .syntaxMarker))
                    spans.append(MarkdownSpan(
                        location: close.closeStart, length: runLength, style: .syntaxMarker
                    ))
                    i = close.closeStart + runLength
                } else {
                    i += 1
                }

            case Ch.star, Ch.underscore:
                if let emphasis = scanEmphasis(from: i, to: end) {
                    let style: MarkdownStyle
                    switch emphasis.markerLength {
                    case 1: style = .italic
                    case 2: style = .bold
                    default: style = .boldItalic
                    }
                    spans.append(MarkdownSpan(
                        location: i + emphasis.markerLength,
                        length: emphasis.closeStart - (i + emphasis.markerLength),
                        style: style
                    ))
                    spans.append(MarkdownSpan(
                        location: i, length: emphasis.markerLength, style: .syntaxMarker
                    ))
                    spans.append(MarkdownSpan(
                        location: emphasis.closeStart, length: emphasis.markerLength,
                        style: .syntaxMarker
                    ))
                    // Nested inline styling inside the emphasised run.
                    scanInline(from: i + emphasis.markerLength, to: emphasis.closeStart, into: &spans)
                    i = emphasis.closeStart + emphasis.markerLength
                } else {
                    i += 1
                }

            case Ch.tilde:
                if i + 1 < end, chars[i + 1] == Ch.tilde,
                   let closeStart = findRun(of: Ch.tilde, length: 2, from: i + 2, to: end) {
                    spans.append(MarkdownSpan(
                        location: i + 2, length: closeStart - (i + 2), style: .strikethrough
                    ))
                    spans.append(MarkdownSpan(location: i, length: 2, style: .syntaxMarker))
                    spans.append(MarkdownSpan(location: closeStart, length: 2, style: .syntaxMarker))
                    i = closeStart + 2
                } else {
                    i += 1
                }

            case Ch.lbracket, Ch.bang:
                if let link = scanLink(from: i, to: end) {
                    spans.append(MarkdownSpan(
                        location: link.openMarkerStart,
                        length: link.textStart - link.openMarkerStart,
                        style: .syntaxMarker
                    ))
                    spans.append(MarkdownSpan(
                        location: link.textStart, length: link.textEnd - link.textStart, style: .link
                    ))
                    spans.append(MarkdownSpan(
                        location: link.textEnd, length: link.urlStart - link.textEnd,
                        style: .syntaxMarker
                    ))
                    spans.append(MarkdownSpan(
                        location: link.urlStart, length: link.urlEnd - link.urlStart, style: .linkURL
                    ))
                    spans.append(MarkdownSpan(location: link.urlEnd, length: 1, style: .syntaxMarker))
                    i = link.urlEnd + 1
                } else {
                    i += 1
                }

            default:
                i += 1
            }
        }
    }

    private func scanInlineCode(from start: Int, to end: Int) -> (runLength: Int, closeStart: Int)? {
        var runLength = 0
        var i = start
        while i < end && chars[i] == Ch.backtick { i += 1; runLength += 1 }
        guard i < end else { return nil }
        var j = i
        while j < end {
            if chars[j] == Ch.backtick {
                var closeLength = 0
                let closeStart = j
                while j < end && chars[j] == Ch.backtick { j += 1; closeLength += 1 }
                if closeLength == runLength { return (runLength, closeStart) }
            } else {
                j += 1
            }
        }
        return nil
    }

    private func scanEmphasis(from start: Int, to end: Int) -> (markerLength: Int, closeStart: Int)? {
        let ch = chars[start]
        var runLength = 0
        var i = start
        while i < end && chars[i] == ch { i += 1; runLength += 1 }
        let markerLength = min(runLength, 3)
        guard i < end, !Ch.isSpace(chars[i]) else { return nil }
        // `snake_case` must not turn into emphasis.
        if ch == Ch.underscore, start > 0, Ch.isAlnum(chars[start - 1]) { return nil }
        var j = i
        while j < end {
            if chars[j] == ch {
                let closeStart = j
                var closeLength = 0
                while j < end && chars[j] == ch { j += 1; closeLength += 1 }
                guard closeLength >= markerLength else { continue }
                guard closeStart > start, !Ch.isSpace(chars[closeStart - 1]) else { continue }
                if ch == Ch.underscore, j < end, Ch.isAlnum(chars[j]) { continue }
                return (markerLength, closeStart + (closeLength - markerLength))
            }
            j += 1
        }
        return nil
    }

    private func findRun(of ch: UInt16, length: Int, from start: Int, to end: Int) -> Int? {
        var i = start
        while i < end {
            if chars[i] == ch {
                var run = 0
                let runStart = i
                while i < end && chars[i] == ch { i += 1; run += 1 }
                if run >= length { return runStart }
            } else {
                i += 1
            }
        }
        return nil
    }

    private struct LinkScan {
        var openMarkerStart: Int
        var textStart: Int
        var textEnd: Int
        var urlStart: Int
        var urlEnd: Int
    }

    private func scanLink(from start: Int, to end: Int) -> LinkScan? {
        var i = start
        if chars[i] == Ch.bang {
            guard i + 1 < end, chars[i + 1] == Ch.lbracket else { return nil }
            i += 1
        }
        guard chars[i] == Ch.lbracket else { return nil }
        let textStart = i + 1
        var j = textStart
        var depth = 1
        while j < end {
            if chars[j] == Ch.backslash { j += 2; continue }
            if chars[j] == Ch.lbracket { depth += 1 }
            if chars[j] == Ch.rbracket {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        guard j < end, chars[j] == Ch.rbracket, j + 1 < end, chars[j + 1] == Ch.lparen else {
            return nil
        }
        let textEnd = j
        let urlStart = j + 2
        var k = urlStart
        while k < end && chars[k] != Ch.rparen { k += 1 }
        guard k < end else { return nil }
        return LinkScan(
            openMarkerStart: start, textStart: textStart,
            textEnd: textEnd, urlStart: urlStart, urlEnd: k
        )
    }
}

// MARK: - Task-list helper (pure, line-local)

extension MarkdownHighlighter {
    /// Finds the task checkbox on a single line, if the line is a task-list item.
    ///
    /// Pure and line-local so the editor can answer "did the user click a
    /// checkbox?" without holding on to spans. The returned offset is relative
    /// to the start of `line` in UTF-16 units.
    public static func taskMarker(inLine line: String) -> MarkdownTaskMarker? {
        let units = Array(line.utf16)
        var i = 0
        while i < units.count && Ch.isSpace(units[i]) { i += 1 }
        guard i < units.count else { return nil }
        let bullet = units[i]
        if bullet == Ch.dash || bullet == Ch.star || bullet == Ch.plus {
            i += 1
        } else if Ch.isDigit(bullet) {
            var digits = 0
            while i < units.count && Ch.isDigit(units[i]) && digits < 9 { i += 1; digits += 1 }
            guard i < units.count, units[i] == Ch.dot || units[i] == Ch.rparen else { return nil }
            i += 1
        } else {
            return nil
        }
        guard i < units.count, Ch.isSpace(units[i]) else { return nil }
        while i < units.count && Ch.isSpace(units[i]) { i += 1 }
        guard i + 2 < units.count, units[i] == Ch.lbracket, units[i + 2] == Ch.rbracket else {
            return nil
        }
        let inner = units[i + 1]
        if inner == Ch.space {
            return MarkdownTaskMarker(location: i, length: 3, isChecked: false)
        }
        if inner == Ch.x || inner == Ch.X {
            return MarkdownTaskMarker(location: i, length: 3, isChecked: true)
        }
        return nil
    }

    /// The replacement text for toggling a checkbox found by ``taskMarker(inLine:)``.
    public static func toggledTaskMarker(isChecked: Bool) -> String {
        isChecked ? "[ ]" : "[x]"
    }
}
