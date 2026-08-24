import Foundation
import Testing

@testable import FilawayCore

/// The line diff behind the Activity window's before/after view (FR-4.3) and
/// behind Undo's reverse patch (FR-4.4).
@Suite("Text diff")
struct ActivityDiffTests {
    @Test("splitting and joining round-trips every input")
    func splitJoinRoundTrip() {
        for text in [
            "", "\n", "a", "a\n", "a\nb", "a\nb\n", "a\r\nb\r\n", "\n\n\n",
            "# Heading\n\n```\ncode\n```\n", "no trailing newline",
        ] {
            #expect(TextDiff.join(TextDiff.lines(of: text)) == text, "round trip of \(text.debugDescription)")
        }
    }

    @Test("identical texts diff to nothing")
    func identical() {
        #expect(TextDiff.between("a\nb\n", "a\nb\n").isEmpty)
        #expect(TextDiff.between("", "").isEmpty)
    }

    @Test("an append is one hunk of insertions with the tail as context")
    func appendDiff() {
        let diff = TextDiff.between("one\ntwo\n", "one\ntwo\n\n---\n\nthree\n")
        #expect(diff.hunks.count == 1)
        #expect(diff.insertedLineCount == 4)
        #expect(diff.deletedLineCount == 0)
        #expect(diff.hunks[0].insertedLines == ["---", "", "three", ""])
    }

    @Test("a deletion in the middle is located at the right line")
    func deletionDiff() {
        let diff = TextDiff.between("a\nb\nc\nd\ne\nf\ng\nh\n", "a\nb\nc\ne\nf\ng\nh\n")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].deletedLines == ["d"])
        #expect(diff.hunks[0].beforeStart == 0)
        #expect(diff.hunks[0].beforeCount == 7)
    }

    @Test("two distant changes are two hunks")
    func twoHunks() {
        let before = (1 ... 40).map { "line \($0)" }.joined(separator: "\n")
        var lines = before.components(separatedBy: "\n")
        lines[2] = "changed early"
        lines[35] = "changed late"
        let diff = TextDiff.between(before, lines.joined(separator: "\n"))
        #expect(diff.hunks.count == 2)
        #expect(diff.insertedLineCount == 2)
        #expect(diff.deletedLineCount == 2)
    }

    @Test("unified output carries the hunk headers and markers")
    func unifiedOutput() {
        let diff = TextDiff.between("a\nb\nc\n", "a\nB\nc\n")
        let text = diff.unified(before: "Notes.md", after: "Notes.md")
        #expect(text.hasPrefix("--- Notes.md\n+++ Notes.md\n@@ "))
        #expect(text.contains("\n-b\n"))
        #expect(text.contains("\n+B\n"))
        #expect(text.contains("\n a\n"))
    }

    @Test("reversing a diff and replaying it restores the original")
    func reversedRoundTrip() {
        let before = "# Auth\n\nnotes\n"
        let after = "# Auth\n\nnotes\n\n---\n\n## Token\n\nTOKEN=abc\n"
        let restored = TextDiff.between(before, after).reversed.apply(to: after)
        #expect(restored.isComplete)
        #expect(restored.text == before)
    }

    @Test("a patch still lands when the text has moved on elsewhere")
    func patchTolerantOfUnrelatedEdits() {
        let before = "intro\n\nbody\n"
        let after = "intro\n\nbody\n\n---\n\nappended\n"
        // The user edited the top of the note after the apply.
        let edited = "intro rewritten by the user\n\nbody\n\n---\n\nappended\n"
        let result = TextDiff.between(before, after).reversed.apply(to: edited)
        #expect(result.isComplete)
        #expect(result.text == "intro rewritten by the user\n\nbody\n")
    }

    @Test("a hunk whose lines are gone is reported, never forced")
    func patchReportsFailure() {
        let before = "a\nb\nc\n"
        let after = "a\nb\nc\nd\n"
        let result = TextDiff.between(before, after).reversed.apply(to: "completely different\n")
        #expect(!result.isComplete)
        #expect(result.failedHunks.count == 1)
        #expect(result.text == "completely different\n")
    }

    @Test("failed hunks report the lines they were carrying")
    func failedHunkCarriesText() {
        // after → before restores "secret line"; the user has since rewritten
        // the whole region, so the hunk cannot land.
        let before = "keep\n\nsecret line\n"
        let after = "keep\n"
        let result = TextDiff.between(before, after).reversed.apply(to: "totally rewritten\n")
        #expect(!result.isComplete)
        #expect(result.unrecoveredLines.contains("secret line"))
    }

    @Test("a hunk is matched nearest to where it used to be")
    func nearestMatchWins() {
        let haystack = ["x", "a", "b", "x", "a", "b"]
        #expect(TextDiff.locate(["a", "b"], in: haystack, near: 4) == 4)
        #expect(TextDiff.locate(["a", "b"], in: haystack, near: 0) == 1)
        #expect(TextDiff.locate(["q"], in: haystack, near: 0) == nil)
    }

    @Test("diffing a created and a trashed note reads as all-insert and all-delete")
    func createdAndTrashed() {
        #expect(TextDiff.between("", "new\n").deletedLineCount == 0)
        #expect(TextDiff.between("gone\n", "").insertedLineCount == 0)
    }
}
