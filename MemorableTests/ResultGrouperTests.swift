import XCTest
@testable import Memorable

final class ResultGrouperTests: XCTestCase {

    private func makeResult(id: String, date: Date?) -> SearchResult {
        SearchResult(id: id, score: 0.5, localIdentifier: id, creationDate: date, isVideo: false, bestFramePosition: nil)
    }

    func testGroupsByMonth() {
        let cal = Calendar.current
        let jan = cal.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let feb = cal.date(from: DateComponents(year: 2024, month: 2, day: 10))!

        let results = [
            makeResult(id: "1", date: jan),
            makeResult(id: "2", date: jan),
            makeResult(id: "3", date: feb),
        ]

        let groups = ResultGrouper.groupByMonth(results: results)
        XCTAssertEqual(groups.count, 2)
    }

    func testNilDatesGrouped() {
        let results = [
            makeResult(id: "1", date: nil),
            makeResult(id: "2", date: nil),
        ]

        let groups = ResultGrouper.groupByMonth(results: results)
        // Nil dates should be grouped together
        XCTAssertFalse(groups.isEmpty)
    }

    func testEmptyResults() {
        let groups = ResultGrouper.groupByMonth(results: [])
        XCTAssertTrue(groups.isEmpty)
    }

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
}
