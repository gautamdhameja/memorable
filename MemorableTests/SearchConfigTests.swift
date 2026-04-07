import XCTest
@testable import Memorable

final class SearchConfigTests: XCTestCase {

    // MARK: - Threshold Sanity

    func testMinimumScoreThreshold() {
        XCTAssertGreaterThan(SearchConfig.minimumScoreThreshold, 0)
        XCTAssertLessThan(SearchConfig.minimumScoreThreshold, 1.0)
    }

    func testDuplicateThreshold() {
        XCTAssertGreaterThan(SearchConfig.duplicateThreshold, SearchConfig.minimumScoreThreshold,
            "Duplicate threshold must be higher than search threshold")
        XCTAssertLessThanOrEqual(SearchConfig.duplicateThreshold, 1.0)
    }

    // MARK: - Boost Values

    func testTimeOfDayBoostGreaterThanOne() {
        XCTAssertGreaterThan(SearchConfig.timeOfDayMatchBoost, 1.0,
            "Time-of-day match should boost, not penalize")
    }

    func testLocationBoostsArePositive() {
        XCTAssertGreaterThan(SearchConfig.locationCloseBoost, 1.0)
        XCTAssertGreaterThan(SearchConfig.locationNearBoost, 1.0)
        XCTAssertGreaterThan(SearchConfig.locationCloseBoost, SearchConfig.locationNearBoost,
            "Closer location should get higher boost")
    }

    func testNegativeTermWeightPositive() {
        XCTAssertGreaterThan(SearchConfig.negativeTermWeight, 0)
        XCTAssertLessThan(SearchConfig.negativeTermWeight, 1.0,
            "Negative term weight should be moderate, not total elimination")
    }

    func testOCRBoostPositive() {
        XCTAssertGreaterThan(SearchConfig.ocrBoostPerWord, 0)
    }
}
