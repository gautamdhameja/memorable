import XCTest
@testable import Memorable

final class ResultGrouperTests: XCTestCase {

    private let cal = Calendar.current

    private func makeResult(id: String, date: Date?, score: Float = 0.5) -> SearchResult {
        SearchResult(id: id, score: score, localIdentifier: id, creationDate: date, isVideo: false, bestFramePosition: nil)
    }

    // MARK: - Basic Grouping

    func testGroupsByMonth() {
        let jan = cal.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let feb = cal.date(from: DateComponents(year: 2024, month: 2, day: 10))!
        let results = [
            makeResult(id: "1", date: jan),
            makeResult(id: "2", date: jan),
            makeResult(id: "3", date: feb),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].results.count, 2)
        XCTAssertEqual(groups[1].results.count, 1)
    }

    func testSingleMonthSingleGroup() {
        let date = cal.date(from: DateComponents(year: 2024, month: 3, day: 1))!
        let results = (1...5).map { makeResult(id: "\($0)", date: date) }
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].results.count, 5)
    }

    func testEmptyResults() {
        let groups = ResultGrouper.groupByMonth(results: [])
        XCTAssertTrue(groups.isEmpty)
    }

    func testSingleResult() {
        let results = [makeResult(id: "1", date: Date())]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].results.count, 1)
    }

    // MARK: - Nil Dates

    func testNilDatesGroupedTogether() {
        let results = [
            makeResult(id: "1", date: nil),
            makeResult(id: "2", date: nil),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].label, "Unknown Date")
    }

    func testMixedNilAndRealDates() {
        let date = cal.date(from: DateComponents(year: 2024, month: 5, day: 1))!
        let results = [
            makeResult(id: "1", date: date),
            makeResult(id: "2", date: nil),
            makeResult(id: "3", date: date),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 2)
    }

    // MARK: - Year Spanning

    func testYearSpanningSeparateGroups() {
        let dec2023 = cal.date(from: DateComponents(year: 2023, month: 12, day: 15))!
        let jan2024 = cal.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let results = [
            makeResult(id: "1", date: dec2023),
            makeResult(id: "2", date: jan2024),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 2)
        XCTAssertNotEqual(groups[0].label, groups[1].label)
    }

    func testSameMonthDifferentYears() {
        let jan2023 = cal.date(from: DateComponents(year: 2023, month: 1, day: 10))!
        let jan2024 = cal.date(from: DateComponents(year: 2024, month: 1, day: 10))!
        let results = [
            makeResult(id: "1", date: jan2023),
            makeResult(id: "2", date: jan2024),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 2, "Same month in different years should be separate groups")
    }

    // MARK: - Order Preservation

    func testPreservesOrderWithinGroup() {
        let date = Date()
        let results = [
            makeResult(id: "a", date: date),
            makeResult(id: "b", date: date),
            makeResult(id: "c", date: date),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.first?.results.map(\.id), ["a", "b", "c"])
    }

    func testGroupOrderIsFirstAppearance() {
        let feb = cal.date(from: DateComponents(year: 2024, month: 2, day: 1))!
        let jan = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let results = [
            makeResult(id: "1", date: feb),
            makeResult(id: "2", date: jan),
        ]
        let groups = ResultGrouper.groupByMonth(results: results)
        // February appears first in input, so it should be the first group
        XCTAssertTrue(groups[0].label.contains("February"))
    }

    // MARK: - Label Format

    func testLabelContainsMonthAndYear() {
        let date = cal.date(from: DateComponents(year: 2024, month: 6, day: 15))!
        let results = [makeResult(id: "1", date: date)]
        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertTrue(groups[0].label.contains("2024"))
    }
}
