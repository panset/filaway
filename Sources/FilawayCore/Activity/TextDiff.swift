import Foundation

/// One line of a diff.
public struct DiffLine: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case context
        case insert
        case delete

        /// The unified-diff marker.
        public var marker: Character {
            switch self {
            case .context: " "
            case .insert: "+"
            case .delete: "-"
            }
        }
    }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A contiguous run of changed lines with its surrounding context — the unit
/// Undo's reverse patch applies (FR-4.3: "undo after the user has edited the
/// note" must not overwrite the edit).
public struct DiffHunk: Sendable, Hashable, Codable {
    /// 0-based line index into the *before* text.
    public var beforeStart: Int
    public var beforeCount: Int
    /// 0-based line index into the *after* text.
    public var afterStart: Int
    public var afterCount: Int
    public var lines: [DiffLine]

    public init(beforeStart: Int, beforeCount: Int, afterStart: Int, afterCount: Int, lines: [DiffLine]) {
        self.beforeStart = beforeStart
        self.beforeCount = beforeCount
        self.afterStart = afterStart
        self.afterCount = afterCount
        self.lines = lines
    }

    /// The lines this hunk expects to find: context plus deletions.
    public var beforeLines: [String] {
        lines.filter { $0.kind != .insert }.map(\.text)
    }

    /// The lines this hunk leaves behind: context plus insertions.
    public var afterLines: [String] {
        lines.filter { $0.kind != .delete }.map(\.text)
    }

    /// Only the added lines — what a *failed* hunk could not put back, and so
    /// what Undo appends under its conflict marker rather than dropping.
    public var insertedLines: [String] {
        lines.filter { $0.kind == .insert }.map(\.text)
    }

    public var deletedLines: [String] {
        lines.filter { $0.kind == .delete }.map(\.text)
    }

    /// `@@ -a,b +c,d @@`, 1-based as `diff(1)` writes it.
    public var header: String {
        "@@ -\(range(beforeStart, beforeCount)) +\(range(afterStart, afterCount)) @@"
    }

    private func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start + 1)" : "\(count == 0 ? start : start + 1),\(count)"
    }

    /// The hunk reversed: insertions become deletions and vice versa.
    public var reversed: DiffHunk {
        DiffHunk(
            beforeStart: afterStart,
            beforeCount: afterCount,
            afterStart: beforeStart,
            afterCount: beforeCount,
            lines: lines.map { line in
                switch line.kind {
                case .context: line
                case .insert: DiffLine(.delete, line.text)
                case .delete: DiffLine(.insert, line.text)
                }
            }
        )
    }
}

/// What ``TextDiff/apply(to:)`` managed.
public struct PatchResult: Sendable, Hashable {
    public var text: String
    public var appliedHunks: [DiffHunk]
    public var failedHunks: [DiffHunk]

    public init(text: String, appliedHunks: [DiffHunk] = [], failedHunks: [DiffHunk] = []) {
        self.text = text
        self.appliedHunks = appliedHunks
        self.failedHunks = failedHunks
    }

    /// Every hunk landed — the patched text is exactly what the diff described.
    public var isComplete: Bool { failedHunks.isEmpty }

    /// The added lines of every hunk that did not land.
    public var unrecoveredLines: [String] { failedHunks.flatMap(\.insertedLines) }
}

/// A line diff between two texts, and the patcher that replays it.
///
/// Deliberately small and dependency-free: a longest-common-subsequence over
/// lines, with the common prefix and suffix trimmed first so the quadratic part
/// only ever sees the region that actually changed. Notes are at most a few
/// thousand lines, and a diff that is *understandable* matters more here than
/// one that is minimal — this is what the Activity window shows the user
/// (FR-4.3) and what Undo replays onto a note the user has edited since.
///
/// ```swift
/// let diff = TextDiff.between(before, after)
/// print(diff.unified(before: "Commands/curl.md", after: "Commands/curl.md"))
/// let restored = diff.reversed.apply(to: currentText)
/// ```
public struct TextDiff: Sendable, Hashable, Codable {
    public var hunks: [DiffHunk]
    /// Lines of context kept around each change.
    public var context: Int

    public init(hunks: [DiffHunk], context: Int = 3) {
        self.hunks = hunks
        self.context = context
    }

    public var isEmpty: Bool { hunks.isEmpty }

    public var insertedLineCount: Int { hunks.reduce(0) { $0 + $1.insertedLines.count } }
    public var deletedLineCount: Int { hunks.reduce(0) { $0 + $1.deletedLines.count } }

    /// The diff that turns `after` back into `before`.
    public var reversed: TextDiff {
        TextDiff(hunks: hunks.map(\.reversed), context: context)
    }

    // MARK: - Splitting

    /// Splits on `\n`, keeping the empty trailing element, so that
    /// `join(lines(of: text)) == text` for *every* input — including CRLF text
    /// (the `\r` rides along at the end of its line) and text with no final
    /// newline.
    public static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    public static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    // MARK: - Diffing

    /// Line diff between two texts.
    public static func between(_ before: String, _ after: String, context: Int = 3) -> TextDiff {
        diff(lines(of: before), lines(of: after), context: context)
    }

    /// Line diff between two arrays of lines.
    public static func diff(_ before: [String], _ after: [String], context: Int = 3) -> TextDiff {
        guard before != after else { return TextDiff(hunks: [], context: context) }

        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix,
              suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }

        let leftMiddle = Array(before[prefix ..< (before.count - suffix)])
        let rightMiddle = Array(after[prefix ..< (after.count - suffix)])
        let script = editScript(leftMiddle, rightMiddle)

        // Re-assemble the whole edit script: untouched prefix, the middle, then
        // the untouched suffix.
        var operations: [Operation] = []
        operations.reserveCapacity(script.count + prefix + suffix)
        for index in 0 ..< prefix { operations.append(.equal(before[index])) }
        operations.append(contentsOf: script)
        for index in (before.count - suffix) ..< before.count { operations.append(.equal(before[index])) }

        return TextDiff(hunks: hunks(from: operations, context: context), context: context)
    }

    private enum Operation: Sendable, Hashable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// Guard rail: beyond this many cells the LCS table is not worth building,
    /// and the middle is reported as one wholesale replacement instead. 4M
    /// cells is a 2,000 × 2,000-line change, far past anything a note holds.
    private static let maxTableCells = 4_000_000

    private static func editScript(_ before: [String], _ after: [String]) -> [Operation] {
        if before.isEmpty { return after.map(Operation.insert) }
        if after.isEmpty { return before.map(Operation.delete) }
        guard before.count * after.count <= maxTableCells else {
            return before.map(Operation.delete) + after.map(Operation.insert)
        }

        // Classic LCS table. Rows are `before`, columns are `after`.
        let rows = before.count + 1
        let columns = after.count + 1
        var table = [Int32](repeating: 0, count: rows * columns)
        for row in stride(from: before.count - 1, through: 0, by: -1) {
            let rowOffset = row * columns
            let nextOffset = (row + 1) * columns
            for column in stride(from: after.count - 1, through: 0, by: -1) {
                table[rowOffset + column] = before[row] == after[column]
                    ? table[nextOffset + column + 1] + 1
                    : max(table[nextOffset + column], table[rowOffset + column + 1])
            }
        }

        var operations: [Operation] = []
        var row = 0
        var column = 0
        while row < before.count, column < after.count {
            if before[row] == after[column] {
                operations.append(.equal(before[row]))
                row += 1
                column += 1
            } else if table[(row + 1) * columns + column] >= table[row * columns + column + 1] {
                operations.append(.delete(before[row]))
                row += 1
            } else {
                operations.append(.insert(after[column]))
                column += 1
            }
        }
        while row < before.count {
            operations.append(.delete(before[row]))
            row += 1
        }
        while column < after.count {
            operations.append(.insert(after[column]))
            column += 1
        }
        return operations
    }

    private static func hunks(from operations: [Operation], context: Int) -> [DiffHunk] {
        // Index every operation against its line numbers on both sides.
        var beforeIndex = 0
        var afterIndex = 0
        var positioned: [(operation: Operation, before: Int, after: Int)] = []
        positioned.reserveCapacity(operations.count)
        for operation in operations {
            positioned.append((operation, beforeIndex, afterIndex))
            switch operation {
            case .equal:
                beforeIndex += 1
                afterIndex += 1
            case .delete:
                beforeIndex += 1
            case .insert:
                afterIndex += 1
            }
        }

        let changed = positioned.indices.filter {
            if case .equal = positioned[$0].operation { return false }
            return true
        }
        guard !changed.isEmpty else { return [] }

        // Group changes that are within 2×context of each other into one hunk.
        var groups: [[Int]] = []
        var current: [Int] = [changed[0]]
        for index in changed.dropFirst() {
            if index - current[current.count - 1] <= context * 2 + 1 {
                current.append(index)
            } else {
                groups.append(current)
                current = [index]
            }
        }
        groups.append(current)

        return groups.map { group in
            let start = max(0, group[0] - context)
            let end = min(positioned.count - 1, group[group.count - 1] + context)
            var lines: [DiffLine] = []
            var beforeCount = 0
            var afterCount = 0
            for index in start ... end {
                switch positioned[index].operation {
                case let .equal(text):
                    lines.append(DiffLine(.context, text))
                    beforeCount += 1
                    afterCount += 1
                case let .delete(text):
                    lines.append(DiffLine(.delete, text))
                    beforeCount += 1
                case let .insert(text):
                    lines.append(DiffLine(.insert, text))
                    afterCount += 1
                }
            }
            return DiffHunk(
                beforeStart: positioned[start].before,
                beforeCount: beforeCount,
                afterStart: positioned[start].after,
                afterCount: afterCount,
                lines: lines
            )
        }
    }

    // MARK: - Rendering

    /// Unified diff text, `diff -u` style.
    public func unified(before: String = "before", after: String = "after") -> String {
        guard !hunks.isEmpty else { return "" }
        var out = "--- \(before)\n+++ \(after)\n"
        for hunk in hunks {
            out += hunk.header + "\n"
            for line in hunk.lines {
                out.append(line.kind.marker)
                out += line.text + "\n"
            }
        }
        return out
    }

    // MARK: - Patching

    /// Replays the diff onto `text`, which may have moved on since the diff was
    /// taken.
    ///
    /// Each hunk is located by matching its context and removed lines, nearest
    /// to where it used to be. A hunk whose lines are no longer there is
    /// reported in ``PatchResult/failedHunks`` — never forced, never dropped
    /// silently: Undo turns those into its conflict block (FR-4.4).
    public func apply(to text: String) -> PatchResult {
        var lines = Self.lines(of: text)
        var applied: [DiffHunk] = []
        var failed: [DiffHunk] = []
        var delta = 0

        for hunk in hunks {
            let expected = max(0, min(lines.count, hunk.beforeStart + delta))
            let needle = hunk.beforeLines
            guard let found = Self.locate(needle, in: lines, near: expected) else {
                failed.append(hunk)
                continue
            }
            let replacement = hunk.afterLines
            lines.replaceSubrange(found ..< (found + needle.count), with: replacement)
            delta += replacement.count - needle.count
            applied.append(hunk)
        }

        return PatchResult(text: Self.join(lines), appliedHunks: applied, failedHunks: failed)
    }

    /// Finds `needle` in `haystack`, preferring the occurrence nearest `near`.
    /// An empty needle means "pure insertion": it lands at `near`.
    static func locate(_ needle: [String], in haystack: [String], near: Int) -> Int? {
        guard !needle.isEmpty else { return min(near, haystack.count) }
        guard needle.count <= haystack.count else { return nil }
        var best: Int?
        for start in 0 ... (haystack.count - needle.count) {
            var matches = true
            for offset in 0 ..< needle.count where haystack[start + offset] != needle[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            if let current = best {
                if abs(start - near) < abs(current - near) { best = start }
            } else {
                best = start
            }
        }
        return best
    }
}
