import Foundation

/// The text surgery an apply performs, as pure functions.
///
/// All of FR-4.4's "never deletes user content" lives here in miniature: the
/// only two edits Filaway makes to an existing note are *append under a
/// divider* and *remove a segment that is travelling to another note*, and both
/// are deterministic enough to unit-test without a filesystem.
public enum ApplyText {
    /// The rule above an appended block.
    public static let divider = "---"

    /// FR-4.4: "content appended with a divider/heading", never interleaved.
    ///
    /// * A blank target gets the block with no leading rule — a divider at the
    ///   top of an empty note is noise.
    /// * Trailing whitespace is normalised so repeated appends stack evenly.
    public static func appending(
        _ content: String,
        to body: String,
        heading: String? = nil,
        divider useDivider: Bool? = nil
    ) -> String {
        let trimmedBody = body.trimmingTrailingWhitespaceAndNewlines
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var block = ""
        if trimmedBody.isEmpty {
            // No rule above the first thing in a note.
        } else if useDivider ?? true {
            block += "\(divider)\n\n"
        }
        if let heading = heading?.trimmingCharacters(in: .whitespacesAndNewlines), !heading.isEmpty {
            block += heading.hasPrefix("#") ? "\(heading)\n\n" : "## \(heading)\n\n"
        }
        block += trimmedContent
        if trimmedBody.isEmpty { return block.isEmpty ? "" : block + "\n" }
        return trimmedBody + "\n\n" + block + "\n"
    }

    /// Removes the first verbatim occurrence of `segment`, tidying the seam.
    ///
    /// Returns `nil` when the segment is not in `body` byte-for-byte — which is
    /// a compare-and-swap miss, not a licence to guess (ADR-016).
    public static func removingSegment(_ segment: String, from body: String) -> String? {
        guard !segment.isEmpty, let range = body.range(of: segment) else { return nil }
        let head = String(body[body.startIndex ..< range.lowerBound]).trimmingTrailingWhitespaceAndNewlines
        let tail = String(body[range.upperBound...]).trimmingLeadingBlanks
        if head.isEmpty, tail.isEmpty { return "" }
        if head.isEmpty { return tail }
        if tail.isEmpty { return head + "\n" }
        return head + "\n\n" + tail
    }

    /// Whitespace-only counts as empty: that is what sends a `moveSegment`
    /// source to the Trash (plan §1 amendment 1).
    public static func isEffectivelyEmpty(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// FR-4.1 tags are **additive** — merging never drops one the user has.
    /// Case-insensitive de-duplication, first spelling wins.
    public static func mergedTags(_ existing: [String], adding: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in existing + adding {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// The heading Undo writes above text it could not patch back into place.
    public static let undoConflictHeading = "Restored by Undo (conflict)"

    /// Appends recovered text under an unmistakable marker (FR-4.4: a failed
    /// reverse patch must never silently drop what it was carrying).
    public static func appendingConflictBlock(_ recovered: String, to text: String) -> String {
        appending(recovered, to: text, heading: undoConflictHeading, divider: true)
    }
}

extension String {
    var trimmingTrailingWhitespaceAndNewlines: String {
        var out = self
        while let last = out.last, last.isWhitespace || last.isNewline { out.removeLast() }
        return out
    }

    /// Newlines, spaces and tabs at the very start — the seam left behind when
    /// a segment is lifted out of the middle of a note.
    var trimmingLeadingBlanks: String {
        var out = self
        while let first = out.first, first.isNewline || first == " " || first == "\t" { out.removeFirst() }
        return out
    }
}
