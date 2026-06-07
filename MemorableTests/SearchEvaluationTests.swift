import XCTest
@testable import Memorable

final class SearchEvaluationTests: XCTestCase {

    func testVisualQueryRanksIntendedPhotoAboveDistractor() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(id: "dog", localIdentifier: "local-dog", date: nil, embedding: float16Vector(first: 1)),
            .init(id: "cat", localIdentifier: "local-cat", date: nil, embedding: float16Vector(second: 1)),
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.first?.id, "dog")
    }

    func testDateFilterExcludesOutOfRangeMedia() throws {
        let inRange = Date(timeIntervalSince1970: 1_000)
        let outOfRange = Date(timeIntervalSince1970: 10_000)
        let database = SearchFixtureDatabase(photos: [
            .init(id: "in-range", localIdentifier: "local-in", date: inRange, embedding: float16Vector(first: 1)),
            .init(id: "out-of-range", localIdentifier: "local-out", date: outOfRange, embedding: float16Vector(first: 1)),
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)
        let range = DateRange(start: Date(timeIntervalSince1970: 500), end: Date(timeIntervalSince1970: 2_000))

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog", dateRange: range))

        XCTAssertEqual(response.results.map(\.id), ["in-range"])
    }

    func testLocationOnlyQueryReturnsMetadataMatchesWithoutVisualScoring() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(id: "paris", localIdentifier: "local-paris", date: nil, city: "Paris", embedding: float16Vector(second: 1)),
            .init(id: "berlin", localIdentifier: "local-berlin", date: nil, city: "Berlin", embedding: float16Vector(first: 1)),
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["Paris": floatVector(first: 0)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "Paris", locationHint: "Paris", hasVisualQuery: false))

        XCTAssertEqual(response.results.map(\.id), ["paris"])
    }

    func testMixedVisualLocationKeepsFallbackWhenVisualScoreIsSparse() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(id: "berlin-distractor", localIdentifier: "local-berlin", date: nil, city: "Berlin", embedding: float16Vector(second: 1)),
            .init(id: "paris-dog", localIdentifier: "local-paris", date: nil, city: "Paris", embedding: float16Vector(first: 1)),
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog", locationHint: "Berlin"))

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.map(\.id), ["berlin-distractor"])
    }

    func testNegativeTermLowersMatchingNegativeResult() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(id: "dog", localIdentifier: "local-dog", date: nil, embedding: float16Vector(first: 1)),
        ])
        let encoder = FakeTextEncoder([
            "dog": floatVector(first: 1),
            "cat": floatVector(first: 1),
        ])
        let engine = SearchEngine(textEncoder: encoder, database: database)

        try engine.loadIndex()
        let positive = try engine.hybridSearch(hints: hints(text: "dog"))
        let negative = try engine.hybridSearch(hints: hints(text: "dog", negativeTerms: ["cat"]))

        XCTAssertLessThan(negative.results[0].score, positive.results[0].score)
    }

    func testVideoKeepsBestFramePerVideo() throws {
        let database = SearchFixtureDatabase(videos: [
            .init(id: "video", localIdentifier: "local-video", date: nil, city: nil, embedding: float16Vector(first: 0.5)),
            .init(id: "video", localIdentifier: "local-video", date: nil, city: nil, embedding: float16Vector(first: 1)),
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].id, "video")
    }

    func testVideoCompensationCanLiftNearThresholdFrameIntoResults() throws {
        let database = SearchFixtureDatabase(videos: [
            .init(
                id: "near-threshold-video",
                localIdentifier: "local-near-threshold-video",
                date: nil,
                city: nil,
                embedding: float16Vector(first: 0.10)
            )
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog eating carrot": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog eating carrot"))

        XCTAssertEqual(response.results.map(\.id), ["near-threshold-video"])
        XCTAssertTrue(response.fallbackResults.isEmpty)
    }

    func testSingleSceneLabelDoesNotBuryStrongerVideoForCompoundQuery() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "generic-dog-photo",
                    localIdentifier: "local-generic-dog-photo",
                    date: nil,
                    sceneLabels: "dog",
                    embedding: float16Vector(first: 0.13)
                )
            ],
            videos: [
                .init(
                    id: "dog-eating-carrot-video",
                    localIdentifier: "local-dog-eating-carrot-video",
                    date: nil,
                    city: nil,
                    embedding: float16Vector(first: 0.125)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog eating carrot": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog eating carrot"))

        XCTAssertEqual(response.results.first?.id, "dog-eating-carrot-video")
    }

    func testEmptyResultFixtureReturnsNoMainResults() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(id: "cat", localIdentifier: "local-cat", date: nil, embedding: float16Vector(second: 1)),
        ])
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertTrue(response.results.isEmpty)
    }

    private func hints(
        text: String,
        dateRange: DateRange? = nil,
        locationHint: String? = nil,
        hasVisualQuery: Bool = true,
        negativeTerms: [String] = []
    ) -> QueryHints {
        QueryHints(
            textQuery: text,
            dateRange: dateRange,
            locationHint: locationHint,
            locationCoordinate: nil,
            locationRadiusKm: nil,
            locationLocality: nil,
            locationSubAdmin: nil,
            locationAdminArea: nil,
            locationCountryName: nil,
            seasonHint: nil,
            negativeTerms: negativeTerms,
            timeOfDayHours: nil,
            hasVisualQuery: hasVisualQuery
        )
    }
}
