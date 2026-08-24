import Foundation

/// Minimal, allocation-free ISO-8601 date support for front-matter (DS-2).
///
/// `Foundation.ISO8601DateFormatter` is not `Sendable` and allocating one per
/// note makes a 5,000-note scan measurably slower, so the two operations the
/// front-matter codec needs are hand-rolled on top of integer civil-date maths
/// (Howard Hinnant's `days_from_civil` / `civil_from_days`).
public enum ISO8601 {
    /// Canonical form Filaway writes: `2026-08-22T21:49:00Z` (UTC, no fractional seconds).
    public static func string(from date: Date) -> String {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var days = total / 86_400
        var secondOfDay = total % 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / 3600
        let minute = (secondOfDay % 3600) / 60
        let second = secondOfDay % 60
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))Z"
    }

    /// Tolerant parser: accepts `yyyy-MM-dd`, `yyyy-MM-ddTHH:mm:ss`, a space
    /// instead of `T`, optional fractional seconds, and `Z` / `±HH:MM` / `±HHMM`
    /// offsets. Anything else returns `nil` (the caller then treats the value as
    /// an unknown scalar and preserves it verbatim).
    public static func date(from raw: String) -> Date? {
        let s = Array(raw.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0

        func digits(_ count: Int) -> Int? {
            guard i + count <= s.count else { return nil }
            var value = 0
            for _ in 0 ..< count {
                let c = s[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
                i += 1
            }
            return value
        }
        func expect(_ scalar: UInt8) -> Bool {
            guard i < s.count, s[i] == scalar else { return false }
            i += 1
            return true
        }

        guard let year = digits(4), expect(45), let month = digits(2), expect(45), let day = digits(2) else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        var hour = 0, minute = 0, second = 0, offset = 0
        if i < s.count, s[i] == 84 || s[i] == 116 || s[i] == 32 {  // 'T' | 't' | ' '
            i += 1
            guard let h = digits(2), expect(58), let m = digits(2) else { return nil }
            hour = h
            minute = m
            if i < s.count, s[i] == 58 {
                i += 1
                guard let sec = digits(2) else { return nil }
                second = sec
            }
            if i < s.count, s[i] == 46 {  // '.'
                i += 1
                while i < s.count, s[i] >= 48, s[i] <= 57 { i += 1 }
            }
            if i < s.count {
                let sign = s[i]
                if sign == 90 || sign == 122 {  // 'Z' | 'z'
                    i += 1
                } else if sign == 43 || sign == 45 {  // '+' | '-'
                    i += 1
                    guard let oh = digits(2) else { return nil }
                    if i < s.count, s[i] == 58 { i += 1 }
                    let om = digits(2) ?? 0
                    offset = (oh * 3600 + om * 60) * (sign == 45 ? -1 : 1)
                }
            }
        }
        guard i == s.count else { return nil }
        guard hour < 24, minute < 60, second <= 60 else { return nil }

        let days = daysFromCivil(year, month, day)
        let epoch = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// `yyyy-MM-dd HHmm` in the *local* time zone — the suffix used for
    /// external-edit conflict copies (DS-4).
    public static func conflictStamp(from date: Date, timeZone: TimeZone = .current) -> String {
        let shifted = Int(date.timeIntervalSince1970.rounded(.down)) + timeZone.secondsFromGMT(for: date)
        var days = shifted / 86_400
        var secondOfDay = shifted % 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)) \(pad(secondOfDay / 3600, 2))\(pad((secondOfDay % 3600) / 60, 2))"
    }

    // MARK: - Civil date maths

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ input: Int) -> (year: Int, month: Int, day: Int) {
        let z = input + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
