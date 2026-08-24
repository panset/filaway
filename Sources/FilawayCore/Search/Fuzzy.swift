import Foundation

/// Byte-level matching over folded UTF-8.
///
/// Titles are matched as UTF-8 bytes rather than as `String`s. That is exact —
/// UTF-8 is self-synchronising, so a byte-range match of a valid UTF-8 needle
/// can only start on a character boundary — and it is roughly an order of
/// magnitude cheaper than Foundation's Unicode-aware comparisons, which matters
/// because *every* keystroke walks *every* title (NFR-1's 100 ms).
///
/// The primitives take raw pointers so the caller can keep all titles in one
/// flat buffer and run the scan without a single retain or bounds check.
enum ByteMatch {
    static func equal(_ haystack: UnsafePointer<UInt8>, _ count: Int, _ needle: UnsafePointer<UInt8>, _ needleCount: Int) -> Bool {
        count == needleCount && hasPrefix(haystack, count, needle, needleCount)
    }

    static func hasPrefix(_ haystack: UnsafePointer<UInt8>, _ count: Int, _ needle: UnsafePointer<UInt8>, _ needleCount: Int) -> Bool {
        guard needleCount <= count else { return false }
        for index in 0 ..< needleCount where haystack[index] != needle[index] { return false }
        return true
    }

    /// Offset of `needle` inside `haystack`, or `nil`. Naive scan: titles are
    /// tens of bytes, so anything cleverer would cost more than it saves.
    static func contains(_ haystack: UnsafePointer<UInt8>, _ count: Int, _ needle: UnsafePointer<UInt8>, _ needleCount: Int) -> Bool {
        guard needleCount > 0, needleCount <= count else { return false }
        let first = needle[0]
        var start = 0
        while start <= count - needleCount {
            if haystack[start] == first,
               hasPrefix(haystack + start, count - start, needle, needleCount) { return true }
            start += 1
        }
        return false
    }

    /// `true` when some word of `haystack` starts with `needle` (the caller has
    /// already ruled out the whole string starting with it).
    static func startsWord(_ haystack: UnsafePointer<UInt8>, _ count: Int, _ needle: UnsafePointer<UInt8>, _ needleCount: Int) -> Bool {
        guard needleCount > 0 else { return false }
        var index = 1
        while index < count {
            if !Fuzzy.isWordByte(haystack[index - 1]), Fuzzy.isWordByte(haystack[index]),
               hasPrefix(haystack + index, count - index, needle, needleCount) {
                return true
            }
            index += 1
        }
        return false
    }

    // Array conveniences, for tests and for callers that are not in a hot loop.

    static func equal(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.count == needle.count && hasPrefix(haystack, needle)
    }

    static func hasPrefix(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        with(haystack, needle, ifEmpty: needle.isEmpty, hasPrefix)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        with(haystack, needle, ifEmpty: false, contains)
    }

    static func startsWord(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        with(haystack, needle, ifEmpty: false, startsWord)
    }

    private static func with(
        _ haystack: [UInt8],
        _ needle: [UInt8],
        ifEmpty fallback: Bool,
        _ body: (UnsafePointer<UInt8>, Int, UnsafePointer<UInt8>, Int) -> Bool
    ) -> Bool {
        haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                guard let base = h.baseAddress, let needleBase = n.baseAddress else { return fallback }
                return body(base, h.count, needleBase, n.count)
            }
        }
    }
}

/// Typo tolerance for **titles only** (plan §1 amendment 6).
///
/// Bodies are matched literally: a substring or prefix hit inside 50 MB of
/// prose is fast and predictable, whereas edit-distance over every word would
/// be neither. Titles are short, few, and the thing people misremember, so they
/// get a Damerau-Levenshtein budget instead.
enum Fuzzy {
    /// How many edits a query of this length may be wrong by: nothing under
    /// four characters (where one edit reaches half the alphabet), one up to
    /// seven, two beyond.
    static func tolerance(forLength length: Int) -> Int {
        switch length {
        case ..<4: 0
        case 4 ... 7: 1
        default: 2
        }
    }

    /// A 64-bit set of the byte classes a string contains.
    ///
    /// The prefilter that makes fuzzy title search affordable: turning `a` into
    /// `b` in `d` edits can drop at most `d` distinct classes, so
    /// `popcount(signature(a) & ~signature(b)) > d` proves the distance exceeds
    /// `d` — in one instruction, for every title, before any matrix is touched.
    static func signature(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt64 {
        var mask: UInt64 = 0
        for index in 0 ..< count { mask |= 1 << UInt64(bytes[index] & 63) }
        return mask
    }

    static func signature(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return signature(base, buffer.count)
        }
    }

    /// Optimal string alignment distance (Damerau-Levenshtein restricted to
    /// adjacent transpositions), abandoning as soon as every cell of a row
    /// exceeds `maxDistance`.
    ///
    /// Returns `nil` when the strings are further apart than the budget.
    /// Allocation-free: the three rows it needs come from a temporary stack
    /// allocation.
    static func distance(
        _ lhs: UnsafePointer<UInt8>, _ rows: Int,
        _ rhs: UnsafePointer<UInt8>, _ columns: Int,
        maxDistance: Int
    ) -> Int? {
        if rows == 0 { return columns <= maxDistance ? columns : nil }
        if columns == 0 { return rows <= maxDistance ? rows : nil }
        guard abs(rows - columns) <= maxDistance else { return nil }

        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (columns + 1)) { scratch in
            var previous2 = scratch.baseAddress!
            var previous = previous2 + (columns + 1)
            var current = previous + (columns + 1)
            for column in 0 ... columns {
                previous2[column] = 0
                previous[column] = column
            }

            for row in 1 ... rows {
                current[0] = row
                var best = row
                let leftByte = lhs[row - 1]
                for column in 1 ... columns {
                    let cost = leftByte == rhs[column - 1] ? 0 : 1
                    var value = min(
                        current[column - 1] + 1,      // insertion
                        previous[column] + 1,         // deletion
                        previous[column - 1] + cost   // substitution
                    )
                    if row > 1, column > 1,
                       leftByte == rhs[column - 2],
                       lhs[row - 2] == rhs[column - 1] {
                        value = min(value, previous2[column - 2] + 1)  // transposition
                    }
                    current[column] = value
                    if value < best { best = value }
                }
                if best > maxDistance { return nil }
                swap(&previous2, &previous)
                swap(&previous, &current)
            }
            let result = previous[columns]
            return result <= maxDistance ? result : nil
        }
    }

    static func distance(_ lhs: [UInt8], _ rhs: [UInt8], maxDistance: Int) -> Int? {
        lhs.withUnsafeBufferPointer { l in
            rhs.withUnsafeBufferPointer { r in
                guard let left = l.baseAddress, let right = r.baseAddress else {
                    return max(l.count, r.count) <= maxDistance ? max(l.count, r.count) : nil
                }
                return distance(left, l.count, right, r.count, maxDistance: maxDistance)
            }
        }
    }

    /// Distance between two already-folded strings, compared as UTF-8 bytes.
    ///
    /// Bytes rather than characters: titles are overwhelmingly ASCII, and for
    /// the multi-byte ones a byte-level distance is still a sound "did they
    /// nearly type this" signal — it only ever over-counts.
    static func distance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int? {
        distance(Array(lhs.utf8), Array(rhs.utf8), maxDistance: maxDistance)
    }

    /// `true` for bytes that are part of a word in a folded title.
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)        // 0-9
            || (byte >= 0x41 && byte <= 0x5A) // A-Z
            || (byte >= 0x61 && byte <= 0x7A) // a-z
            || byte >= 0x80                   // any non-ASCII lead/continuation
    }

    /// The closest match between `needle` and any word of `haystack`.
    ///
    /// Lets "dcoker" find *Docker compose cheatsheet* — a whole-title distance
    /// would reject that on length alone.
    static func wordDistance(
        _ haystack: UnsafePointer<UInt8>, _ count: Int,
        _ needle: UnsafePointer<UInt8>, _ needleCount: Int,
        maxDistance: Int
    ) -> Int? {
        guard maxDistance > 0, needleCount > 0 else { return nil }
        var best: Int?
        var index = 0
        while index < count {
            guard isWordByte(haystack[index]) else { index += 1; continue }
            var end = index
            while end < count, isWordByte(haystack[end]) { end += 1 }
            if abs((end - index) - needleCount) <= maxDistance,
               let found = distance(haystack + index, end - index, needle, needleCount, maxDistance: maxDistance) {
                if found == 0 { return 0 }
                best = min(best ?? Int.max, found)
            }
            index = end
        }
        return best
    }

    static func wordDistance(_ haystack: [UInt8], _ needle: [UInt8], maxDistance: Int) -> Int? {
        haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                guard let base = h.baseAddress, let needleBase = n.baseAddress else { return nil }
                return wordDistance(base, h.count, needleBase, n.count, maxDistance: maxDistance)
            }
        }
    }
}
