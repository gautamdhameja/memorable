import CoreLocation
import XCTest
@testable import Memorable

final class SearchConfigTests: XCTestCase {

    func testReverseGeocoderCacheHasAFixedMemoryBound() {
        XCTAssertGreaterThan(ReverseGeocoder.cacheEntryLimit, 0)
        XCTAssertLessThanOrEqual(ReverseGeocoder.cacheEntryLimit, 4_096)
    }

    func testLocationCoordinatePolicyRejectsMalformedGPS() {
        XCTAssertTrue(LocationCoordinatePolicy.isValid(latitude: 90, longitude: 180))
        XCTAssertFalse(LocationCoordinatePolicy.isValid(latitude: .nan, longitude: 0))
        XCTAssertFalse(LocationCoordinatePolicy.isValid(latitude: .infinity, longitude: 0))
        XCTAssertFalse(LocationCoordinatePolicy.isValid(latitude: 90.01, longitude: 0))
        XCTAssertFalse(LocationCoordinatePolicy.isValid(latitude: 0, longitude: -180.01))
        XCTAssertFalse(LocationCoordinatePolicy.isValidOrAbsent(latitude: 1, longitude: nil))
    }

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

    func testDuplicateFinderBoundsDenseMatchResultsDeterministically() {
        let count = 70
        let ids = (0..<count).map { "photo-\($0)" }
        let localIDs = (0..<count).map { "local-\($0)" }
        let embeddings = [Float16](repeating: 1, count: count)

        let first = DuplicateFinder.findDuplicates(
            ids: ids,
            localIdentifiers: localIDs,
            embeddings: embeddings,
            embeddingDim: 1,
            threshold: 0.5,
            featurePolicy: .pro
        )
        let second = DuplicateFinder.findDuplicates(
            ids: ids,
            localIdentifiers: localIDs,
            embeddings: embeddings,
            embeddingDim: 1,
            threshold: 0.5,
            featurePolicy: .pro
        )

        XCTAssertEqual(first.count, DuplicateFinder.maximumRetainedPairs)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(zip(first, first.dropFirst()).allSatisfy { $0.similarity >= $1.similarity })
    }

    func testDuplicateFinderDefaultsToFreePolicyAndReturnsNoResults() {
        let results = DuplicateFinder.findDuplicates(
            ids: ["first", "second"],
            localIdentifiers: ["local-first", "local-second"],
            embeddings: [1, 1],
            embeddingDim: 1,
            threshold: 0.5
        )

        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testReverseGeocoderCancelsSubmittedRequestWithParentTask() async {
        let backend = BlockingLocationGeocoder()
        let reverseGeocoder = ReverseGeocoder(
            geocoder: backend,
            throttleNanoseconds: 0
        )
        let task = Task {
            await reverseGeocoder.reverseGeocode(latitude: 37.3317, longitude: -122.0301)
        }

        for _ in 0..<2_000 where !backend.hasStarted {
            await Task.yield()
        }
        XCTAssertTrue(backend.hasStarted)
        task.cancel()
        _ = await task.value

        XCTAssertEqual(backend.cancelCount, 1)
    }
}

@MainActor
private final class BlockingLocationGeocoder: LocationGeocoding {
    private(set) var hasStarted = false
    private(set) var cancelCount = 0
    private var continuation: CheckedContinuation<[CLPlacemark], Error>?

    func reverseGeocode(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> [CLPlacemark] {
        hasStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
