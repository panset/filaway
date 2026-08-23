import Foundation
import Testing

@testable import FilawayCore

/// FR-2.4 — "pasting content that looks like a shell command or code offers to
/// wrap it in a code block".
///
/// The suite is written as a corpus rather than as a set of unit tests: what
/// matters is the *ratio* of the two mistakes. A false positive interrupts
/// someone pasting a sentence; a false negative costs three keystrokes. So the
/// negatives below are the ones that would actually be pasted into a notes app —
/// URLs, meeting notes, a Markdown list, a shell word used in a sentence.
@Suite("Paste intelligence — shell")
struct ShellPasteClassificationTests {

    @Test("a prompt marker is decisive")
    func promptMarker() {
        #expect(CodeLikePasteClassifier.classify("$ git status") == .shellCommand(language: "bash"))
        #expect(CodeLikePasteClassifier.classify("% brew upgrade") == .shellCommand(language: "bash"))
        #expect(CodeLikePasteClassifier.classify("  $ ls -la /tmp") == .shellCommand(language: "bash"))
    }

    @Test("a prompt marker survives a transcript with output")
    func promptTranscript() {
        let text = """
        $ git status
        On branch main
        nothing to commit, working tree clean
        """
        #expect(CodeLikePasteClassifier.classify(text) == .shellCommand(language: "bash"))
    }

    @Test("the Figure 1 curl line")
    func curlWithHeader() {
        let text = #"curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs"#
        #expect(CodeLikePasteClassifier.classify(text) == .shellCommand(language: "bash"))
    }

    @Test("known command heads with real arguments", arguments: [
        "git commit -m \"fix the retry window\"",
        "docker run --rm -it alpine sh",
        "kubectl get pods -n staging",
        "ssh deploy@st.app -p 2222",
        "brew install ripgrep",
        "npm run build -- --watch",
        "pip install -r requirements.txt",
        "make test",
        "grep -rn TODO Sources/",
        "sed -i '' 's/foo/bar/g' file.txt",
        "awk '{print $2}' access.log",
        "cd ~/projects/filaway",
        "export ANTHROPIC_API_KEY=sk-ant-123",
        "tar -czf backup.tgz Notes/",
        "./Tools/smoke.sh --keep",
        "xcrun notarytool submit build/Filaway.dmg --wait",
    ])
    func commandHeads(_ line: String) {
        #expect(CodeLikePasteClassifier.classify(line) == .shellCommand(language: "bash"),
                "should be shell: \(line)")
    }

    @Test("pipes and redirects across several lines")
    func pipeline() {
        let text = """
        cat access.log | grep 401 | wc -l
        tail -f server.log > errors.txt
        """
        #expect(CodeLikePasteClassifier.classify(text) == .shellCommand(language: "bash"))
    }

    @Test("a wrapped command with continuation lines")
    func continuations() {
        let text = """
        curl -sS https://api.st.app/v2/docs \\
          -H "Auth: Bearer $TOK" \\
          -H "Accept: application/json"
        """
        #expect(CodeLikePasteClassifier.classify(text) == .shellCommand(language: "bash"))
    }

    @Test("sudo and environment prefixes do not hide the command")
    func prefixes() {
        #expect(CodeLikePasteClassifier.classify("sudo launchctl unload -w /Library/LaunchDaemons/x.plist")
            == .shellCommand(language: "bash"))
        #expect(CodeLikePasteClassifier.classify("FILAWAY_SMOKE=1 build/Filaway.app/Contents/MacOS/Filaway")
            == .shellCommand(language: "bash"))
    }
}

@Suite("Paste intelligence — code and data")
struct CodePasteClassificationTests {

    @Test("JSON is decided by the parser, not by shape")
    func json() {
        let text = """
        {
          "model": "claude-sonnet-5",
          "max_tokens": 1024
        }
        """
        #expect(CodeLikePasteClassifier.classify(text) == .code(language: "json"))
    }

    @Test("a JSON array")
    func jsonArray() {
        #expect(CodeLikePasteClassifier.classify(#"[{"id": 1}, {"id": 2}]"#) == .code(language: "json"))
    }

    @Test("YAML mappings")
    func yaml() {
        let text = """
        name: ci
        on:
          push:
            branches: [main]
        """
        #expect(CodeLikePasteClassifier.classify(text) == .code(language: "yaml"))
    }

    @Test("Swift")
    func swiftSource() {
        let text = """
        func classify(_ text: String) -> PasteKind {
            guard !text.isEmpty else { return .plain }
            return .code(language: "swift")
        }
        """
        #expect(CodeLikePasteClassifier.classify(text) == .code(language: "swift"))
    }

    @Test("Python")
    func pythonSource() {
        let text = """
        def rotate(token):
            if token.expired:
                return refresh(token)
            return token
        """
        #expect(CodeLikePasteClassifier.classify(text) == .code(language: "python"))
    }

    @Test("JavaScript")
    func javaScriptSource() {
        let text = """
        const total = items.reduce((sum, item) => sum + item.price, 0);
        console.log(total);
        """
        #expect(CodeLikePasteClassifier.classify(text) == .code(language: "javascript"))
    }

    @Test("SQL")
    func sqlSource() {
        let text = """
        SELECT id, title FROM notes
        WHERE modified > date('now', '-2 days')
        ORDER BY modified DESC;
        """
        #expect(CodeLikePasteClassifier.classify(text).fenceLanguage == "sql")
    }

    @Test("a single line the pasteboard itself called source code")
    func declaredSourceCode() {
        let kind = CodeLikePasteClassifier.classify(
            "let hits = try await search.keyword(query, limit: 20)",
            pasteboardTypes: ["public.source-code", "public.utf8-plain-text"]
        )
        #expect(kind.isCodeLike)
    }
}

@Suite("Paste intelligence — negatives")
struct PlainPasteClassificationTests {

    @Test("ordinary prose is never wrapped", arguments: [
        "The 401 only happens after the bearer token rotates.",
        "Remember to ask Priya about the staging credentials before Friday.",
        "I think we should move the retry window to thirty seconds and see what happens.",
        "Notes from the staging spike.",
        "token expires hourly",
    ])
    func prose(_ text: String) {
        #expect(CodeLikePasteClassifier.classify(text) == .plain, "should be plain: \(text)")
    }

    @Test("a URL on its own is not a command")
    func url() {
        #expect(CodeLikePasteClassifier.classify("https://api.st.app/v2/docs") == .plain)
        #expect(CodeLikePasteClassifier.classify("See https://api.st.app/v2/docs for the schema.") == .plain)
    }

    @Test("a command word used in a sentence")
    func commandWordInProse() {
        #expect(CodeLikePasteClassifier.classify("cd to the office and ask about the token") == .plain)
        #expect(CodeLikePasteClassifier.classify("open the ticket about the rate limit") == .plain)
        #expect(CodeLikePasteClassifier.classify("date of the next review") == .plain)
    }

    @Test("a bare word or a short phrase")
    func bareWords() {
        #expect(CodeLikePasteClassifier.classify("git") == .plain)
        #expect(CodeLikePasteClassifier.classify("curl") == .plain)
        #expect(CodeLikePasteClassifier.classify("") == .plain)
        #expect(CodeLikePasteClassifier.classify("   \n  ") == .plain)
    }

    @Test("a Markdown list is not YAML")
    func markdownList() {
        let text = """
        - rotate the staging token
        - check the refresh window
        - ask about the rate limit
        """
        #expect(CodeLikePasteClassifier.classify(text) == .plain)
    }

    @Test("a Markdown heading and paragraph")
    func markdownProse() {
        let text = """
        ## Auth API debug

        The refresh window is shorter than the docs claim, so the client has to
        retry once before it gives up.
        """
        #expect(CodeLikePasteClassifier.classify(text) == .plain)
    }

    @Test("already-fenced text is left alone")
    func alreadyFenced() {
        let text = """
        ```bash
        curl -sS https://api.st.app/v2/docs
        ```
        """
        #expect(CodeLikePasteClassifier.classify(text) == .plain)
    }

    @Test("a file promise is never a command")
    func fileURLPasteboard() {
        let kind = CodeLikePasteClassifier.classify(
            "curl -sS https://api.st.app/v2/docs",
            pasteboardTypes: ["public.file-url"]
        )
        #expect(kind == .plain)
    }

    @Test("a note with a colon is not YAML")
    func colonProse() {
        let text = """
        Question: does the token refresh on its own?
        Answer: only when the client asks for it.
        """
        #expect(CodeLikePasteClassifier.classify(text) == .plain)
    }

    @Test("a shopping list of prices")
    func prices() {
        #expect(CodeLikePasteClassifier.classify("$ 12 for lunch\n$ 4 for coffee") == .plain)
    }

    @Test("an enormous paste is left alone")
    func enormous() {
        let text = String(repeating: "git status\n", count: 40_000)
        #expect(text.utf16.count > CodeLikePasteClassifier.maxLength)
        #expect(CodeLikePasteClassifier.classify(text) == .plain)
    }
}

@Suite("Paste intelligence — PasteKind")
struct PasteKindTests {

    @Test("fence language")
    func fenceLanguage() {
        #expect(PasteKind.plain.fenceLanguage == nil)
        #expect(PasteKind.shellCommand(language: "bash").fenceLanguage == "bash")
        #expect(PasteKind.code(language: "json").fenceLanguage == "json")
        #expect(PasteKind.code(language: nil).fenceLanguage == nil)
        #expect(!PasteKind.plain.isCodeLike)
        #expect(PasteKind.code(language: nil).isCodeLike)
    }
}

/// The bytes `Wrap` writes. These live in Core precisely so they are covered by
/// `swift test` — the editor half needs a live `NSTextView` and can only be
/// checked by the `paste` smoke phase.
@Suite("Paste intelligence — the fenced block Wrap writes")
struct CodeFenceTests {

    @Test("a one-line command, mid-paragraph")
    func midParagraph() {
        let wrapped = CodeFence.wrap(
            "git status", language: "bash",
            needsLeadingNewline: true, needsTrailingNewline: true
        )
        #expect(wrapped == "\n```bash\ngit status\n```\n")
    }

    @Test("a command already on its own line needs no padding")
    func ownLine() {
        #expect(CodeFence.wrap("git status", language: "bash") == "```bash\ngit status\n```")
    }

    @Test("a body that already ends in a newline is not doubled")
    func trailingNewline() {
        #expect(CodeFence.wrap("git status\n", language: "bash") == "```bash\ngit status\n```")
    }

    @Test("no language means a bare fence")
    func bareFence() {
        #expect(CodeFence.wrap("x = 1", language: nil) == "```\nx = 1\n```")
        #expect(CodeFence.wrap("x = 1", language: "  ") == "```\nx = 1\n```")
    }

    @Test("a multi-line block keeps every line")
    func multiline() {
        let body = "curl -sS https://api.st.app \\\n  -H \"Auth: Bearer $TOK\""
        let wrapped = CodeFence.wrap(body, language: "bash")
        #expect(wrapped.hasPrefix("```bash\n"))
        #expect(wrapped.hasSuffix("\n```"))
        #expect(wrapped.contains(body))
    }

    @Test("the wrapped result classifies as plain — wrapping twice is impossible")
    func wrappingIsIdempotent() {
        let wrapped = CodeFence.wrap("git status", language: "bash")
        #expect(CodeLikePasteClassifier.classify(wrapped) == .plain)
    }
}
