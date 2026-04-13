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

    func testTimeOfDayBoostPositive() {
        XCTAssertGreaterThan(SearchConfig.timeOfDayMatchBoost, 0.0,
            "Time-of-day additive boost should be positive")
    }

    func testLocationBoostsArePositive() {
        XCTAssertGreaterThan(SearchConfig.locationCloseBoost, 0.0)
        XCTAssertGreaterThan(SearchConfig.locationNearBoost, 0.0)
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

    func testSceneLabelBoostPositive() {
        XCTAssertGreaterThan(SearchConfig.sceneLabelBoostPerMatch, 0)
    }

    func testVideoCompensationPositive() {
        XCTAssertGreaterThan(SearchConfig.videoRelevanceCompensation, 0)
    }

    // MARK: - SigLIP2 Score Range Consistency

    func testThresholdInSigLIP2Range() {
        // SigLIP2 (sigmoid loss) matching pairs typically score 0.10-0.25.
        // Threshold must be low enough to catch valid matches.
        XCTAssertLessThanOrEqual(SearchConfig.minimumScoreThreshold, 0.15,
            "Threshold must accommodate SigLIP2's lower score range")
    }

    func testBoostsProportionalToThreshold() {
        // Additive boosts should not individually exceed the minimum threshold,
        // otherwise a single boost could push an irrelevant result over threshold.
        let threshold = SearchConfig.minimumScoreThreshold
        XCTAssertLessThan(SearchConfig.locationCloseBoost, threshold,
            "Location boost should not alone push a result over threshold")
        XCTAssertLessThan(SearchConfig.timeOfDayMatchBoost, threshold,
            "Time-of-day boost should not alone push a result over threshold")
        XCTAssertLessThan(SearchConfig.ocrBoostPerWord, threshold,
            "OCR boost should not alone push a result over threshold")
        XCTAssertLessThan(SearchConfig.sceneLabelBoostPerMatch, threshold,
            "Scene label boost should not alone push a result over threshold")
        XCTAssertLessThan(SearchConfig.videoRelevanceCompensation, threshold,
            "Video compensation should not alone push a result over threshold")
    }
}
