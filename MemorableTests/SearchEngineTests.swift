import XCTest
@testable import Memorable

final class SearchEngineTests: XCTestCase {

    func testVideoOnlyIndexIsLoadedAndSearchable() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertTrue(engine.isIndexLoaded)
        XCTAssertEqual(engine.indexSize, 0)
        XCTAssertEqual(engine.videoSize, 1)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertTrue(response.results[0].isVideo)
        XCTAssertEqual(response.results[0].id, "video-1")
    }

    func testPureLocationQueryReturnsVideoOnlyResults() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Paris",
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "a photo", locationHint: "Paris", hasVisualQuery: false))

        XCTAssertEqual(response.results.map(\.id), ["video-paris"])
        XCTAssertTrue(response.results[0].isVideo)
    }

    func testDateFilterExcludesVideoOnlyResult() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "old-video",
                    localIdentifier: "local-old-video",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)
        let futureRange = DateRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog", dateRange: futureRange))

        XCTAssertTrue(response.results.isEmpty)
    }

    func testNegativeTermsLowerVideoScoresWithoutGPU() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let encoder = FakeTextEncoder([
            "dog": floatVector(first: 1),
            "cat": floatVector(first: 1)
        ])
        let engine = SearchEngine(textEncoder: encoder, database: database)

        try engine.loadIndex()
        let positive = try engine.hybridSearch(hints: hints(text: "dog"))
        let negative = try engine.hybridSearch(hints: hints(text: "dog", negativeTerms: ["cat"]))

        XCTAssertEqual(positive.results.count, 1)
        XCTAssertEqual(negative.results.count, 1)
        XCTAssertLessThan(negative.results[0].score, positive.results[0].score)
    }

    func testFilteredOutPhotosStillProduceCpuFallbackResults() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)
        let futureRange = DateRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog", dateRange: futureRange))

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.map(\.id), ["photo-1"])
    }

    func testCorruptedVideoMatrixThrows() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: nil,
                    city: nil,
                    embedding: [Float16(1)]
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        XCTAssertThrowsError(try engine.loadIndex()) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
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

final class FakeTextEncoder: TextEmbeddingEncoding {
    private let embeddings: [String: [Float]]

    init(_ embeddings: [String: [Float]]) {
        self.embeddings = embeddings
    }

    func encode(text: String) throws -> [Float] {
        embeddings[text] ?? floatVector(first: 0)
    }
}

struct FixturePhoto {
    let id: String
    let localIdentifier: String
    let date: Date?
    var city: String? = nil
    let embedding: [Float16]
}

struct FixtureVideo {
    let id: String
    let localIdentifier: String
    let date: Date?
    let city: String?
    let embedding: [Float16]
}

final class SearchFixtureDatabase: DatabaseProtocol {
    var photos: [FixturePhoto]
    var videos: [FixtureVideo]

    init(photos: [FixturePhoto] = [], videos: [FixtureVideo] = []) {
        self.photos = photos
        self.videos = videos
    }

    func indexedCount() throws -> Int { photos.count }
    func videoIndexedCount() throws -> Int { Set(videos.map(\.id)).count }

    func loadAllEmbeddings() throws -> EmbeddingIndex {
        EmbeddingIndex(
            ids: photos.map(\.id),
            localIdentifiers: photos.map(\.localIdentifier),
            dates: photos.map(\.date),
            latitudes: Array<Double?>(repeating: nil, count: photos.count),
            longitudes: Array<Double?>(repeating: nil, count: photos.count),
            ocrTexts: Array<String?>(repeating: nil, count: photos.count),
            locationCities: photos.map(\.city),
            locationStates: Array<String?>(repeating: nil, count: photos.count),
            locationCountries: Array<String?>(repeating: nil, count: photos.count),
            locationNames: Array<String?>(repeating: nil, count: photos.count),
            sceneLabels: Array<String?>(repeating: nil, count: photos.count),
            embeddings: photos.flatMap(\.embedding)
        )
    }

    func loadAllVideoEmbeddings() throws -> VideoEmbeddingIndex {
        (
            videoIds: videos.map(\.id),
            localIdentifiers: videos.map(\.localIdentifier),
            dates: videos.map(\.date),
            latitudes: Array<Double?>(repeating: nil, count: videos.count),
            longitudes: Array<Double?>(repeating: nil, count: videos.count),
            framePositions: Array(repeating: 0.5, count: videos.count),
            locationCities: videos.map(\.city),
            locationStates: Array<String?>(repeating: nil, count: videos.count),
            locationCountries: Array<String?>(repeating: nil, count: videos.count),
            locationNames: Array<String?>(repeating: nil, count: videos.count),
            embeddings: videos.flatMap(\.embedding)
        )
    }

    func insertPhoto(_ photo: IndexedPhoto) throws {}
    func insertPhotos(_ photos: [IndexedPhoto]) throws {}
    func isIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedIdentifiers() throws -> Set<String> { [] }
    func allIndexedFilePaths() throws -> Set<String> { [] }
    func deleteAll() throws {}
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {}
    func fetchRandomPhoto(sharp: Bool) throws -> IndexedPhoto? { nil }
    func photosNeedingEnrichment(limit: Int) throws -> [PhotoEnrichmentCandidate] { [] }
    func photosNeedingEnrichmentCount() throws -> Int { 0 }
    func updatePhotoEnrichment(_ update: PhotoEnrichmentUpdate) throws {}
    func insertVideo(_ video: IndexedVideo) throws {}
    func insertVideoFrames(_ frames: [IndexedVideoFrame]) throws {}
    func isVideoIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedVideoIdentifiers() throws -> Set<String> { [] }
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws {}
    func trimToLimit(_ limit: Int) throws {}
    func photosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func videosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func photosNeedingLocationBackfillCount() throws -> Int { 0 }
    func videosNeedingLocationBackfillCount() throws -> Int { 0 }
    func photosWithGPSCount() throws -> Int { 0 }
    func videosWithGPSCount() throws -> Int { 0 }
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func insertSource(_ source: PhotoSource) throws {}
    func listSources() throws -> [PhotoSource] { [] }
    func deleteSource(_ id: String) throws {}
    func updateSourceStats(_ id: String, photoCount: Int) throws {}
    func onThisDayPhotos() throws -> [(year: Int, ids: [String])] { [] }
    func addSearchHistory(_ query: String) throws {}
    func loadSearchHistory() throws -> [String] { [] }
    func clearSearchHistory() throws {}
    func removeSearchHistory(at index: Int) throws {}
    func loadSmartAlbums() throws -> [SmartAlbum] { [] }
    func saveSmartAlbum(_ album: SmartAlbum) throws {}
    func deleteSmartAlbum(id: String) throws {}
}

func floatVector(first: Float = 0, second: Float = 0) -> [Float] {
    var values = [Float](repeating: 0, count: EmbeddingConfig.dimensions)
    values[0] = first
    values[1] = second
    return values
}

func float16Vector(first: Float = 0, second: Float = 0) -> [Float16] {
    let floatValues = floatVector(first: first, second: second)
    return floatValues.map(Float16.init)
}
