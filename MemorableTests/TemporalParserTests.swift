import XCTest
@testable import Memorable

final class TemporalParserTests: XCTestCase {

    private let cal = Calendar.current
    private var currentYear: Int { cal.component(.year, from: Date()) }
    private var currentMonth: Int { cal.component(.month, from: Date()) }

    // MARK: - Relative Days

    func testYesterday() {
        let hints = QueryParserFallback.parse(query: "dog yesterday")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "dog")
        let yesterday = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date())!)
        XCTAssertEqual(cal.startOfDay(for: hints.dateRange!.start), yesterday)
    }

    func testToday() {
        let hints = QueryParserFallback.parse(query: "coffee today")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "coffee")
        let today = cal.startOfDay(for: Date())
        XCTAssertEqual(cal.startOfDay(for: hints.dateRange!.start), today)
    }

    func testDayBeforeYesterday() {
        let hints = QueryParserFallback.parse(query: "lunch day before yesterday")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("lunch"))
        let twoDaysAgo = cal.startOfDay(for: cal.date(byAdding: .day, value: -2, to: Date())!)
        XCTAssertEqual(cal.startOfDay(for: hints.dateRange!.start), twoDaysAgo)
    }

    func testTheOtherDay() {
        let hints = QueryParserFallback.parse(query: "coffee the other day")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.dateRange!.start < Date())
    }

    // MARK: - Relative Weeks

    func testLastWeek() {
        let hints = QueryParserFallback.parse(query: "dinner last week")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "dinner")
        XCTAssertTrue(hints.dateRange!.end < Date())
    }

    func testThisWeek() {
        let hints = QueryParserFallback.parse(query: "meeting this week")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "meeting")
    }

    func testLastWeekend() {
        let hints = QueryParserFallback.parse(query: "brunch last weekend")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("brunch"))
        XCTAssertTrue(hints.dateRange!.start < Date())
    }

    func testTwoWeeksAgo() {
        let hints = QueryParserFallback.parse(query: "photos two weeks ago")
        XCTAssertNotNil(hints.dateRange)
    }

    func testRecently() {
        let hints = QueryParserFallback.parse(query: "beach recently")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "beach")
        // Source defines "recently" as daysAgo(14). The diff includes the
        // current time-of-day offset (0 to <1 day), so expect 14.0 to 15.0.
        let daysDiff = Date().timeIntervalSince(hints.dateRange!.start) / 86400
        XCTAssertEqual(daysDiff, 14.0, accuracy: 1.0)
    }

    func testPastFewDays() {
        let hints = QueryParserFallback.parse(query: "food past few days")
        XCTAssertNotNil(hints.dateRange)
    }

    // MARK: - Relative Months

    func testLastMonth() {
        let hints = QueryParserFallback.parse(query: "birthday cake last month")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("birthday"))
        XCTAssertTrue(hints.textQuery.contains("cake"))
    }

    func testThisMonth() {
        let hints = QueryParserFallback.parse(query: "selfie this month")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "selfie")
        let firstOfMonth = cal.date(from: DateComponents(
            year: currentYear, month: currentMonth, day: 1
        ))!
        XCTAssertEqual(cal.startOfDay(for: hints.dateRange!.start), firstOfMonth)
    }

    func testTwoMonthsAgo() {
        let hints = QueryParserFallback.parse(query: "trip two months ago")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("trip"))
    }

    func testCoupleMonthsAgo() {
        let hints = QueryParserFallback.parse(query: "food couple months ago")
        XCTAssertNotNil(hints.dateRange)
    }

    func testEarlierThisYear() {
        let hints = QueryParserFallback.parse(query: "earlier this year")
        XCTAssertNotNil(hints.dateRange)
        let startYear = cal.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, currentYear)
    }

    // MARK: - Relative Years

    func testLastYear() {
        let hints = QueryParserFallback.parse(query: "vacation last year")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "vacation")
        let startYear = cal.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, currentYear - 1)
    }

    func testThisYear() {
        let hints = QueryParserFallback.parse(query: "photos this year")
        XCTAssertNotNil(hints.dateRange)
        let startYear = cal.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, currentYear)
    }

    func testTwoYearsAgo() {
        let hints = QueryParserFallback.parse(query: "wedding two years ago")
        XCTAssertNotNil(hints.dateRange)
        let startYear = cal.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, currentYear - 2)
    }

    func testFewYearsAgo() {
        let hints = QueryParserFallback.parse(query: "trip a few years ago")
        XCTAssertNotNil(hints.dateRange)
        let startYear = cal.component(.year, from: hints.dateRange!.start)
        XCTAssertTrue(startYear <= currentYear - 2)
    }

    // MARK: - Seasons

    func testLastSummer() {
        let hints = QueryParserFallback.parse(query: "beach last summer")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "beach")
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 6)
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), currentYear - 1)
    }

    func testThisWinterCrossesYearBoundary() {
        let hints = QueryParserFallback.parse(query: "snow this winter")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "snow")
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 12)
    }

    func testLastFall() {
        let hints = QueryParserFallback.parse(query: "leaves last fall")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 9)
    }

    func testLastAutumnSameAsFall() {
        let hints = QueryParserFallback.parse(query: "leaves last autumn")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 9)
    }

    func testLastSpring() {
        let hints = QueryParserFallback.parse(query: "flowers last spring")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 3)
    }

    func testSeasonWithYear() {
        let hints = QueryParserFallback.parse(query: "flowers spring 2023")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("flowers"))
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), 2023)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 3)
    }

    func testSummer2024() {
        let hints = QueryParserFallback.parse(query: "beach summer 2024")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), 2024)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 6)
        let endMonth = cal.component(.month, from: hints.dateRange!.end)
        XCTAssertTrue(endMonth == 8 || endMonth == 9, "Summer should end in Aug/Sep")
    }

    func testWinter2023CrossesYearBoundary() {
        let hints = QueryParserFallback.parse(query: "snow winter 2023")
        XCTAssertNotNil(hints.dateRange)
        // Winter 2023: Dec 2022 to Feb 2023
        let startYear = cal.component(.year, from: hints.dateRange!.start)
        let startMonth = cal.component(.month, from: hints.dateRange!.start)
        XCTAssertEqual(startMonth, 12)
        XCTAssertEqual(startYear, 2022)
    }

    // MARK: - Holidays

    func testChristmas() {
        let hints = QueryParserFallback.parse(query: "christmas dinner")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("dinner"))
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 12)
    }

    func testLastChristmas() {
        let hints = QueryParserFallback.parse(query: "presents last christmas")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 12)
    }

    func testXmasAlias() {
        let hints = QueryParserFallback.parse(query: "tree xmas")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 12)
    }

    func testChristmasEve() {
        let hints = QueryParserFallback.parse(query: "gifts christmas eve")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 12)
    }

    func testHalloween() {
        let hints = QueryParserFallback.parse(query: "costume halloween")
        XCTAssertNotNil(hints.dateRange)
        let month = cal.component(.month, from: hints.dateRange!.start)
        XCTAssertTrue(month == 10 || month == 11)
    }

    func testNewYearsEve() {
        let hints = QueryParserFallback.parse(query: "fireworks new years eve")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("fireworks"))
    }

    func testNewYear() {
        let hints = QueryParserFallback.parse(query: "party new year")
        XCTAssertNotNil(hints.dateRange)
    }

    func testThanksgiving() {
        let hints = QueryParserFallback.parse(query: "food thanksgiving")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 11)
    }

    func testValentinesDay() {
        let hints = QueryParserFallback.parse(query: "flowers valentines day")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 2)
    }

    func testEasterApproximateRange() {
        let hints = QueryParserFallback.parse(query: "eggs easter")
        XCTAssertNotNil(hints.dateRange)
        let month = cal.component(.month, from: hints.dateRange!.start)
        XCTAssertTrue(month >= 3 && month <= 4, "Easter should be in March or April range")
    }

    func testChristmasWithYear() {
        let hints = QueryParserFallback.parse(query: "gifts christmas 2023")
        XCTAssertNotNil(hints.dateRange)
        let year = cal.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(year, 2023)
    }

    // MARK: - Named Months

    func testNamedMonth() {
        let hints = QueryParserFallback.parse(query: "trip in march")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 3)
    }

    func testNamedMonthWithYear() {
        let hints = QueryParserFallback.parse(query: "wedding june 2024")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 6)
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), 2024)
    }

    func testAbbreviatedMonth() {
        let hints = QueryParserFallback.parse(query: "trip jan 2024")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 1)
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), 2024)
    }

    func testMonthLastYear() {
        let hints = QueryParserFallback.parse(query: "photos january last year")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("photos"))
        if let range = hints.dateRange {
            XCTAssertEqual(cal.component(.year, from: range.start), currentYear - 1)
            XCTAssertEqual(cal.component(.month, from: range.start), 1)
            // dayEnd pushes end to midnight of Feb 1 (just past Jan 31)
            let endMonth = cal.component(.month, from: range.end)
            XCTAssertTrue(endMonth == 1 || endMonth == 2,
                "End should be late January or midnight Feb 1, not December")
        }
    }

    func testMonthThisYear() {
        let hints = QueryParserFallback.parse(query: "food march this year")
        XCTAssertNotNil(hints.dateRange)
        if let range = hints.dateRange {
            XCTAssertEqual(cal.component(.year, from: range.start), currentYear)
            XCTAssertEqual(cal.component(.month, from: range.start), 3)
        }
    }

    func testLastMarch() {
        let hints = QueryParserFallback.parse(query: "flowers last march")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("flowers"))
        if let range = hints.dateRange {
            XCTAssertEqual(cal.component(.month, from: range.start), 3)
        }
    }

    func testAbbreviatedMonthLastYear() {
        let hints = QueryParserFallback.parse(query: "trip jan last year")
        XCTAssertNotNil(hints.dateRange)
        if let range = hints.dateRange {
            XCTAssertEqual(cal.component(.year, from: range.start), currentYear - 1)
            XCTAssertEqual(cal.component(.month, from: range.start), 1)
        }
    }

    func testBareMonthSelectsMostRecentPast() {
        let hints = QueryParserFallback.parse(query: "party january")
        XCTAssertNotNil(hints.dateRange)
        let startMonth = cal.component(.month, from: hints.dateRange!.start)
        XCTAssertEqual(startMonth, 1)
        // If we're past January, it should be this year's Jan; if in Jan, last year's
        let expectedYear = currentMonth > 1 ? currentYear : currentYear - 1
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), expectedYear)
    }

    // MARK: - Bare Year

    func testBareYear() {
        let hints = QueryParserFallback.parse(query: "vacation 2023")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("vacation"))
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), 2023)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.start), 1)
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.end), 2023)
        XCTAssertEqual(cal.component(.month, from: hints.dateRange!.end), 12)
    }

    func testBareYear2024() {
        let hints = QueryParserFallback.parse(query: "photos 2024")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(cal.component(.year, from: hints.dateRange!.start), 2024)
    }

    func testYearBelowRangeNotMatched() {
        let hints = QueryParserFallback.parse(query: "photos 1999")
        // "1999" doesn't match the /\b(20\d{2})\b/ pattern
        XCTAssertNil(hints.dateRange)
    }

    // MARK: - Longest Match Priority

    func testLongestMatchFirst() {
        // "last christmas" (14 chars) should match before "last" alone or "christmas" alone
        let hints = QueryParserFallback.parse(query: "gifts last christmas")
        XCTAssertNotNil(hints.dateRange)
        let month = cal.component(.month, from: hints.dateRange!.start)
        XCTAssertEqual(month, 12, "Should match 'last christmas', not 'last' alone")
    }

    func testChristmasDayVsChristmas() {
        // "christmas day" (13 chars) is longer than "christmas" (9 chars)
        let hints = QueryParserFallback.parse(query: "dinner christmas day")
        XCTAssertNotNil(hints.dateRange)
        let day = cal.component(.day, from: hints.dateRange!.start)
        XCTAssertEqual(day, 25)
    }

    // MARK: - No Temporal Match

    func testNoTemporalMatch() {
        let hints = QueryParserFallback.parse(query: "dog playing in park")
        XCTAssertNil(hints.dateRange)
    }

    // MARK: - Should NOT Match Partial Words

    func testSunsetDoesNotMatchSun() {
        let hints = QueryParserFallback.parse(query: "sunset at beach")
        XCTAssertNil(hints.dateRange)
    }

    func testSanDiegoDoesNotTriggerTemporal() {
        let hints = QueryParserFallback.parse(query: "sunset in san diego")
        XCTAssertNil(hints.dateRange)
    }

    func testFoodInItalyDoesNotTriggerTemporal() {
        let hints = QueryParserFallback.parse(query: "food in italy")
        XCTAssertNil(hints.dateRange)
    }

    func testWeekdayInWeekly() {
        // "week" in "weekly" should not match due to word boundary
        let hints = QueryParserFallback.parse(query: "weekly meeting notes")
        XCTAssertNil(hints.dateRange, "Partial word 'week' in 'weekly' should not match")
    }

    // MARK: - Combined Temporal + Visual

    func testTemporalStrippedFromQuery() {
        let hints = QueryParserFallback.parse(query: "beach photos from last summer")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertFalse(hints.textQuery.contains("last summer"))
        XCTAssertTrue(hints.textQuery.contains("beach"))
    }

    func testTemporalStrippedLeavesCleanText() {
        let hints = QueryParserFallback.parse(query: "sunset yesterday")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "sunset")
    }

    func testApostropheSStripped() {
        // TemporalParser strips "'s" before matching
        let hints = QueryParserFallback.parse(query: "new year's eve")
        XCTAssertNotNil(hints.dateRange)
    }
}
