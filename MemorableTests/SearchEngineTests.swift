import XCTest
@testable import Memorable

final class SearchEngineTests: XCTestCase {

    func testMediaIndexRejectsMismatchedColumnLengths() throws {
        XCTAssertThrowsError(
            try MediaIndex(
                kind: .photo,
                ids: ["photo-1"],
                localIdentifiers: [],
                dates: [nil],
                latitudes: [nil],
                longitudes: [nil],
                ocrTexts: [nil],
                locationCities: [nil],
                locationStates: [nil],
                locationCountries: [nil],
                locationNames: [nil],
                sceneLabels: [nil],
                framePositions: [nil],
                embeddings: float16Vector(first: 1)
            )
        ) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testMediaIndexCompleteAppendKeepsEveryColumnAligned() throws {
        var index = MediaIndex(kind: .photo)
        try index.append(
            MediaIndex.Row(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: Date(timeIntervalSince1970: 100),
                latitude: 1,
                longitude: 2,
                city: "Paris",
                state: "Ile-de-France",
                country: "France",
                locationName: "Eiffel Tower",
                details: .photo(ocrText: "sign", sceneLabels: "tower")
            ),
            embedding: float16Vector(first: 1)
        )

        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.ids, ["photo-1"])
        XCTAssertEqual(index.localIdentifiers, ["local-photo-1"])
        XCTAssertEqual(index.dates.count, index.count)
        XCTAssertEqual(index.latitudes, [1])
        XCTAssertEqual(index.longitudes, [2])
        XCTAssertEqual(index.ocrTexts, ["sign"])
        XCTAssertEqual(index.locationCities, ["Paris"])
        XCTAssertEqual(index.locationStates, ["Ile-de-France"])
        XCTAssertEqual(index.locationCountries, ["France"])
        XCTAssertEqual(index.locationNames, ["Eiffel Tower"])
        XCTAssertEqual(index.sceneLabels, ["tower"])
        XCTAssertEqual(index.framePositions, [nil])
        XCTAssertEqual(index.embeddings.count, EmbeddingConfig.dimensions)
        XCTAssertEqual(index.embeddings[0], 1)
    }

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

    func testLocationQueryRetainsVideoWithGPSButNoStoredCityWithoutCoordinateHint() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-awaiting-geocode",
                    localIdentifier: "local-video-awaiting-geocode",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    latitude: 48.8566,
                    longitude: 2.3522,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(text: "a photo", locationHint: "Paris", hasVisualQuery: false)
        )

        XCTAssertEqual(response.results.map(\.id), ["video-awaiting-geocode"])
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

    func testPhotoAndVideoRowsShareCommonFilterAndScoringPath() throws {
        let date = Date(timeIntervalSince1970: 10_000)
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-paris",
                    localIdentifier: "local-photo-paris",
                    date: date,
                    city: "Paris",
                    embedding: float16Vector(first: 1)
                )
            ],
            videos: [
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: date,
                    city: "Paris",
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "dog": floatVector(first: 0.3),
                "cat": floatVector(first: 0.1),
            ]),
            database: database
        )
        let dateRange = DateRange(
            start: date.addingTimeInterval(-1),
            end: date.addingTimeInterval(1)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(
            text: "dog",
            dateRange: dateRange,
            locationHint: "Paris",
            negativeTerms: ["cat"],
            timeOfDayHours: (0, 24)
        ))

        XCTAssertEqual(Set(response.results.map(\.id)), ["photo-paris", "video-paris"])
        let photoScore = try XCTUnwrap(response.results.first { !$0.isVideo }?.score)
        let videoScore = try XCTUnwrap(response.results.first { $0.isVideo }?.score)
        XCTAssertEqual(
            videoScore - photoScore,
            SearchConfig.videoRelevanceCompensation,
            accuracy: 0.0001
        )
    }

    func testMultiFrameVideoKeepsBestFramePosition() throws {
        let database = SearchFixtureDatabase(videos: [
            .init(
                id: "video",
                localIdentifier: "local-video",
                date: nil,
                city: nil,
                framePosition: 0.1,
                embedding: float16Vector(first: 0.5)
            ),
            .init(
                id: "video",
                localIdentifier: "local-video",
                date: nil,
                city: nil,
                framePosition: 0.9,
                embedding: float16Vector(first: 1)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].id, "video")
        XCTAssertEqual(response.results[0].bestFramePosition, 0.9)
    }

    func testNegativeTermsUseMatrixScorerForPhotosAndVideos() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 1)
                )
            ],
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
        let photoScorer = RecordingSimilaritySearch()
        let videoScorer = RecordingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "dog": floatVector(first: 0.8),
                "cat": floatVector(first: 0.4)
            ]),
            database: database,
            photoSimilaritySearch: photoScorer,
            videoSimilaritySearch: videoScorer
        )

        try engine.loadIndex()
        _ = try engine.hybridSearch(hints: hints(text: "dog", negativeTerms: ["cat"]))

        XCTAssertEqual(photoScorer.queries.map { $0[0] }, [0.8, 0.4])
        XCTAssertEqual(videoScorer.queries.map { $0[0] }, [0.8, 0.4])
    }

    func testInjectedVideoScorerIsAvailableWhenVideosAppearAfterReload() throws {
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
        let videoScorer = RecordingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "dog": floatVector(first: 0.8),
                "cat": floatVector(first: 0.4)
            ]),
            database: database,
            videoSimilaritySearch: videoScorer
        )

        try engine.loadIndex()
        database.videos = [
            .init(
                id: "video-1",
                localIdentifier: "local-video-1",
                date: Date(timeIntervalSince1970: 100),
                city: nil,
                embedding: float16Vector(first: 1)
            )
        ]
        try engine.loadIndex()
        _ = try engine.hybridSearch(hints: hints(text: "dog", negativeTerms: ["cat"]))

        XCTAssertEqual(videoScorer.queries.map { $0[0] }, [0.8, 0.4])
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
        negativeTerms: [String] = [],
        timeOfDayHours: (start: Int, end: Int)? = nil
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
            timeOfDayHours: timeOfDayHours,
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

final class RecordingSimilaritySearch: SimilaritySearching {
    private var count = 0
    private(set) var queries: [[Float]] = []

    func buildIndex(embeddings: [Float16], count: Int) {
        self.count = count
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        queries.append(queryEmbedding)
        return Array(repeating: queryEmbedding.first ?? 0, count: count)
    }
}

struct FixturePhoto {
    let id: String
    let localIdentifier: String
    let date: Date?
    var city: String? = nil
    var sceneLabels: String? = nil
    let embedding: [Float16]
}

struct FixtureVideo {
    let id: String
    let localIdentifier: String
    let date: Date?
    let city: String?
    var latitude: Double? = nil
    var longitude: Double? = nil
    var framePosition: Double = 0.5
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
    func indexedMediaCounts() throws -> IndexedMediaCounts {
        IndexedMediaCounts(photos: photos.count, videos: Set(videos.map(\.id)).count)
    }
    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers {
        IndexedMediaIdentifiers(
            photos: Set(photos.map(\.localIdentifier)),
            videos: Set(videos.map(\.localIdentifier))
        )
    }

    func loadAllEmbeddings() throws -> MediaIndex {
        var index = MediaIndex(kind: .photo)
        for photo in photos {
            try index.append(
                MediaIndex.Row(
                    id: photo.id,
                    localIdentifier: photo.localIdentifier,
                    date: photo.date,
                    latitude: nil,
                    longitude: nil,
                    city: photo.city,
                    state: nil,
                    country: nil,
                    locationName: nil,
                    details: .photo(ocrText: nil, sceneLabels: photo.sceneLabels)
                ),
                embedding: photo.embedding
            )
        }
        return index
    }

    func loadAllVideoEmbeddings() throws -> MediaIndex {
        var index = MediaIndex(kind: .videoFrame)
        for video in videos {
            try index.append(
                MediaIndex.Row(
                    id: video.id,
                    localIdentifier: video.localIdentifier,
                    date: video.date,
                    latitude: video.latitude,
                    longitude: video.longitude,
                    city: video.city,
                    state: nil,
                    country: nil,
                    locationName: nil,
                    details: .videoFrame(position: video.framePosition)
                ),
                embedding: video.embedding
            )
        }
        return index
    }

    func insertPhoto(_ photo: IndexedPhoto) throws {}
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool { false }
    func isIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedIdentifiers() throws -> Set<String> { [] }
    func allIndexedFilePaths() throws -> Set<String> { [] }
    func deleteAll() throws {}
    func deletePhoto(localIdentifier: String) throws {}
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {}
    func fetchRandomPhoto(sharp: Bool) throws -> IndexedPhoto? { nil }
    func photosNeedingEnrichment(limit: Int) throws -> [PhotoEnrichmentCandidate] { [] }
    func photosNeedingEnrichmentCount() throws -> Int { 0 }
    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws {}
    func indexRebuildRequired() throws -> Bool { false }
    func clearIndexRebuildRequired() throws {}
    func insertVideo(
        _ video: IndexedVideo,
        _ frames: [IndexedVideoFrame],
        completingRequiredRebuild: Bool
    ) throws -> Bool { false }
    func isVideoIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedVideoIdentifiers() throws -> Set<String> { [] }
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws {}
    func trimToLimit(_ limit: Int) throws {}
    func photosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func videosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func geocodingCounts() throws -> GeocodingCounts {
        GeocodingCounts(totalWithGPS: 0, remaining: 0, indexedPhotos: photos.count, indexedVideos: videos.count)
    }
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
