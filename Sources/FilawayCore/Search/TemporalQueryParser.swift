import Foundation

/// A half-open interval of time, `start ..< end`.
public struct DateRange: Sendable, Equatable, CustomStringConvertible {
    public let start: Date
    /// Exclusive.
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var description: String {
        "\(ISO8601.string(from: start)) ..< \(ISO8601.string(from: end))"
    }
}

/// What ``TemporalQueryParser`` made of a natural-language query (FR-5.3).
public struct TemporalQuery: Sendable, Equatable {
    /// The query as typed.
    public let original: String
    /// The query with the time phrase removed, for the embedder and FTS5.
    /// Never empty when `original` was not: a query that is *only* a date
    /// keeps its words, because "yesterday" alone is a legitimate search.
    public let strippedQuery: String
    /// A **hard** filter: only notes modified inside this range may match.
    public let range: DateRange?
    /// A **soft** window: "recently" biases towards fresh notes without
    /// excluding anything (plan §3 M3-04).
    public let boostWindow: TimeInterval?
    /// The words that were recognised, verbatim, for the UI to show as a chip.
    public let matchedPhrase: String?

    public init(
        original: String,
        strippedQuery: String,
        range: DateRange? = nil,
        boostWindow: TimeInterval? = nil,
        matchedPhrase: String? = nil
    ) {
        self.original = original
        self.strippedQuery = strippedQuery
        self.range = range
        self.boostWindow = boostWindow
        self.matchedPhrase = matchedPhrase
    }

    /// `true` when a date range was recognised.
    public var hasDateFilter: Bool { range != nil }

    /// `true` when nothing temporal was found.
    public var isEmpty: Bool { range == nil && boostWindow == nil }
}

/// Pulls a date range out of a natural-language query (FR-5.3).
///
/// > "the thing I edited two days ago about auth"
/// > → `("the thing I edited about auth", 2026-08-21 ..< 2026-08-22)`
///
/// The parser is deliberately **conservative**: a false positive silently hides
/// the notes the user was looking for, which is far worse than not recognising
/// a phrase. So `"two days"` without `"ago"` is not a date, a bare `"May"` is
/// not a month (it is usually a modal verb), and `"1.2.3"` is not anything.
/// Every pattern needs an anchor word — `ago`, `last`, `this`, `on`, `in`, or a
/// day number after the month.
///
/// `now` and the calendar are injected, so the tests are not a Tuesday.
public struct TemporalQueryParser: Sendable {
    public var calendar: Calendar

    /// - Parameter calendar: defaults to the user's, which is what decides when
    ///   a week starts and which time zone "yesterday" is in.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// How far back "recently" reaches — a boost, never a filter.
    public static let recentWindow: TimeInterval = 7 * 86_400

    public func parse(_ query: String, now: Date = Date()) -> TemporalQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TemporalQuery(original: query, strippedQuery: "")
        }

        for pattern in Self.patterns {
            guard let match = pattern.firstMatch(in: trimmed) else { continue }
            guard let outcome = pattern.resolve(match, self, now) else { continue }
            let phrase = String(trimmed[match.range])
            let stripped = Self.strip(match.range, from: trimmed)
            return TemporalQuery(
                original: query,
                // "yesterday" on its own is a real query; keep the words rather
                // than sending an empty string to the embedder.
                strippedQuery: stripped.isEmpty ? trimmed : stripped,
                range: outcome.range,
                boostWindow: outcome.boostWindow,
                matchedPhrase: phrase
            )
        }
        return TemporalQuery(original: query, strippedQuery: trimmed)
    }

    /// Convenience for callers that only want the pair plan §3 M3-04 names.
    public func split(_ query: String, now: Date = Date()) -> (strippedQuery: String, range: DateRange?) {
        let parsed = parse(query, now: now)
        return (parsed.strippedQuery, parsed.range)
    }

    // MARK: - Stripping

    /// Connectors left dangling once the date is gone. "…from two days ago"
    /// must not become "…from".
    static let connectors: Set<String> = [
        "from", "on", "in", "at", "since", "during", "around", "of", "the", "that", "was",
    ]

    static func strip(_ range: Range<String.Index>, from text: String) -> String {
        var head = String(text[text.startIndex ..< range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let tail = String(text[range.upperBound...])
        while let last = head.split(separator: " ").last, connectors.contains(last.lowercased()) {
            head = String(head.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
        }
        return (head + " " + tail)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Calendar helpers

    func day(containing date: Date) -> DateRange {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateRange(start: start, end: end)
    }

    func unit(_ component: Calendar.Component, containing date: Date) -> DateRange? {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return nil }
        return DateRange(start: interval.start, end: interval.end)
    }

    func shifted(_ component: Calendar.Component, by value: Int, from date: Date) -> Date? {
        calendar.date(byAdding: component, value: value, to: date)
    }

    /// The most recent occurrence of `weekday` at or before `now`.
    func lastWeekday(_ weekday: Int, before now: Date) -> DateRange {
        let today = calendar.startOfDay(for: now)
        let current = calendar.component(.weekday, from: today)
        var delta = current - weekday
        if delta < 0 { delta += 7 }
        let target = calendar.date(byAdding: .day, value: -delta, to: today) ?? today
        return day(containing: target)
    }

    /// The most recent `month` that has already begun.
    func lastMonth(_ month: Int, before now: Date) -> DateRange? {
        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = 1
        guard var start = calendar.date(from: components) else { return nil }
        if start > now, let earlier = calendar.date(byAdding: .year, value: -1, to: start) {
            start = earlier
        }
        guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateRange(start: start, end: end)
    }

    /// The most recent `month`/`day` at or before `now`.
    func lastDate(month: Int, day: Int, before now: Date) -> DateRange? {
        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        guard var start = calendar.date(from: components) else { return nil }
        // Guard against a rolled-over date (31 February becoming 3 March).
        guard calendar.component(.day, from: start) == day,
              calendar.component(.month, from: start) == month
        else { return nil }
        if start > now, let earlier = calendar.date(byAdding: .year, value: -1, to: start) {
            start = earlier
        }
        return self.day(containing: start)
    }

    // MARK: - Patterns

    struct Outcome {
        var range: DateRange?
        var boostWindow: TimeInterval?
    }

    struct Pattern: Sendable {
        let expression: NSRegularExpression
        let resolve: @Sendable (Match, TemporalQueryParser, Date) -> Outcome?

        init(_ pattern: String, resolve: @escaping @Sendable (Match, TemporalQueryParser, Date) -> Outcome?) {
            // Every pattern is written case-insensitively and anchored on word
            // boundaries; a failure here is a programming error, not input.
            expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.resolve = resolve
        }

        func firstMatch(in text: String) -> Match? {
            let ns = text as NSString
            guard let result = expression.firstMatch(
                in: text, options: [], range: NSRange(location: 0, length: ns.length)
            ), let range = Range(result.range, in: text) else { return nil }
            return Match(result: result, text: text, range: range)
        }
    }

    struct Match {
        let result: NSTextCheckingResult
        let text: String
        let range: Range<String.Index>

        func group(_ index: Int) -> String? {
            guard index < result.numberOfRanges,
                  let range = Range(result.range(at: index), in: text)
            else { return nil }
            return String(text[range]).lowercased()
        }
    }

    static let weekdays = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    static let months = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "couple of": 2, "couple": 2, "few": 3, "several": 3,
    ]

    static func count(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if let value = Int(raw) { return value > 0 && value < 500 ? value : nil }
        return numberWords[raw]
    }

    /// Ordered most specific first. The first pattern that both matches *and*
    /// resolves to a real range wins.
    static let patterns: [Pattern] = {
        let weekdayAlternation = weekdays.keys.sorted().joined(separator: "|")
        let monthAlternation = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let numberAlternation = (numberWords.keys.sorted { $0.count > $1.count } + ["\\d{1,3}"])
            .joined(separator: "|")

        return [
            // "last night" before "last week" so the shorter word cannot win.
            Pattern("\\blast night\\b") { _, parser, now in
                let today = parser.calendar.startOfDay(for: now)
                guard let start = parser.calendar.date(byAdding: .hour, value: -6, to: today),
                      let end = parser.calendar.date(byAdding: .hour, value: 6, to: today)
                else { return nil }
                return Outcome(range: DateRange(start: start, end: end))
            },

            Pattern("\\byesterday\\b") { _, parser, now in
                guard let yesterday = parser.shifted(.day, by: -1, from: now) else { return nil }
                return Outcome(range: parser.day(containing: yesterday))
            },

            Pattern("\\btoday\\b") { _, parser, now in
                Outcome(range: parser.day(containing: now))
            },

            Pattern("\\bthis morning\\b") { _, parser, now in
                let today = parser.calendar.startOfDay(for: now)
                guard let end = parser.calendar.date(byAdding: .hour, value: 12, to: today) else { return nil }
                return Outcome(range: DateRange(start: today, end: end))
            },

            // "N days/weeks/months/years ago". The anchor is `ago`: without it
            // "two days" is a duration, not a date.
            Pattern("\\b(\(numberAlternation))\\s+(day|days|week|weeks|month|months|year|years)\\s+ago\\b") {
                match, parser, now in
                guard let value = count(match.group(1)), let unit = match.group(2) else { return nil }
                switch unit {
                case "day", "days":
                    guard let then = parser.shifted(.day, by: -value, from: now) else { return nil }
                    return Outcome(range: parser.day(containing: then))
                case "week", "weeks":
                    guard let then = parser.shifted(.weekOfYear, by: -value, from: now),
                          let range = parser.unit(.weekOfYear, containing: then) else { return nil }
                    return Outcome(range: range)
                case "month", "months":
                    guard let then = parser.shifted(.month, by: -value, from: now),
                          let range = parser.unit(.month, containing: then) else { return nil }
                    return Outcome(range: range)
                default:
                    guard let then = parser.shifted(.year, by: -value, from: now),
                          let range = parser.unit(.year, containing: then) else { return nil }
                    return Outcome(range: range)
                }
            },

            Pattern("\\blast\\s+(week|month|year)\\b") { match, parser, now in
                let component: Calendar.Component = switch match.group(1) {
                case "week": .weekOfYear
                case "month": .month
                default: .year
                }
                guard let then = parser.shifted(component, by: -1, from: now),
                      let range = parser.unit(component, containing: then) else { return nil }
                return Outcome(range: range)
            },

            Pattern("\\bthis\\s+(week|month|year)\\b") { match, parser, now in
                let component: Calendar.Component = switch match.group(1) {
                case "week": .weekOfYear
                case "month": .month
                default: .year
                }
                guard let range = parser.unit(component, containing: now) else { return nil }
                return Outcome(range: range)
            },

            // "last Tuesday", "on Tuesday", or a bare weekday — unlike month
            // names, weekday names are never anything else in English.
            Pattern("\\b(?:on|last|this|since)?\\s*(\(weekdayAlternation))\\b") { match, parser, now in
                guard let name = match.group(1), let weekday = weekdays[name] else { return nil }
                return Outcome(range: parser.lastWeekday(weekday, before: now))
            },

            // "May 3", "March 12th", "Dec 1". The day number is the anchor that
            // keeps "may" and "march" from matching as ordinary words.
            Pattern("\\b(\(monthAlternation))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b") { match, parser, now in
                guard let name = match.group(1), let month = months[name],
                      let day = match.group(2).flatMap(Int.init), (1 ... 31).contains(day)
                else { return nil }
                return parser.lastDate(month: month, day: day, before: now).map { Outcome(range: $0) }
            },

            // "3 May" / "12th of March".
            Pattern("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(\(monthAlternation))\\b") { match, parser, now in
                guard let day = match.group(1).flatMap(Int.init), (1 ... 31).contains(day),
                      let name = match.group(2), let month = months[name]
                else { return nil }
                return parser.lastDate(month: month, day: day, before: now).map { Outcome(range: $0) }
            },

            // "in May", "back in December" — the preposition is the anchor.
            Pattern("\\bin\\s+(\(monthAlternation))\\b") { match, parser, now in
                guard let name = match.group(1), let month = months[name] else { return nil }
                return parser.lastMonth(month, before: now).map { Outcome(range: $0) }
            },

            // FR-5.3's soft case: a bias, never a filter.
            Pattern("\\b(?:recently|lately|the other day)\\b") { _, _, _ in
                Outcome(range: nil, boostWindow: TemporalQueryParser.recentWindow)
            },
        ]
    }()
}
