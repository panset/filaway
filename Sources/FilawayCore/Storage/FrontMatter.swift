import Foundation

/// A minimal YAML front-matter block (DS-2).
///
/// Filaway understands exactly three keys — `id`, `created`, `tags` — and writes
/// them only when *the app* saves a note. Everything else in the block (keys
/// from Obsidian, Jekyll, a colleague's script, comments, blank lines) is kept
/// as raw lines and re-emitted verbatim, so a foreign front-matter block
/// round-trips byte-for-byte.
///
/// The parser is deliberately hand-rolled rather than a YAML library: the
/// subset is tiny, a real YAML round-trip would reformat the user's file, and a
/// tolerant parser must never fail — an unparseable block is simply an opaque
/// block.
public struct FrontMatter: Sendable, Equatable {
    /// One `key: …` run of raw lines, in document order.
    ///
    /// Indented continuations, `- item` sequence entries, comments and blank
    /// lines belong to the entry above them. A block that starts with comments
    /// or blanks keeps them in a leading entry whose ``Entry/key`` is `""`.
    public struct Entry: Sendable, Equatable {
        public var key: String
        /// Line contents, terminators excluded.
        public var lines: [String]

        /// Terminator of each line as it was read, or empty when the lines were
        /// produced programmatically — the block's ``FrontMatter/lineEnding``
        /// then fills in. Keeping these is what lets a file with mixed line
        /// endings round-trip byte-for-byte. Only honoured when the count
        /// matches ``lines``.
        public internal(set) var lineTerminators: [String]

        public init(key: String, lines: [String], lineTerminators: [String] = []) {
            self.key = key
            self.lines = lines
            self.lineTerminators = lineTerminators
        }

        func terminator(at index: Int, default fallback: String) -> String {
            guard lineTerminators.count == lines.count, index < lineTerminators.count else { return fallback }
            return lineTerminators[index]
        }
    }

    /// Raw entries in document order.
    public private(set) var entries: [Entry]
    /// Line terminator used by the block: `"\n"` or `"\r\n"`.
    public var lineEnding: String
    /// The exact opening delimiter line, e.g. `"---"`.
    public var openDelimiter: String
    /// The exact closing delimiter line, e.g. `"---"` or `"..."`.
    public var closeDelimiter: String
    /// Terminator after the closing delimiter — empty when the file ends there.
    public var closeTerminator: String

    /// The order Filaway writes its own keys in when it has to add them.
    static let knownKeys = ["id", "created", "tags"]

    public init(
        entries: [Entry] = [],
        lineEnding: String = "\n",
        openDelimiter: String = "---",
        closeDelimiter: String = "---",
        closeTerminator: String? = nil
    ) {
        self.entries = entries
        self.lineEnding = lineEnding
        self.openDelimiter = openDelimiter
        self.closeDelimiter = closeDelimiter
        self.closeTerminator = closeTerminator ?? lineEnding
    }

    /// `true` when no key survives — the block would serialise as `---\n---\n`.
    public var isEmpty: Bool {
        entries.allSatisfy { $0.lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /// Keys in document order, excluding the leading comment pseudo-entry.
    public var keys: [String] { entries.map(\.key).filter { !$0.isEmpty } }

    /// Raw lines of a key exactly as they appear in the file, `nil` if absent.
    public func rawLines(forKey key: String) -> [String]? {
        entries.first { $0.key == key }?.lines
    }

    // MARK: - Known keys

    /// Filaway's stable note identity (DS-2, used for move detection in DS-4).
    ///
    /// Setting a value equal to the current one is a no-op, so the file's bytes
    /// do not change.
    public var id: NoteID? {
        get { scalar(forKey: "id").flatMap(NoteID.init) }
        set { setScalar("id", newValue?.uuidString, currentEquals: { $0 == newValue?.uuidString }) }
    }

    /// Creation timestamp, ISO-8601 UTC.
    public var created: Date? {
        get { scalar(forKey: "created").flatMap(ISO8601.date(from:)) }
        set {
            let text = newValue.map(ISO8601.string(from:))
            // Preserve the author's formatting when the instant is unchanged.
            let current = created
            if let newValue, let current, abs(current.timeIntervalSince(newValue)) < 1 { return }
            setScalar("created", text, currentEquals: { _ in false })
        }
    }

    /// Free-form tags. Reading accepts block sequences (`- tag` lines), flow
    /// sequences (`[a, b]`) and a bare comma-separated scalar.
    public var tags: [String] {
        get { parseTags() }
        set {
            guard newValue != parseTags() else { return }
            setEntry("tags", lines: Self.encodeTags(newValue))
        }
    }

    // MARK: - Parsing

    /// Parses the interior lines of a front-matter block (delimiters excluded).
    public static func parse(
        lines: [String],
        terminators: [String] = [],
        lineEnding: String = "\n",
        openDelimiter: String = "---",
        closeDelimiter: String = "---",
        closeTerminator: String? = nil
    ) -> FrontMatter {
        var entries: [Entry] = []
        for (index, line) in lines.enumerated() {
            let terminator = index < terminators.count ? terminators[index] : lineEnding
            if let key = Self.key(startingIn: line) {
                entries.append(Entry(key: key, lines: [line], lineTerminators: [terminator]))
            } else if entries.isEmpty {
                entries.append(Entry(key: "", lines: [line], lineTerminators: [terminator]))
            } else {
                entries[entries.count - 1].lines.append(line)
                entries[entries.count - 1].lineTerminators.append(terminator)
            }
        }
        return FrontMatter(
            entries: entries,
            lineEnding: lineEnding,
            openDelimiter: openDelimiter,
            closeDelimiter: closeDelimiter,
            closeTerminator: closeTerminator
        )
    }

    /// The block's lines, delimiters included, joined with ``lineEnding``.
    public func serialized() -> String {
        var out = openDelimiter + lineEnding
        for entry in entries {
            for (index, line) in entry.lines.enumerated() {
                out += line + entry.terminator(at: index, default: lineEnding)
            }
        }
        out += closeDelimiter + closeTerminator
        return out
    }

    /// A top-level `key:` at column zero, or `nil` for a continuation line.
    static func key(startingIn line: String) -> String? {
        guard let first = line.unicodeScalars.first, first != " ", first != "\t", first != "#", first != "-" else {
            return nil
        }
        var key = ""
        for character in line {
            if character == ":" {
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            if character == "#" { return nil }
            key.append(character)
        }
        return nil
    }

    /// Text after `key:` on the entry's first line, unquoted, or `nil` if absent.
    func scalar(forKey key: String) -> String? {
        guard let line = entries.first(where: { $0.key == key })?.lines.first else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let unquoted = Self.unquote(value)
        return unquoted.isEmpty ? nil : unquoted
    }

    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, let last = raw.last, first == last,
              first == "\"" || first == "'" else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner
    }

    private func parseTags() -> [String] {
        guard let entry = entries.first(where: { $0.key == "tags" }), let firstLine = entry.lines.first else { return [] }
        var inline = ""
        if let colon = firstLine.firstIndex(of: ":") {
            inline = String(firstLine[firstLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        if inline.hasPrefix("["), inline.hasSuffix("]") {
            let body = inline.dropFirst().dropLast()
            out = body.split(separator: ",").map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
        } else if !inline.isEmpty, !inline.hasPrefix("#") {
            out = inline.split(separator: ",").map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
        }
        for line in entry.lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { continue }
            let value = Self.unquote(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
            if !value.isEmpty { out.append(value) }
        }
        return out.filter { !$0.isEmpty }
    }

    // MARK: - Mutation

    private mutating func setScalar(_ key: String, _ value: String?, currentEquals: (String?) -> Bool) {
        guard !currentEquals(scalar(forKey: key)) else { return }
        guard let value else {
            entries.removeAll { $0.key == key }
            return
        }
        setEntry(key, lines: ["\(key): \(Self.encodeScalar(value))"])
    }

    /// Replaces (or inserts, in canonical order) the lines of one key.
    mutating func setEntry(_ key: String, lines: [String]) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].lines = lines
            return
        }
        entries.insert(Entry(key: key, lines: lines), at: insertionIndex(for: key))
    }

    private func insertionIndex(for key: String) -> Int {
        guard let rank = Self.knownKeys.firstIndex(of: key) else { return entries.count }
        var index = entries.first?.key.isEmpty == true ? 1 : 0
        for (offset, entry) in entries.enumerated() {
            guard let otherRank = Self.knownKeys.firstIndex(of: entry.key), otherRank < rank else { continue }
            index = offset + 1
        }
        return min(index, entries.count)
    }

    static func encodeScalar(_ value: String) -> String {
        let needsQuotes = value.isEmpty
            || value.first == " " || value.last == " "
            || value.contains(": ") || value.hasSuffix(":")
            || "#{}[]&*!|>'\"%@`,".contains(where: { value.first == $0 })
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func encodeTags(_ tags: [String]) -> [String] {
        guard !tags.isEmpty else { return ["tags: []"] }
        return ["tags:"] + tags.map { "  - \(encodeScalar($0))" }
    }
}

/// A Markdown file split into its optional front-matter block and its body.
///
/// `parse` never fails and never loses bytes: ``body`` is the remainder of the
/// file verbatim, so `MarkdownDocument.parse(text).serialized() == text` for
/// every input, LF or CRLF, with or without a BOM.
public struct MarkdownDocument: Sendable, Equatable {
    public var hasByteOrderMark: Bool
    public var frontMatter: FrontMatter?
    /// Clean Markdown — what the editor shows and what the chunker indexes.
    public var body: String

    public init(hasByteOrderMark: Bool = false, frontMatter: FrontMatter? = nil, body: String = "") {
        self.hasByteOrderMark = hasByteOrderMark
        self.frontMatter = frontMatter
        self.body = body
    }

    public static func parse(_ text: String) -> MarkdownDocument {
        var rest = Substring(text)
        var bom = false
        if rest.first == "\u{FEFF}" {
            bom = true
            rest = rest.dropFirst()
        }

        var cursor = rest.startIndex
        // Swift treats "\r\n" as a single `Character`, so the scan must test for
        // all three terminators rather than looking for a bare "\n".
        func nextLine() -> (content: String, terminator: String, next: Substring.Index)? {
            guard cursor < rest.endIndex else { return nil }
            var end = cursor
            var terminator = ""
            while end < rest.endIndex {
                let character = rest[end]
                if character == "\n" || character == "\r\n" || character == "\r" {
                    terminator = String(character)
                    break
                }
                end = rest.index(after: end)
            }
            let content = String(rest[cursor ..< end])
            let next = end < rest.endIndex ? rest.index(after: end) : rest.endIndex
            return (content, terminator, next)
        }

        guard let opening = nextLine(),
              opening.content.trimmingCharacters(in: .whitespaces) == "---",
              !opening.terminator.isEmpty
        else {
            return MarkdownDocument(hasByteOrderMark: bom, frontMatter: nil, body: String(rest))
        }

        let lineEnding = opening.terminator
        cursor = opening.next
        var lines: [String] = []
        var terminators: [String] = []
        while let line = nextLine() {
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                cursor = line.next
                let block = FrontMatter.parse(
                    lines: lines,
                    terminators: terminators,
                    lineEnding: lineEnding,
                    openDelimiter: opening.content,
                    closeDelimiter: line.content,
                    closeTerminator: line.terminator
                )
                return MarkdownDocument(hasByteOrderMark: bom, frontMatter: block, body: String(rest[cursor...]))
            }
            if line.terminator.isEmpty { break }  // EOF inside the block
            lines.append(line.content)
            terminators.append(line.terminator)
            cursor = line.next
        }
        // Unterminated block: not front-matter at all, the whole file is body.
        return MarkdownDocument(hasByteOrderMark: bom, frontMatter: nil, body: String(rest))
    }

    /// The full file contents.
    public func serialized() -> String {
        var out = hasByteOrderMark ? "\u{FEFF}" : ""
        if let frontMatter { out += frontMatter.serialized() }
        out += body
        return out
    }
}
