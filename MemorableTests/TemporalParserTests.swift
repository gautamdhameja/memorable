import XCTest
@testable import Memorable

final class TemporalParserTests: XCTestCase {

    // MARK: - Relative Days

    func testYesterday() {
        let hints = QueryParserFallback.parse(query: "dog yesterday")
        XCTAssertNotNil(hints.dateRange, "Should extract date range for 'yesterday'")
        XCTAssertEqual(hints.textQuery, "dog")

        let cal = Calendar.current
        let yesterday = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date())!)
        XCTAssertEqual(cal.startOfDay(for: hints.dateRange!.start), yesterday)
    }

    func testToday() {
        let hints = QueryParserFallback.parse(query: "coffee today")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "coffee")

        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(Calendar.current.startOfDay(for: hints.dateRange!.start), today)
    }

    func testDayBeforeYesterday() {
        let hints = QueryParserFallback.parse(query: "lunch day before yesterday")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("lunch"))
    }

    // MARK: - Relative Weeks

    func testLastWeek() {
        let hints = QueryParserFallback.parse(query: "dinner last week")
        XCTAssertNotNil(hints.dateRange, "Should extract date range for 'last week'")
        XCTAssertEqual(hints.textQuery, "dinner")

        // Last week should be in the past
        XCTAssertTrue(hints.dateRange!.end < Date())
    }

    func testThisWeek() {
        let hints = QueryParserFallback.parse(query: "meeting this week")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "meeting")
    }

    func testRecently() {
        let hints = QueryParserFallback.parse(query: "beach recently")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "beach")

        // Recently should cover roughly last 14 days
        let daysDiff = Date().timeIntervalSince(hints.dateRange!.start) / 86400
        XCTAssertTrue(daysDiff >= 13 && daysDiff <= 15)
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

        let cal = Calendar.current
        let firstOfMonth = cal.date(from: DateComponents(
            year: cal.component(.year, from: Date()),
            month: cal.component(.month, from: Date()),
            day: 1
        ))!
        XCTAssertEqual(cal.startOfDay(for: hints.dateRange!.start), firstOfMonth)
    }

    // MARK: - Relative Years

    func testLastYear() {
        let hints = QueryParserFallback.parse(query: "vacation last year")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "vacation")

        let lastYear = Calendar.current.component(.year, from: Date()) - 1
        let startYear = Calendar.current.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, lastYear)
    }

    func testThisYear() {
        let hints = QueryParserFallback.parse(query: "photos this year")
        XCTAssertNotNil(hints.dateRange)

        let thisYear = Calendar.current.component(.year, from: Date())
        let startYear = Calendar.current.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, thisYear)
    }

    // MARK: - Seasons

    func testLastSummer() {
        let hints = QueryParserFallback.parse(query: "beach last summer")
        XCTAssertNotNil(hints.dateRange, "Should extract date range for 'last summer'")
        XCTAssertEqual(hints.textQuery, "beach")

        let lastYear = Calendar.current.component(.year, from: Date()) - 1
        let startMonth = Calendar.current.component(.month, from: hints.dateRange!.start)
        let startYear = Calendar.current.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startMonth, 6, "Last summer should start in June")
        XCTAssertEqual(startYear, lastYear)
    }

    func testThisWinter() {
        let hints = QueryParserFallback.parse(query: "snow this winter")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "snow")
        // Winter spans Dec-Feb across year boundary
        XCTAssertEqual(Calendar.current.component(.month, from: hints.dateRange!.start), 12)
    }

    func testSeasonWithYear() {
        let hints = QueryParserFallback.parse(query: "flowers spring 2023")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("flowers"))

        let startYear = Calendar.current.component(.year, from: hints.dateRange!.start)
        let startMonth = Calendar.current.component(.month, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, 2023)
        XCTAssertEqual(startMonth, 3, "Spring should start in March")
    }

    // MARK: - Holidays

    func testChristmas() {
        let hints = QueryParserFallback.parse(query: "christmas dinner")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("dinner"))

        let month = Calendar.current.component(.month, from: hints.dateRange!.start)
        XCTAssertEqual(month, 12, "Christmas should be in December")
    }

    func testHalloween() {
        let hints = QueryParserFallback.parse(query: "costume halloween")
        XCTAssertNotNil(hints.dateRange)

        let month = Calendar.current.component(.month, from: hints.dateRange!.start)
        XCTAssertTrue(month == 10 || month == 11, "Halloween should be late October/early November")
    }

    func testNewYears() {
        let hints = QueryParserFallback.parse(query: "fireworks new years eve")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("fireworks"))
    }

    // MARK: - Named Months

    func testNamedMonth() {
        let hints = QueryParserFallback.parse(query: "trip in march")
        XCTAssertNotNil(hints.dateRange)
        let startMonth = Calendar.current.component(.month, from: hints.dateRange!.start)
        XCTAssertEqual(startMonth, 3)
    }

    func testNamedMonthWithYear() {
        let hints = QueryParserFallback.parse(query: "wedding june 2024")
        XCTAssertNotNil(hints.dateRange)

        let startMonth = Calendar.current.component(.month, from: hints.dateRange!.start)
        let startYear = Calendar.current.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startMonth, 6)
        XCTAssertEqual(startYear, 2024)
    }

    // MARK: - Bare Year

    func testBareYear() {
        let hints = QueryParserFallback.parse(query: "vacation 2023")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("vacation"))

        let startYear = Calendar.current.component(.year, from: hints.dateRange!.start)
        XCTAssertEqual(startYear, 2023)
    }

    // MARK: - No Temporal Match

    func testNoTemporalMatch() {
        let hints = QueryParserFallback.parse(query: "dog playing in park")
        XCTAssertNil(hints.dateRange, "Should not extract date for non-temporal query")
    }

    // MARK: - Should NOT Match Partial Words

    func testSunsetDoesNotMatchSun() {
        // "sun" is not a temporal pattern; ensure "sunset" doesn't trigger anything
        let hints = QueryParserFallback.parse(query: "sunset at beach")
        XCTAssertNil(hints.dateRange)
    }

    func testSanDiegoDoesNotTriggerTemporal() {
        let hints = QueryParserFallback.parse(query: "sunset in san diego")
        XCTAssertNil(hints.dateRange, "'in san diego' should not match 'in summer' or any temporal pattern")
    }

    func testFoodInItalyDoesNotTriggerTemporal() {
        let hints = QueryParserFallback.parse(query: "food in italy")
        XCTAssertNil(hints.dateRange, "'in italy' should not match 'in' temporal patterns")
    }

    // MARK: - Combined Temporal + Visual

    func testTemporalStrippedFromQuery() {
        let hints = QueryParserFallback.parse(query: "beach photos from last summer")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertFalse(hints.textQuery.contains("last summer"), "Temporal phrase should be stripped from textQuery")
        XCTAssertTrue(hints.textQuery.contains("beach"))
    }
}
