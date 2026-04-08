import XCTest
@testable import Memorable

final class QueryParserTests: XCTestCase {

    // MARK: - Negative Terms

    func testNegativeTermExtraction() {
        let hints = QueryParserFallback.parse(query: "dog -cat -bird")
        XCTAssertEqual(hints.negativeTerms.sorted(), ["bird", "cat"])
        XCTAssertEqual(hints.textQuery, "dog")
    }

    func testNegativeTermWithOtherFeatures() {
        let hints = QueryParserFallback.parse(query: "food -pizza this month")
        XCTAssertEqual(hints.negativeTerms, ["pizza"])
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "food")
    }

    func testNoNegativeTerms() {
        let hints = QueryParserFallback.parse(query: "beautiful sunset")
        XCTAssertTrue(hints.negativeTerms.isEmpty)
    }

    // MARK: - Time-of-Day Detection

    func testBreakfastTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "breakfast at hotel")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 5)
        XCTAssertEqual(hints.timeOfDayHours?.end, 10)
    }

    func testDinnerTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "dinner with friends")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 18)
        XCTAssertEqual(hints.timeOfDayHours?.end, 22)
    }

    func testSunsetTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "sunset over water")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 18)
    }

    func testNightTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "night sky stars")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 20)
        XCTAssertEqual(hints.timeOfDayHours?.end, 4) // wraps midnight
    }

    func testNoTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "dog in park")
        XCTAssertNil(hints.timeOfDayHours)
    }

    // MARK: - Location Extraction

    func testLocationWithProperCase() {
        // NLTagger requires proper case for place detection
        let hints = QueryParserFallback.parse(query: "sunset in San Diego")
        // Either NLTagger or preposition fallback should extract location
        XCTAssertNotNil(hints.locationHint, "Should extract location from 'in San Diego'")
        XCTAssertTrue(hints.textQuery.contains("sunset"))
        XCTAssertFalse(hints.textQuery.contains("diego"), "Location should be stripped from textQuery")
    }

    func testLocationWithLowercase() {
        let hints = QueryParserFallback.parse(query: "food in paris")
        XCTAssertNotNil(hints.locationHint, "Should extract location even with lowercase")
    }

    func testLocationWithAt() {
        let hints = QueryParserFallback.parse(query: "photos at berlin")
        XCTAssertNotNil(hints.locationHint)
    }

    func testNoLocationForTemporalPreposition() {
        // "in summer" should be temporal, not location
        let hints = QueryParserFallback.parse(query: "beach in summer")
        XCTAssertNotNil(hints.dateRange, "'in summer' should be temporal")
        // locationHint may or may not be nil depending on parse order, but dateRange must be set
    }

    // MARK: - Query Truncation

    func testLongQueryTruncated() {
        let longQuery = String(repeating: "a ", count: 300) // 600 chars
        let hints = QueryParserFallback.parse(query: longQuery)
        XCTAssertTrue(hints.textQuery.count <= 500)
    }

    // MARK: - Empty / Edge Cases

    func testEmptyQuery() {
        let hints = QueryParserFallback.parse(query: "")
        // Empty query has no visual content — textQuery defaults to "a photo"
        XCTAssertFalse(hints.hasVisualQuery)
        XCTAssertEqual(hints.textQuery, "a photo")
    }

    func testOnlyTemporalQuery() {
        let hints = QueryParserFallback.parse(query: "last summer")
        XCTAssertNotNil(hints.dateRange)
        // textQuery should fall back to original since stripping leaves empty
    }

    func testOnlyPreposition() {
        let hints = QueryParserFallback.parse(query: "in")
        // Should not crash, textQuery may be empty or the original
        XCTAssertNotNil(hints)
    }

    // MARK: - Combined Features

    func testFullQuery() {
        let hints = QueryParserFallback.parse(query: "sunset -clouds last summer")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.negativeTerms, ["clouds"])
        XCTAssertTrue(hints.textQuery.contains("sunset"))
        XCTAssertFalse(hints.textQuery.contains("clouds"))
        XCTAssertFalse(hints.textQuery.contains("last summer"))
        XCTAssertNotNil(hints.timeOfDayHours) // "sunset" triggers evening
    }
}
