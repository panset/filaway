import Foundation
import Testing

@testable import FilawayCore

@Suite("Front-matter codec (DS-2)")
struct FrontMatterTests {
    // MARK: - Round trips

    @Test("A file with no front-matter is body-only and round-trips byte-for-byte")
    func noFrontMatter() {
        let text = "# Heading\n\nSome body with --- inside it.\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.frontMatter == nil)
        #expect(document.body == text)
        #expect(document.serialized() == text)
    }

    @Test("Unknown keys survive a parse/serialize round trip byte-for-byte")
    func foreignKeysRoundTrip() {
        let text = """
        ---
        # a comment nobody should touch
        title: "Not our title"
        aliases:
          - one
          - two
        obsidian: {nested: true}
        cssclass:   spaced-out
        ---
        Body stays clean.
        """
        let document = MarkdownDocument.parse(text)
        #expect(document.serialized() == text)
        #expect(document.frontMatter?.keys == ["title", "aliases", "obsidian", "cssclass"])
        #expect(document.body == "Body stays clean.")
    }

    @Test("Setting a known key leaves every unknown key's bytes alone")
    func mutationPreservesUnknownKeys() {
        let text = """
        ---
        title: "Not our title"
        aliases:
          - one
        ---
        Body.
        """
        var document = MarkdownDocument.parse(text)
        let id = NoteID()
        document.frontMatter?.id = id
        let output = document.serialized()
        #expect(output.contains("title: \"Not our title\""))
        #expect(output.contains("aliases:\n  - one"))
        #expect(output.contains("id: \(id.uuidString)"))
        #expect(MarkdownDocument.parse(output).frontMatter?.id == id)
        #expect(MarkdownDocument.parse(output).body == "Body.")
    }

    @Test("Setting a known key to its current value does not change a single byte")
    func idempotentSet() {
        let id = NoteID()
        let text = "---\nid:   \(id.uuidString)\ntags: [a, b]\n---\nBody\n"
        var document = MarkdownDocument.parse(text)
        document.frontMatter?.id = id
        document.frontMatter?.tags = ["a", "b"]
        #expect(document.serialized() == text)
    }

    @Test("CRLF line endings survive")
    func crlf() {
        let text = "---\r\nid: \(NoteID().uuidString)\r\ntags:\r\n  - shell\r\n---\r\n# Title\r\n\r\nBody\r\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.frontMatter?.lineEnding == "\r\n")
        #expect(document.frontMatter?.tags == ["shell"])
        #expect(document.body == "# Title\r\n\r\nBody\r\n")
        #expect(document.serialized() == text)
    }

    @Test("A UTF-8 BOM survives")
    func byteOrderMark() {
        let text = "\u{FEFF}---\ntags: [x]\n---\nBody\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.hasByteOrderMark)
        #expect(document.frontMatter?.tags == ["x"])
        #expect(document.serialized() == text)
    }

    @Test("A BOM with no front-matter still round-trips")
    func byteOrderMarkNoFrontMatter() {
        let text = "\u{FEFF}Just a body.\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.hasByteOrderMark)
        #expect(document.frontMatter == nil)
        #expect(document.serialized() == text)
    }

    @Test("An unterminated block is body, not front-matter")
    func unterminatedBlockIsBody() {
        let text = "---\nid: nope\nstill going\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.frontMatter == nil)
        #expect(document.serialized() == text)
    }

    @Test("A `...` terminator is accepted and preserved")
    func dotTerminator() {
        let text = "---\ntags: [a]\n...\nBody\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.frontMatter?.closeDelimiter == "...")
        #expect(document.serialized() == text)
    }

    @Test("A file that ends on the closing delimiter round-trips")
    func noTrailingNewline() {
        let text = "---\ntags: [a]\n---"
        let document = MarkdownDocument.parse(text)
        #expect(document.body.isEmpty)
        #expect(document.serialized() == text)
    }

    @Test("An empty block round-trips")
    func emptyBlock() {
        let text = "---\n---\nBody\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.frontMatter?.isEmpty == true)
        #expect(document.serialized() == text)
    }

    @Test("A horizontal rule in the body is not mistaken for front-matter")
    func horizontalRuleInBody() {
        let text = "Intro\n\n---\n\nMore\n"
        let document = MarkdownDocument.parse(text)
        #expect(document.frontMatter == nil)
        #expect(document.serialized() == text)
    }

    // MARK: - Values

    @Test("Block, flow and bare tag sequences all parse")
    func tagForms() {
        #expect(MarkdownDocument.parse("---\ntags:\n  - shell\n  - curl\n---\n").frontMatter?.tags == ["shell", "curl"])
        #expect(MarkdownDocument.parse("---\ntags: [shell, curl]\n---\n").frontMatter?.tags == ["shell", "curl"])
        #expect(MarkdownDocument.parse("---\ntags: shell, curl\n---\n").frontMatter?.tags == ["shell", "curl"])
        #expect(MarkdownDocument.parse("---\ntags: []\n---\n").frontMatter?.tags == [])
        #expect(MarkdownDocument.parse("---\ntags:\n---\n").frontMatter?.tags == [])
        #expect(MarkdownDocument.parse("---\ntags:\n  - \"with space\"\n---\n").frontMatter?.tags == ["with space"])
    }

    @Test("Writing tags produces a block sequence that reparses")
    func writeTags() {
        var frontMatter = FrontMatter()
        frontMatter.tags = ["shell", "two words"]
        let serialized = frontMatter.serialized()
        #expect(serialized.contains("tags:\n  - shell\n  - two words"))
        #expect(MarkdownDocument.parse(serialized + "body").frontMatter?.tags == ["shell", "two words"])

        frontMatter.tags = []
        #expect(frontMatter.serialized().contains("tags: []"))
    }

    @Test("Quoted and unquoted ids both parse")
    func idForms() {
        let id = NoteID()
        #expect(MarkdownDocument.parse("---\nid: \(id.uuidString)\n---\n").frontMatter?.id == id)
        #expect(MarkdownDocument.parse("---\nid: \"\(id.uuidString)\"\n---\n").frontMatter?.id == id)
        #expect(MarkdownDocument.parse("---\nid: '\(id.uuidString)'\n---\n").frontMatter?.id == id)
        #expect(MarkdownDocument.parse("---\nid: not-a-uuid\n---\n").frontMatter?.id == nil)
    }

    @Test("New known keys are inserted in canonical order after any leading comment")
    func canonicalOrder() {
        var frontMatter = MarkdownDocument.parse("---\n# lead comment\nzed: 1\n---\n").frontMatter!
        frontMatter.tags = ["t"]
        frontMatter.created = Date(timeIntervalSince1970: 0)
        frontMatter.id = NoteID()
        #expect(frontMatter.keys == ["id", "created", "tags", "zed"])
        #expect(frontMatter.serialized().hasPrefix("---\n# lead comment\nid: "))
    }

    @Test("Removing a known key drops its line")
    func removeKey() {
        var frontMatter = MarkdownDocument.parse("---\nid: \(NoteID().uuidString)\nkeep: yes\n---\n").frontMatter!
        frontMatter.id = nil
        #expect(frontMatter.keys == ["keep"])
    }

    // MARK: - ISO-8601

    @Test("ISO-8601 dates round-trip and tolerate the formats other tools emit")
    func isoDates() {
        let date = Date(timeIntervalSince1970: 1_755_897_600)
        let text = ISO8601.string(from: date)
        #expect(text == "2025-08-22T21:20:00Z")
        #expect(ISO8601.date(from: text) == date)
        #expect(ISO8601.date(from: "2025-08-22T21:20:00.123Z") == date)
        #expect(ISO8601.date(from: "2025-08-22 21:20:00Z") == date)
        #expect(ISO8601.date(from: "2025-08-22T23:20:00+02:00") == date)
        #expect(ISO8601.date(from: "2025-08-22T23:20:00+0200") == date)
        #expect(ISO8601.date(from: "2025-08-22") == Date(timeIntervalSince1970: 1_755_820_800))
        #expect(ISO8601.date(from: "not a date") == nil)
        #expect(ISO8601.date(from: "2025-13-01") == nil)
    }

    @Test("ISO-8601 formatting matches Foundation across a wide date range")
    func isoMatchesFoundation() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for offset in stride(from: -2_000_000_000.0, through: 2_000_000_000.0, by: 37_000_000.0) {
            let date = Date(timeIntervalSince1970: offset)
            #expect(ISO8601.string(from: date) == formatter.string(from: date))
            #expect(ISO8601.date(from: formatter.string(from: date)) == date)
        }
    }

    @Test("Conflict stamps use the local time zone in yyyy-MM-dd HHmm form")
    func conflictStamp() {
        let date = Date(timeIntervalSince1970: 1_755_897_600)
        #expect(ISO8601.conflictStamp(from: date, timeZone: TimeZone(secondsFromGMT: 0)!) == "2025-08-22 2120")
        #expect(ISO8601.conflictStamp(from: date, timeZone: TimeZone(secondsFromGMT: 3600)!) == "2025-08-22 2220")
    }

    // MARK: - Fuzz

    @Test("Parsing never loses bytes, whatever the input")
    func fuzzRoundTrip() {
        let fragments = [
            "---", "...", "  ", "", "id: x", "tags:", "  - a", "# c", "\r", "body",
            "\u{FEFF}", "key: value", "-", "a: b: c", "   indented",
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 400 {
            let count = Int.random(in: 0 ... 8, using: &generator)
            var text = ""
            for _ in 0 ..< count {
                text += fragments.randomElement(using: &generator)!
                text += Bool.random(using: &generator) ? "\n" : "\r\n"
            }
            #expect(MarkdownDocument.parse(text).serialized() == text, "lost bytes for \(text.debugDescription)")
        }
    }
}
