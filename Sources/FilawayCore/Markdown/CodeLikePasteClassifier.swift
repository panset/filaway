import Foundation

/// What a pasted string looks like (FR-2.4).
///
/// ``PasteKind/plain`` is the answer for everything Filaway is not sure about —
/// the affordance it drives is an offer, and an offer on ordinary prose is worse
/// than no offer at all.
public enum PasteKind: Equatable, Sendable {
    /// Nothing to offer: prose, a URL, a single word, already-fenced text.
    case plain
    /// A shell command or a transcript of a few. The associated value is the
    /// fence's language tag.
    case shellCommand(language: String)
    /// Source code, configuration or data. `nil` when the language is unclear —
    /// the fence is then opened bare.
    case code(language: String?)

    /// `true` for anything worth offering to wrap.
    public var isCodeLike: Bool { self != .plain }

    /// The tag to write after the opening fence, if any.
    public var fenceLanguage: String? {
        switch self {
        case .plain: return nil
        case let .shellCommand(language): return language
        case let .code(language): return language
        }
    }
}

/// Decides whether a pasted string looks enough like a shell command or code to
/// offer wrapping it in a fenced block (FR-2.4).
///
/// The whole design is **conservative**: an offer that fires on a paragraph of
/// prose or a pasted URL is a papercut the user meets several times a day, while
/// a missed offer costs three keystrokes. So every rule below has to clear a
/// specific, nameable shape — a shell prompt marker, a known command head with a
/// real argument, valid JSON, a YAML mapping, code punctuation in more than one
/// form — and a prose veto runs first.
///
/// ```swift
/// switch CodeLikePasteClassifier.classify(pasteboard.string ?? "") {
/// case .plain:                       break
/// case let .shellCommand(language):  offerWrap(language)
/// case let .code(language):          offerWrap(language ?? "")
/// }
/// ```
///
/// Pure `Foundation`, no regular expressions on the hot path, and no state: the
/// editor calls it once per paste on the main thread.
public enum CodeLikePasteClassifier {

    // MARK: - Entry point

    /// Classifies pasted text.
    ///
    /// - Parameters:
    ///   - text: the string that is about to be inserted.
    ///   - pasteboardTypes: the pasteboard's advertised type identifiers. Only
    ///     used to *veto* (a file promise is not a command) and to raise
    ///     confidence when the source declared source code. Pass `[]` when they
    ///     are unknown.
    public static func classify(_ text: String, pasteboardTypes: [String] = []) -> PasteKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }

        // A pasted file, image or URL promise is never a command.
        if pasteboardTypes.contains(where: vetoingTypes.contains) { return .plain }

        // Already fenced: wrapping a fence in a fence is never what was meant.
        if containsFence(trimmed) { return .plain }

        // Absurdly large pastes are almost always documents; the offer would
        // also be pointless, since the wrap has to rewrite the whole range.
        guard trimmed.utf16.count <= maxLength else { return .plain }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return .plain }

        // 1 — an explicit shell prompt marker is the one unambiguous signal, and
        //     it outranks the prose veto ("$ git status" is a command even in a
        //     sentence-shaped paste).
        if hasPromptMarkers(content) { return .shellCommand(language: "bash") }

        // 2 — prose veto. Everything below this line is a guess, and a guess on
        //     prose is the failure mode that matters.
        if looksLikeProse(content) { return .plain }

        // 3 — data shapes are exact enough to test rather than score.
        if isJSON(trimmed) { return .code(language: "json") }
        if isYAML(content) { return .code(language: "yaml") }

        // 4 — shell: known command heads, or an executable path, with real
        //     arguments.
        if let shell = shellKind(content) { return shell }

        // 5 — source code: two independent punctuation/keyword signals, or one
        //     signal plus a declared source-code pasteboard type.
        let strongTypes = pasteboardTypes.contains(where: sourceCodeTypes.contains)
        if let code = codeKind(content, lowerBar: strongTypes) { return code }

        return .plain
    }

    // MARK: - Tunables

    /// Longer than this and the paste is a document, not a snippet.
    static let maxLength = 200_000

    /// Pasteboard types that rule the offer out outright.
    private static let vetoingTypes: Set<String> = [
        "public.file-url", "NSFilenamesPboardType", "public.url",
        "public.png", "public.tiff", "public.jpeg", "com.apple.pasteboard.promised-file-url",
    ]

    /// Pasteboard types that mean the source app called it code.
    private static let sourceCodeTypes: Set<String> = [
        "public.source-code", "public.shell-script", "public.python-script",
        "public.c-source", "public.objective-c-source", "public.swift-source",
    ]

    /// Command names common enough in a notes app about commands that seeing one
    /// at the head of a line is real evidence. Deliberately not exhaustive.
    static let commandHeads: Set<String> = [
        "curl", "wget", "http", "httpie",
        "git", "gh", "hg", "svn",
        "docker", "docker-compose", "podman", "kubectl", "helm", "k9s", "minikube",
        "ssh", "scp", "rsync", "sftp", "telnet", "nc", "ping", "dig", "nslookup", "traceroute",
        "brew", "port", "apt", "apt-get", "yum", "dnf", "pacman", "snap",
        "npm", "npx", "pnpm", "yarn", "bun", "deno", "node",
        "pip", "pip3", "pipx", "poetry", "conda", "python", "python3", "uv", "ruff",
        "gem", "bundle", "rake", "rails",
        "cargo", "rustc", "rustup", "go", "swift", "swiftc", "xcodebuild", "xcrun",
        "make", "cmake", "ninja", "bazel", "gradle", "mvn", "ant",
        "grep", "rg", "ag", "sed", "awk", "cut", "sort", "uniq", "tr", "head", "tail",
        "wc", "xargs", "find", "fd", "jq", "yq", "tee",
        "ls", "cd", "pwd", "mkdir", "rmdir", "rm", "cp", "mv", "ln", "touch", "cat",
        "less", "more", "open", "chmod", "chown", "du", "df", "stat",
        "tar", "zip", "unzip", "gzip", "gunzip", "bzip2",
        "export", "source", "alias", "unset", "env", "which", "whereis", "type",
        "ps", "top", "htop", "kill", "killall", "pkill", "lsof", "sudo", "su",
        "systemctl", "service", "launchctl", "defaults", "codesign", "notarytool",
        "sqlite3", "psql", "mysql", "redis-cli", "mongo",
        "terraform", "ansible", "vagrant", "aws", "gcloud", "az",
        "echo", "printf", "read", "sleep", "date", "diff", "patch", "man",
        "vim", "nvim", "nano", "emacs", "code", "bash", "sh", "zsh", "fish",
    ]

    /// Words that give a sentence away. A "command" containing one of these,
    /// with no flag, path, pipe or quote anywhere on the line, is a sentence.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "and", "or", "but", "is", "was", "are", "were",
        "in", "on", "at", "for", "of", "with", "from", "about", "into", "over",
        "my", "your", "our", "their", "its", "this", "that", "these", "those",
        "it", "we", "you", "they", "he", "she", "i", "me", "us", "them",
        "should", "would", "could", "will", "can", "need", "needs", "want",
        "when", "then", "than", "because", "if", "so", "just", "also", "back",
    ]

    // MARK: - Fences

    /// `true` when the text already contains a fenced block, or opens one.
    static func containsFence(_ text: String) -> Bool {
        text.contains("```") || text.contains("~~~")
    }

    // MARK: - Shell prompt markers

    /// `$ ` / `% ` at the head of a line, followed by something that could be a
    /// command name.
    static func hasPromptMarkers(_ content: [String]) -> Bool {
        for line in content {
            let stripped = line.drop { $0 == " " || $0 == "\t" }
            guard let marker = stripped.first, marker == "$" || marker == "%" else { continue }
            let afterMarker = stripped.dropFirst()
            guard afterMarker.first == " " else { continue }
            let rest = afterMarker.drop { $0 == " " }
            guard let head = rest.split(separator: " ", maxSplits: 1).first else { continue }
            guard head.count >= 2, isCommandNameShaped(String(head)) else { continue }
            return true
        }
        return false
    }

    /// A bare command name: letters, digits, `_ . / -`, at least one letter, and
    /// not a number or a price.
    static func isCommandNameShaped(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var hasLetter = false
        for character in token {
            if character.isLetter { hasLetter = true; continue }
            if character.isNumber { continue }
            if character == "_" || character == "." || character == "/" || character == "-" { continue }
            return false
        }
        return hasLetter
    }

    // MARK: - Prose veto

    /// `true` when the paste reads like sentences.
    ///
    /// A line is prose when it has six or more words, ends in sentence
    /// punctuation or contains no code punctuation at all, and carries none of
    /// the marks code always has. Half the lines being prose is enough.
    static func looksLikeProse(_ content: [String]) -> Bool {
        var prose = 0
        for line in content where isProseLine(line) { prose += 1 }
        return Double(prose) >= Double(content.count) * 0.5
    }

    static func isProseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Anything with unmistakable code punctuation is not prose.
        if trimmed.contains("|") || trimmed.contains("&&") || trimmed.contains(";")
            || trimmed.contains("{") || trimmed.contains("}") || trimmed.contains("=")
            || trimmed.contains("$") || trimmed.contains("\t") { return false }
        let words = trimmed.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return false }
        // A flag or an explicit path is enough to disqualify a sentence.
        if words.contains(where: { $0.hasPrefix("-") && $0.count > 1 }) { return false }
        if words.contains(where: { $0.contains("/") && !$0.contains("://") }) { return false }
        let stops = words.filter { stopWords.contains(normalizedWord($0)) }.count
        let endsSentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
        return stops >= 2 || (endsSentence && stops >= 1 && words.count >= 6)
    }

    private static func normalizedWord(_ word: String) -> String {
        String(word.lowercased().drop { !$0.isLetter }.reversed().drop { !$0.isLetter }.reversed())
    }

    // MARK: - JSON

    /// Real JSON, decided by `JSONSerialization` rather than by shape.
    static func isJSON(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        guard let last = trimmed.last, last == "}" || last == "]" else { return false }
        // `{}` and `[]` are valid JSON and pointless to fence.
        guard trimmed.count > 6, let data = trimmed.data(using: .utf8) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        return object is [String: Any] || object is [Any]
    }

    // MARK: - YAML

    /// A YAML mapping or sequence: two or more lines that are `key: value` or
    /// `- item`, and no line that is a sentence.
    static func isYAML(_ content: [String]) -> Bool {
        guard content.count >= 2 else { return false }
        var shaped = 0
        for line in content {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { shaped += 1; continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" { shaped += 1; continue }
            if isMappingLine(trimmed) { shaped += 1; continue }
        }
        guard shaped == content.count else { return false }
        // At least one real `key:` — a list of bullets alone is Markdown.
        return content.contains { isMappingLine($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `key:` or `key: value`, with an identifier-shaped key.
    static func isMappingLine(_ trimmed: String) -> Bool {
        var candidate = Substring(trimmed)
        if candidate.hasPrefix("- ") { candidate = candidate.dropFirst(2) }
        guard let colon = candidate.firstIndex(of: ":") else { return false }
        let key = candidate[candidate.startIndex ..< colon]
        guard !key.isEmpty, key.count <= 64 else { return false }
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else {
            return false
        }
        guard key.contains(where: \.isLetter) else { return false }
        let rest = candidate[candidate.index(after: colon)...]
        return rest.isEmpty || rest.hasPrefix(" ")
    }

    // MARK: - Shell

    /// A command transcript: most lines start with a known command head (or an
    /// executable path) and carry a real argument.
    static func shellKind(_ content: [String]) -> PasteKind? {
        var commands = 0
        var continuations = 0
        for line in content {
            if isCommandLine(line) {
                commands += 1
            } else if isContinuationLine(line) {
                continuations += 1
            }
        }
        guard commands > 0 else { return nil }
        // Every line has to be a command or an obvious continuation of one:
        // a single command buried in a paragraph is not a code block.
        guard commands + continuations == content.count else { return nil }
        return .shellCommand(language: "bash")
    }

    /// One line of shell.
    static func isCommandLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var tokens = trimmed.split(separator: " ").map(String.init)
        // Environment prefixes and `sudo` never change what the line is. A
        // leading `NAME=value` is the strongest of the three: prose does not
        // open with an assignment.
        var hadEnvAssignment = false
        while let head = tokens.first, tokens.count > 1 {
            if head == "sudo" || head == "env" || head == "time" {
                tokens.removeFirst()
                continue
            }
            if isEnvironmentAssignment(head) {
                hadEnvAssignment = true
                tokens.removeFirst()
                continue
            }
            break
        }
        guard let head = tokens.first, tokens.count <= 24 else { return false }
        guard tokens.count >= 2 || hadEnvAssignment else { return false }

        let isKnown = commandHeads.contains(head)
        let isPath = (head.hasPrefix("./") || head.hasPrefix("/") || head.hasPrefix("~/")) && head.count > 2
        // `FOO=1 build/App/Contents/MacOS/App` — an assignment prefix makes any
        // path-shaped head a command.
        let isRelativeExecutable = hadEnvAssignment && head.contains("/") && head.count > 2
        guard isKnown || isPath || isRelativeExecutable else { return false }
        if hadEnvAssignment { return true }

        // A line with a flag, a path, a pipe, a quote or a variable is a command
        // whatever words it also contains.
        let hasShellPunctuation = trimmed.contains(" -") || trimmed.contains("|") || trimmed.contains("&&")
            || trimmed.contains(">") || trimmed.contains("\"") || trimmed.contains("'")
            || trimmed.contains("$") || trimmed.contains("/") || trimmed.contains("=")
        if hasShellPunctuation { return true }

        // Otherwise it has to read like a command, not a sentence.
        let stops = tokens.dropFirst().filter { stopWords.contains($0.lowercased()) }.count
        guard stops == 0 else { return false }
        guard !trimmed.hasSuffix(".") else { return false }
        return tokens.count <= 5
    }

    /// `NAME=value` with a shell-shaped variable name.
    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[token.startIndex ..< equals]
        guard name.first?.isLetter == true || name.first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A wrapped or chained continuation of the command above it.
    static func isContinuationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("|") || trimmed.hasPrefix("&&")
            || trimmed.hasPrefix(">") { return true }
        return line.hasSuffix("\\") || line.hasSuffix("|") || line.hasSuffix("&&")
    }

    // MARK: - Source code

    /// Source code, judged by independent signals rather than by language.
    ///
    /// - Parameter lowerBar: `true` when the pasteboard itself declared source
    ///   code, in which case one signal is enough.
    static func codeKind(_ content: [String], lowerBar: Bool) -> PasteKind? {
        guard content.count >= 2 || lowerBar else { return nil }

        // SQL is its own shape — a verb at the head and a clause keyword — and
        // scoring punctuation would never find it.
        if isSQL(content) { return .code(language: "sql") }

        var signals = 0

        // a) statement punctuation at line ends.
        let terminated = content.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed == "}"
                || trimmed.hasSuffix("):") || trimmed.hasSuffix(" =>")
        }.count
        if Double(terminated) >= Double(content.count) * 0.4 { signals += 1 }

        // b) operators that essentially never appear in prose.
        let operators = ["=>", "->", "::", "!==", "===", "!=", "&&", "||", "+=", "==", "<-"]
        if content.contains(where: { line in operators.contains { line.contains($0) } }) { signals += 1 }

        // c) a declaration keyword at the head of a line.
        if content.contains(where: { startsWithKeyword($0) }) { signals += 1 }

        // d) consistent indentation: two or more indented lines under an
        //     unindented one.
        let indented = content.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        if indented >= 2, indented < content.count { signals += 1 }

        // e) a call shape: `name(args)` on its own line.
        if content.contains(where: looksLikeCall) { signals += 1 }

        guard signals >= (lowerBar ? 1 : 2) else { return nil }
        return .code(language: guessLanguage(content))
    }

    /// A statement that opens with a SQL verb and carries a clause keyword.
    /// Case-insensitive on the verb, because half the world writes it lower.
    static func isSQL(_ content: [String]) -> Bool {
        guard let first = content.first?.trimmingCharacters(in: .whitespaces).uppercased() else { return false }
        let verbs = ["SELECT ", "INSERT INTO ", "UPDATE ", "DELETE FROM ", "CREATE TABLE ",
                     "ALTER TABLE ", "DROP TABLE ", "WITH "]
        guard verbs.contains(where: { first.hasPrefix($0) }) else { return false }
        let whole = content.joined(separator: " ").uppercased()
        let clauses = [" FROM ", " WHERE ", " VALUES ", " SET ", " JOIN ", " GROUP BY ", " ORDER BY "]
        return clauses.contains { whole.contains($0) }
    }

    private static let keywords: [String: String] = [
        "func": "swift", "guard": "swift", "@State": "swift", "struct": "swift",
        "extension": "swift", "protocol": "swift",
        "def": "python", "elif": "python", "class": "python", "async def": "python",
        "const": "javascript", "function": "javascript", "export": "javascript",
        "require(": "javascript", "console.log": "javascript",
        "fn": "rust", "impl": "rust", "pub fn": "rust",
        "package": "go", "SELECT": "sql", "select": "sql",
        "#include": "c", "#import": "c", "public": "java",
        "let": "", "var": "", "if": "", "for": "", "while": "", "return": "",
        "switch": "", "case": "", "import": "", "from": "", "try": "", "catch": "",
        "enum": "", "private": "", "static": "", "type": "", "interface": "",
        "module": "", "using": "", "namespace": "", "with": "",
    ]

    static func startsWithKeyword(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let head = trimmed.split(separator: " ").first.map(String.init) else { return false }
        if keywords[head] != nil { return true }
        return trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import")
    }

    /// `something(...)` or `something(...);` alone on a line.
    static func looksLikeCall(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.contains(")") else { return false }
        let name = trimmed[trimmed.startIndex ..< open]
        guard !name.isEmpty, name.count <= 60 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }
            && name.contains(where: \.isLetter)
    }

    /// Best-effort language tag; `nil` opens a bare fence.
    static func guessLanguage(_ content: [String]) -> String? {
        var votes: [String: Int] = [:]
        for line in content {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import") { votes["c", default: 0] += 2 }
            if trimmed.hasPrefix("func ") || trimmed.hasPrefix("guard ") { votes["swift", default: 0] += 2 }
            if trimmed.contains("-> some View") || trimmed.hasPrefix("@State") { votes["swift", default: 0] += 3 }
            if trimmed.hasPrefix("def ") || trimmed.hasPrefix("elif ") || trimmed.hasSuffix("):") {
                votes["python", default: 0] += 2
            }
            if trimmed.hasPrefix("import ") && trimmed.hasSuffix(" as np") { votes["python", default: 0] += 2 }
            if trimmed.hasPrefix("const ") || trimmed.hasPrefix("let ") && trimmed.hasSuffix(";") {
                votes["javascript", default: 0] += 2
            }
            if trimmed.contains("=>") || trimmed.contains("console.log") { votes["javascript", default: 0] += 2 }
            if trimmed.hasPrefix("fn ") || trimmed.contains("let mut ") { votes["rust", default: 0] += 3 }
            if trimmed.hasPrefix("package ") || trimmed.contains(":= ") { votes["go", default: 0] += 2 }
            let upper = trimmed.uppercased()
            if upper.hasPrefix("SELECT ") || upper.hasPrefix("INSERT INTO ") || upper.hasPrefix("UPDATE ") {
                votes["sql", default: 0] += 3
            }
        }
        return votes.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }
}
