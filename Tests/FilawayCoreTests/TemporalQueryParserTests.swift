import Foundation
import Testing

@testable import FilawayCore

/// M3-04 — the temporal query parser (FR-5.3).
@Suite("TemporalQueryParser")
struct TemporalQueryParserTests {
    /// A fixed clock and a fixed calendar, so none of this depends on the day
    /// the suite happens to run: **Wednesday 12 August 2026, 14:30 UTC**.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2  // Monday, so "last week" is Mon–Sun
        return calendar
    }()

    static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 12
        components.hour = 14
        components.minute = 30
        return calendar.date(from: components)!
    }()

    static let parser = TemporalQueryParser(calendar: calendar)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    static func parse(_ query: String) -> TemporalQuery {
        parser.parse(query, now: now)
    }

    // MARK: - The headline case

    @Test("the plan's own example")
    func planExample() {
        let parsed = Self.parse("the thing I edited two days ago about auth")
        #expect(parsed.strippedQuery == "the thing I edited about auth")
        #expect(parsed.range == DateRange(start: Self.date(2026, 8, 10), end: Self.date(2026, 8, 11)))
        #expect(parsed.matchedPhrase == "two days ago")
        #expect(parsed.hasDateFilter)
    }

    @Test("a dangling connector is removed with the phrase")
    func danglingConnector() {
        #expect(Self.parse("the curl command from two days ago").strippedQuery == "the curl command")
        #expect(Self.parse("notes from yesterday").strippedQuery == "notes")
        #expect(Self.parse("what did I write on tuesday").strippedQuery == "what did I write")
    }

    @Test("a query that is only a date keeps its words")
    func dateOnlyQuery() {
        let parsed = Self.parse("yesterday")
        #expect(parsed.strippedQuery == "yesterday")
        #expect(parsed.range != nil)
    }

    // MARK: - Day patterns

    @Test("yesterday, today and last night")
    func dayKeywords() {
        #expect(Self.parse("yesterday").range
            == DateRange(start: Self.date(2026, 8, 11), end: Self.date(2026, 8, 12)))
        #expect(Self.parse("today").range
            == DateRange(start: Self.date(2026, 8, 12), end: Self.date(2026, 8, 13)))
        // 18:00 yesterday to 06:00 today.
        #expect(Self.parse("last night").range
            == DateRange(start: Self.date(2026, 8, 11, 18), end: Self.date(2026, 8, 12, 6)))
        #expect(Self.parse("this morning").range
            == DateRange(start: Self.date(2026, 8, 12), end: Self.date(2026, 8, 12, 12)))
    }

    @Test("N days ago, in digits and in words", arguments: [
        ("1 day ago", 11), ("2 days ago", 10), ("three days ago", 9),
        ("10 days ago", 2), ("a day ago", 11), ("couple of days ago", 10),
    ])
    func daysAgo(query: String, expectedDay: Int) {
        let parsed = Self.parse(query)
        #expect(parsed.range?.start == Self.date(2026, 8, expectedDay))
        #expect(parsed.range?.end == Self.date(2026, 8, expectedDay + 1))
    }

    // MARK: - Week, month, year

    @Test("last week is the previous Monday-to-Sunday")
    func lastWeek() {
        // 12 Aug 2026 is a Wednesday; its week starts Monday 10 Aug.
        #expect(Self.parse("last week").range
            == DateRange(start: Self.date(2026, 8, 3), end: Self.date(2026, 8, 10)))
        #expect(Self.parse("this week").range
            == DateRange(start: Self.date(2026, 8, 10), end: Self.date(2026, 8, 17)))
    }

    @Test("N weeks ago is the calendar week that far back")
    func weeksAgo() {
        #expect(Self.parse("two weeks ago").range
            == DateRange(start: Self.date(2026, 7, 27), end: Self.date(2026, 8, 3)))
    }

    @Test("last month, this month and N months ago")
    func months() {
        #expect(Self.parse("last month").range
            == DateRange(start: Self.date(2026, 7, 1), end: Self.date(2026, 8, 1)))
        #expect(Self.parse("this month").range
            == DateRange(start: Self.date(2026, 8, 1), end: Self.date(2026, 9, 1)))
        #expect(Self.parse("three months ago").range
            == DateRange(start: Self.date(2026, 5, 1), end: Self.date(2026, 6, 1)))
    }

    @Test("last year and N years ago")
    func years() {
        #expect(Self.parse("last year").range
            == DateRange(start: Self.date(2025, 1, 1), end: Self.date(2026, 1, 1)))
        #expect(Self.parse("two years ago").range
            == DateRange(start: Self.date(2024, 1, 1), end: Self.date(2025, 1, 1)))
    }

    // MARK: - Weekdays

    @Test("a weekday resolves to its most recent occurrence", arguments: [
        ("on monday", 10), ("on tuesday", 11), ("on wednesday", 12),
        ("on thursday", 6), ("last friday", 7), ("on sunday", 9),
    ])
    func weekdays(query: String, expectedDay: Int) {
        #expect(Self.parse(query).range?.start == Self.date(2026, 8, expectedDay))
    }

    @Test("today's weekday resolves to today, not a week ago")
    func todaysWeekday() {
        // "now" is a Wednesday.
        #expect(Self.parse("the note from wednesday").range
            == DateRange(start: Self.date(2026, 8, 12), end: Self.date(2026, 8, 13)))
    }

    // MARK: - Months and dates

    @Test("in <month> resolves to the most recent one that has begun")
    func inMonth() {
        // May 2026 is in the past.
        #expect(Self.parse("the deploy notes in may").range
            == DateRange(start: Self.date(2026, 5, 1), end: Self.date(2026, 6, 1)))
        // December 2026 has not begun, so December 2025 is meant.
        #expect(Self.parse("the retro in december").range
            == DateRange(start: Self.date(2025, 12, 1), end: Self.date(2026, 1, 1)))
    }

    @Test("<month> <day> and <day> <month>", arguments: [
        "may 3", "May 3rd", "3 may", "3rd of May",
    ])
    func monthAndDay(query: String) {
        #expect(Self.parse("the migration \(query)").range
            == DateRange(start: Self.date(2026, 5, 3), end: Self.date(2026, 5, 4)))
    }

    @Test("a month-day in the future means last year")
    func futureMonthDay() {
        #expect(Self.parse("the invoice december 1").range
            == DateRange(start: Self.date(2025, 12, 1), end: Self.date(2025, 12, 2)))
    }

    @Test("an impossible date is not a date")
    func impossibleDate() {
        #expect(Self.parse("february 31 config").range == nil)
    }

    // MARK: - Soft window

    @Test("recently boosts without filtering")
    func recentlyIsSoft() {
        let parsed = Self.parse("the redis config I touched recently")
        #expect(parsed.range == nil)
        #expect(parsed.boostWindow == TemporalQueryParser.recentWindow)
        #expect(parsed.strippedQuery == "the redis config I touched")
        #expect(!parsed.hasDateFilter)
        #expect(!parsed.isEmpty)
    }

    @Test("lately and the other day are the same soft window", arguments: [
        "lately", "the other day",
    ])
    func softSynonyms(word: String) {
        let parsed = Self.parse("the thing I saw \(word)")
        #expect(parsed.range == nil)
        #expect(parsed.boostWindow == TemporalQueryParser.recentWindow)
    }

    // MARK: - Negatives (the important half)

    @Test("phrases that only look temporal are left alone", arguments: [
        "two days",                          // a duration, not a date
        "the three day sprint plan",
        "how many days in a month",
        "curl -sSL https://example.com",
        "version 1.2.3 release notes",
        "v2.1 changelog",
        "I may need to fix the parser",      // modal verb, not a month
        "may the deploy succeed",
        "march the tests through CI",        // verb, not a month
        "the august release checklist",      // bare month name, no anchor
        "docker compose up -d",
        "postgres 16 upgrade",
        "the 2026 roadmap",
        "chapter 3 notes",
    ])
    func negatives(query: String) {
        let parsed = Self.parse(query)
        #expect(parsed.range == nil, "\(query) should not parse as a date")
        #expect(parsed.boostWindow == nil, "\(query) should not parse as a boost")
        #expect(parsed.isEmpty)
        #expect(parsed.strippedQuery == query)
    }

    @Test("an empty query is empty, not a crash")
    func emptyQuery() {
        let parsed = Self.parse("   ")
        #expect(parsed.strippedQuery.isEmpty)
        #expect(parsed.isEmpty)
    }

    // MARK: - Injected clock

    @Test("the answer moves with the injected clock")
    func clockIsInjected() {
        let earlier = Self.date(2026, 3, 5, 9)
        let parsed = Self.parser.parse("what did I write in may", now: earlier)
        // May 2026 has not begun yet on 5 March 2026, so May 2025 is meant.
        #expect(parsed.range == DateRange(start: Self.date(2025, 5, 1), end: Self.date(2025, 6, 1)))
    }

    @Test("the calendar's time zone decides where a day starts")
    func timeZoneMatters() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let parsed = TemporalQueryParser(calendar: tokyo).parse("yesterday", now: Self.now)
        let range = try! #require(parsed.range)
        // 2026-08-12 14:30 UTC is 23:30 in Tokyo, so "yesterday" there is
        // 2026-08-11 Tokyo time = 2026-08-10 15:00 UTC.
        #expect(range.duration == 86_400)
        #expect(range.start < Self.date(2026, 8, 11))
    }

    // MARK: - The pair the plan asks for

    @Test("split returns the pair plan §3 M3-04 names")
    func splitPair() {
        let (stripped, range) = Self.parser.split("the curl command from two days ago", now: Self.now)
        #expect(stripped == "the curl command")
        #expect(range == DateRange(start: Self.date(2026, 8, 10), end: Self.date(2026, 8, 11)))
    }

    // MARK: - DateRange

    @Test("a date range is half-open")
    func rangeIsHalfOpen() {
        let range = DateRange(start: Self.date(2026, 8, 11), end: Self.date(2026, 8, 12))
        #expect(range.contains(Self.date(2026, 8, 11)))
        #expect(range.contains(Self.date(2026, 8, 11, 23)))
        #expect(!range.contains(Self.date(2026, 8, 12)))
        #expect(!range.contains(Self.date(2026, 8, 10, 23)))
        // An inverted range collapses rather than matching everything.
        #expect(DateRange(start: Self.date(2026, 8, 12), end: Self.date(2026, 8, 11)).duration == 0)
    }
}

/// M3-03 — the soft recency half of FR-5.3.
@Suite("RecencyPrior")
struct RecencyPriorTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a note edited now gets the full boost, an ancient one gets none")
    func decay() {
        let prior = RecencyPrior(halfLife: 30 * 86_400, maxBoost: 0.2)
        #expect(abs(prior.multiplier(for: Self.now, now: Self.now) - 1.2) < 1e-6)
        // One half-life back: half the boost.
        let month = Self.now.addingTimeInterval(-30 * 86_400)
        #expect(abs(prior.multiplier(for: month, now: Self.now) - 1.1) < 1e-6)
        let ancient = Self.now.addingTimeInterval(-3_650 * 86_400)
        #expect(prior.multiplier(for: ancient, now: Self.now) < 1.001)
    }

    @Test("the boost is monotonic and bounded")
    func bounded() {
        let prior = RecencyPrior.default
        var previous = Double.infinity
        for days in 0 ... 400 {
            let value = prior.multiplier(
                for: Self.now.addingTimeInterval(-Double(days) * 86_400), now: Self.now
            )
            #expect(value <= 1 + prior.maxBoost + 1e-9)
            #expect(value >= 1)
            #expect(value <= previous)
            previous = value
        }
    }

    @Test("a future mtime is clamped to now rather than boosted further")
    func futureModification() {
        let prior = RecencyPrior.default
        let future = Self.now.addingTimeInterval(86_400)
        #expect(prior.multiplier(for: future, now: Self.now)
            == prior.multiplier(for: Self.now, now: Self.now))
    }

    @Test("`none` is exactly neutral")
    func noneIsNeutral() {
        #expect(RecencyPrior.none.multiplier(for: .distantPast, now: Self.now) == 1)
        #expect(RecencyPrior.none.multiplier(for: Self.now, now: Self.now) == 1)
    }

    @Test("`recent` is sharper and stronger than the default")
    func recentIsSharper() {
        let day = Self.now.addingTimeInterval(-86_400)
        let month = Self.now.addingTimeInterval(-30 * 86_400)
        #expect(RecencyPrior.recent.multiplier(for: day, now: Self.now)
            > RecencyPrior.default.multiplier(for: day, now: Self.now))
        // …but it decays away much faster.
        #expect(RecencyPrior.recent.multiplier(for: month, now: Self.now)
            < RecencyPrior.default.multiplier(for: month, now: Self.now))
    }
}
