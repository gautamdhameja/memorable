import XCTest
import os
@testable import Memorable

final class SearchEngineTests: XCTestCase {

    func testBoundedTopKMatchesDeterministicFullOrdering() throws {
        let candidates = (0..<1_000).map { index in
            SearchResult(
                id: "id-\(index)",
                score: Float(index % 17),
                localIdentifier: String(format: "local-%04d", 1_000 - index),
                creationDate: Date(timeIntervalSince1970: TimeInterval(index % 23)),
                isVideo: index.isMultiple(of: 2),
                bestFramePosition: nil
            )
        }
        let expected = Array(
            candidates.sorted(by: SearchResultRanking.isPreferred).prefix(50)
        )

        let actual = try BoundedTopK.select(
            from: candidates,
            limit: 50,
            isPreferred: SearchResultRanking.isPreferred
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 50)
        XCTAssertTrue(zip(actual, actual.dropFirst()).allSatisfy {
            SearchResultRanking.isPreferred($0, $1)
        })
    }

    func testSearchResultRankingIsTransitiveForScoreDateAndIdentifierTies() {
        let highestScore = SearchResult(
            id: "highest", score: 0.9, localIdentifier: "z",
            creationDate: Date(timeIntervalSince1970: 1), isVideo: false, bestFramePosition: nil
        )
        let newerDate = SearchResult(
            id: "newer", score: 0.8, localIdentifier: "z",
            creationDate: Date(timeIntervalSince1970: 2), isVideo: false, bestFramePosition: nil
        )
        let earlierIdentifier = SearchResult(
            id: "identifier-a", score: 0.8, localIdentifier: "a",
            creationDate: Date(timeIntervalSince1970: 2), isVideo: false, bestFramePosition: nil
        )

        XCTAssertTrue(SearchResultRanking.isPreferred(highestScore, newerDate))
        XCTAssertTrue(SearchResultRanking.isPreferred(earlierIdentifier, newerDate))
        XCTAssertTrue(SearchResultRanking.isPreferred(highestScore, earlierIdentifier))
        XCTAssertFalse(SearchResultRanking.isPreferred(newerDate, earlierIdentifier))
    }

    func testResultOrderingUsesAStrictScoreOrderBeforeTieBreakers() {
        let newestLowerScore = SearchResult(
            id: "lower",
            score: 0.995,
            localIdentifier: "lower",
            creationDate: Date(timeIntervalSince1970: 300),
            isVideo: false,
            bestFramePosition: nil
        )
        let middle = SearchResult(
            id: "middle",
            score: 1,
            localIdentifier: "middle",
            creationDate: Date(timeIntervalSince1970: 200),
            isVideo: false,
            bestFramePosition: nil
        )
        let oldestHighestScore = SearchResult(
            id: "highest",
            score: 1.005,
            localIdentifier: "highest",
            creationDate: Date(timeIntervalSince1970: 100),
            isVideo: false,
            bestFramePosition: nil
        )

        let sorted = [newestLowerScore, middle, oldestHighestScore]
            .sorted(by: SearchResultRanking.isPreferred)

        XCTAssertEqual(sorted.map(\.id), ["highest", "middle", "lower"])
    }

    func testSearchResultsAreBoundedAndDeterministicallyOrdered() throws {
        let photos = (0..<(SearchEngine.maximumRetainedResults + 25)).map { index in
            FixturePhoto(
                id: String(format: "photo-%04d", index),
                localIdentifier: String(format: "local-%04d", index),
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                embedding: float16Vector(first: 1)
            )
        }
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: photos)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.count, SearchEngine.maximumRetainedResults)
        XCTAssertEqual(response.results.first?.id, "photo-0524")
        XCTAssertEqual(response.results.last?.id, "photo-0025")
    }

    func testSearchRejectsShortQueryEmbeddingBeforeSimilarityScoring() throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": [1]]),
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ])
        )
        try engine.loadIndex()

        XCTAssertThrowsError(try engine.hybridSearch(hints: hints(text: "dog"))) { error in
            XCTAssertEqual(error as? SearchEngineError, .invalidEmbedding)
        }
    }

    func testMemoryPressureSuspendsIndexReloadUntilExplicitResume() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        XCTAssertTrue(engine.isIndexLoaded)

        engine.suspendForMemoryPressure()
        try engine.loadIndex()
        XCTAssertFalse(engine.isIndexLoaded)
        XCTAssertTrue(engine.isMemoryPressureSuspended)

        engine.resumeAfterMemoryPressure()
        try engine.loadIndex()
        XCTAssertTrue(engine.isIndexLoaded)
        XCTAssertFalse(engine.isMemoryPressureSuspended)
    }

    func testConcurrentIndexReloadsShareOneDatabaseLoad() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 1
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        let firstLoad = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)
        let secondLoad = Task.detached { try engine.loadIndex() }

        for _ in 0..<20 where database.photoLoadCount < 2 {
            await Task.yield()
        }
        loadGate.open()

        try await firstLoad.value
        try await secondLoad.value
        XCTAssertEqual(database.photoLoadCount, 1)
        XCTAssertEqual(database.videoLoadCount, 1)
        XCTAssertEqual(engine.indexSize, 1)
    }

    func testConcurrentSearchWaitsForBoundedReloadAndUsesReplacement() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 2
        )
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()
        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .idle,
                residentMediaCount: 1,
                ownsPhotoAccelerator: true,
                ownsVideoAccelerator: false
            )
        )

        database.photos = [
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ]

        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .loadingResidentData,
                residentMediaCount: 1,
                ownsPhotoAccelerator: false,
                ownsVideoAccelerator: false
            )
        )

        let queryHints = hints(text: "dog")
        let search = Task.detached {
            try engine.hybridSearch(hints: queryHints)
        }
        XCTAssertEqual(
            scorer.searchStarted.wait(timeout: .now() + 0.05),
            .timedOut,
            "A search must not retain the old snapshot during replacement construction"
        )

        loadGate.open()
        try await reload.value
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        scorer.resumeSearch.signal()
        let response = try await search.value

        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(response.results.map(\.id), ["photo-2"])
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)
    }

    func testReloadDrainsActiveSearchBeforeRetiringAccelerator() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 2
        )
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        let queryHints = hints(text: "dog")
        let search = Task.detached {
            try engine.hybridSearch(hints: queryHints)
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)

        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(
            loadGate.started.wait(timeout: .now() + 0.05),
            .timedOut,
            "Replacement allocation must wait for the active snapshot reader"
        )
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)

        scorer.resumeSearch.signal()
        _ = try await search.value
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .loadingResidentData)
        XCTAssertFalse(engine.indexMemoryState.ownsPhotoAccelerator)

        loadGate.open()
        try await reload.value
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)
    }

    func testFailedReloadKeepsPreviouslyServingSnapshot() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: RecordingSimilaritySearch()
        )
        try engine.loadIndex()
        database.photos = [
            .init(
                id: "corrupt",
                localIdentifier: "corrupt",
                date: nil,
                embedding: [1]
            )
        ]

        XCTAssertThrowsError(try engine.loadIndex())
        XCTAssertTrue(engine.isIndexLoaded)
        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertFalse(
            engine.indexMemoryState.ownsPhotoAccelerator,
            "A failed reload keeps the old CPU fallback without retaining the old GPU generation"
        )
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-1"]
        )
    }

    func testCancelledReloadKeepsOldCPUFallbackAndReturnsToIdle() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 2
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: RecordingSimilaritySearch()
        )
        try engine.loadIndex()

        database.photos = [
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ]
        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)
        reload.cancel()
        loadGate.open()

        do {
            try await reload.value
            XCTFail("A canceled reload must report cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .idle,
                residentMediaCount: 1,
                ownsPhotoAccelerator: false,
                ownsVideoAccelerator: false
            )
        )
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-1"]
        )
    }

    func testResidentDataInstallsBeforeReplacementAcceleratorBuild() async throws {
        let buildGate = ManualResetLoadGate()
        let scorer = GatedBuildSimilaritySearch(
            buildGate: buildGate,
            gatedBuildNumber: 2
        )
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        database.photos = [
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ]
        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(buildGate.started.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .buildingAccelerators,
                residentMediaCount: 1,
                ownsPhotoAccelerator: false,
                ownsVideoAccelerator: false
            )
        )
        XCTAssertEqual(
            scorer.indexedCount,
            0,
            "The previous accelerator buffer must be cleared before replacement allocation"
        )

        buildGate.open()
        try await reload.value
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-2"]
        )
    }

    func testCancelledSearchStopsAfterSimilarityScoring() async throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()
        let searchHints = hints(text: "dog")

        let search = Task.detached {
            try engine.hybridSearch(hints: searchHints).results.count
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        search.cancel()
        scorer.resumeSearch.signal()

        do {
            _ = try await search.value
            XCTFail("A canceled search must not continue ranking its retained index snapshot")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testMemoryPressureStopsSearchRetainingOldSnapshot() async throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        let searchHints = hints(text: "dog")
        let search = Task.detached {
            try engine.hybridSearch(hints: searchHints).results.count
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        engine.suspendForMemoryPressure()
        scorer.resumeSearch.signal()

        do {
            _ = try await search.value
            XCTFail("Memory pressure must stop a search retaining the old index snapshot")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(engine.isIndexLoaded)
        XCTAssertTrue(engine.isMemoryPressureSuspended)
    }

    func testCancelledFindSimilarStopsAfterSimilarityScoring() async throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        let search = Task.detached {
            engine.findSimilar(photoId: "photo-1").count
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        search.cancel()
        scorer.resumeSearch.signal()

        let resultCount = await search.value
        XCTAssertEqual(resultCount, 0)
    }

    @MainActor
    func testExistingSearchWarmupRecoversAfterMemoryPressure() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )
        engine.suspendForMemoryPressure()

        AppState.resumeExistingSearchForWarmup(engine)
        try engine.loadIndex()

        XCTAssertFalse(engine.isMemoryPressureSuspended)
        XCTAssertTrue(engine.isIndexLoaded)
    }

    func testMediaIndexRejectsMismatchedColumnLengths() throws {
        XCTAssertThrowsError(
            try MediaIndex(
                kind: .photo,
                ids: ["photo-1"],
                localIdentifiers: [],
                sourceIds: [PhotoSourceType.photokit.rawValue],
                filePaths: [nil],
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
                sourceId: "folder-source",
                filePath: "/folder/photo.jpg",
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
        XCTAssertEqual(index.sourceIds, ["folder-source"])
        XCTAssertEqual(index.filePaths, ["/folder/photo.jpg"])
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

    func testFolderSourceMetadataPropagatesIntoSearchResult() throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "folder:source-1:photo.jpg",
                    date: nil,
                    sourceId: "source-1",
                    filePath: "/selected/photo.jpg",
                    embedding: float16Vector(first: 1)
                )
            ])
        )

        try engine.loadIndex()
        let result = try XCTUnwrap(engine.hybridSearch(hints: hints(text: "dog")).results.first)

        XCTAssertEqual(result.sourceId, "source-1")
        XCTAssertEqual(result.filePath, "/selected/photo.jpg")
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

    func testVideoOnlyNearMissAppearsInFallback() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-near-miss",
                    localIdentifier: "local-video-near-miss",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 0.05)
                )
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.map(\.id), ["video-near-miss"])
    }

    func testPureLocationQueryReturnsVideoOnlyResults() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Paris",
                    framePosition: 0.2,
                    embedding: float16Vector(first: 1)
                ),
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Paris",
                    framePosition: 0.8,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(text: "a photo", locationHint: "Paris", hasVisualQuery: false),
            featurePolicy: .pro
        )

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
            hints: hints(text: "a photo", locationHint: "Paris", hasVisualQuery: false),
            featurePolicy: .pro
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
        let response = try engine.hybridSearch(
            hints: hints(text: "dog", dateRange: futureRange),
            featurePolicy: .pro
        )

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
        let basicNegative = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .basic
        )
        let negative = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .pro
        )

        XCTAssertEqual(positive.results.count, 1)
        XCTAssertEqual(basicNegative.results.map(\.score), positive.results.map(\.score))
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
        let response = try engine.hybridSearch(
            hints: hints(
                text: "dog",
                dateRange: dateRange,
                locationHint: "Paris",
                negativeTerms: ["cat"],
                timeOfDayHours: (0, 24)
            ),
            featurePolicy: .pro
        )

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
        _ = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .pro
        )

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
        _ = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .pro
        )

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
        let response = try engine.hybridSearch(
            hints: hints(text: "dog", dateRange: futureRange),
            featurePolicy: .pro
        )

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

    func testWholeLibrarySearchFindsBestResultAfterResidentPage() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.01)
            ),
            .init(
                id: "page-2-match",
                localIdentifier: "page-2-match",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(engine.residentSize, 1)
        XCTAssertEqual(engine.totalSize, 2)
        XCTAssertEqual(response.results.first?.id, "page-2-match")
    }

    func testFindSimilarPagesWhenSourceAndMatchAreOutsideResidentWindow() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 300),
                embedding: float16Vector(second: 1)
            ),
            .init(
                id: "source",
                localIdentifier: "source",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "page-3-match",
                localIdentifier: "page-3-match",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([:]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let results = engine.findSimilar(photoId: "source")

        XCTAssertEqual(results.map(\.id), ["page-3-match"])
    }

    func testPagedSearchGloballyOrdersAndDeduplicatesVideoFrames() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "resident-photo",
                    localIdentifier: "resident-photo",
                    date: Date(timeIntervalSince1970: 300),
                    embedding: float16Vector(first: 0.8)
                ),
                .init(
                    id: "older-photo",
                    localIdentifier: "older-photo",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 0.85)
                ),
            ],
            videos: [
                .init(
                    id: "video",
                    localIdentifier: "video",
                    date: Date(timeIntervalSince1970: 200),
                    city: nil,
                    framePosition: 0.2,
                    embedding: float16Vector(first: 0.5)
                ),
                .init(
                    id: "video",
                    localIdentifier: "video",
                    date: Date(timeIntervalSince1970: 200),
                    city: nil,
                    framePosition: 0.8,
                    embedding: float16Vector(first: 0.9)
                ),
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.map(\.id), ["video", "older-photo", "resident-photo"])
        XCTAssertEqual(response.results.filter(\.isVideo).count, 1)
        XCTAssertEqual(response.results.first?.bestFramePosition, 0.8)
    }

    func testAdaptiveFallbackClusterIsFinalizedAcrossAllPages() throws {
        let database = SearchFixtureDatabase(photos: (1...3).map { number in
            FixturePhoto(
                id: "photo-\(number)",
                localIdentifier: "photo-\(number)",
                date: Date(timeIntervalSince1970: TimeInterval(400 - number)),
                embedding: float16Vector(first: 0.1)
            )
        })
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["abstract": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "abstract"))

        XCTAssertEqual(response.results.count, 3)
        XCTAssertTrue(response.fallbackResults.isEmpty)
    }

    func testMemoryPressureCancelsSearchWhileLoadingLaterPage() async throws {
        let pageGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "resident",
                    localIdentifier: "resident",
                    date: Date(timeIntervalSince1970: 200),
                    embedding: float16Vector(first: 0.8)
                ),
                .init(
                    id: "page-2",
                    localIdentifier: "page-2",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 0.9)
                ),
            ],
            photoLoadGate: pageGate,
            gatedPhotoLoadNumber: 2
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )
        try engine.loadIndex()

        let queryHints = hints(text: "dog")
        let search = Task.detached {
            try engine.hybridSearch(hints: queryHints)
        }
        XCTAssertEqual(pageGate.started.wait(timeout: .now() + 1), .success)
        engine.suspendForMemoryPressure()
        pageGate.open()

        do {
            _ = try await search.value
            XCTFail("Memory pressure must cancel a paged search")
        } catch is CancellationError {
            // Expected.
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
    private struct State: Sendable {
        var count = 0
        var queries: [[Float]] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var queries: [[Float]] {
        state.withLock { $0.queries }
    }

    func buildIndex(embeddings: [Float16], count: Int) {
        state.withLock { $0.count = count }
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        state.withLock {
            $0.queries.append(queryEmbedding)
            return Array(repeating: queryEmbedding.first ?? 0, count: $0.count)
        }
    }
}

final class GatedBuildSimilaritySearch: SimilaritySearching {
    private struct State: Sendable {
        var nonEmptyBuildCount = 0
        var indexedCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let buildGate: ManualResetLoadGate
    private let gatedBuildNumber: Int

    init(buildGate: ManualResetLoadGate, gatedBuildNumber: Int) {
        self.buildGate = buildGate
        self.gatedBuildNumber = gatedBuildNumber
    }

    var indexedCount: Int {
        state.withLock { $0.indexedCount }
    }

    func buildIndex(embeddings: [Float16], count: Int) {
        let buildNumber = state.withLock { state -> Int? in
            guard count > 0 else {
                state.indexedCount = 0
                return nil
            }
            state.nonEmptyBuildCount += 1
            return state.nonEmptyBuildCount
        }
        if buildNumber == gatedBuildNumber {
            buildGate.wait()
        }
        state.withLock { $0.indexedCount = count }
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        Array(
            repeating: queryEmbedding.first ?? 0,
            count: state.withLock { $0.indexedCount }
        )
    }
}

final class BlockingSimilaritySearch: SimilaritySearching {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    let searchStarted = DispatchSemaphore(value: 0)
    let resumeSearch = DispatchSemaphore(value: 0)

    func buildIndex(embeddings: [Float16], count: Int) {
        self.count.withLock { $0 = count }
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        searchStarted.signal()
        resumeSearch.wait()
        return Array(repeating: queryEmbedding.first ?? 0, count: count.withLock { $0 })
    }
}

final class ManualResetLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    let started = DispatchSemaphore(value: 0)

    func wait() {
        condition.lock()
        started.signal()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

struct FixturePhoto: Sendable {
    let id: String
    let localIdentifier: String
    let date: Date?
    var sourceId: String = PhotoSourceType.photokit.rawValue
    var filePath: String? = nil
    var city: String? = nil
    var sceneLabels: String? = nil
    let embedding: [Float16]
}

struct FixtureVideo: Sendable {
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
    private struct State: Sendable {
        var photos: [FixturePhoto]
        var videos: [FixtureVideo]
        var photoLoadCount = 0
        var videoLoadCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let photoLoadGate: ManualResetLoadGate?
    private let gatedPhotoLoadNumber: Int

    var photos: [FixturePhoto] {
        get { state.withLock { $0.photos } }
        set { state.withLock { $0.photos = newValue } }
    }

    var videos: [FixtureVideo] {
        get { state.withLock { $0.videos } }
        set { state.withLock { $0.videos = newValue } }
    }

    var photoLoadCount: Int {
        state.withLock { $0.photoLoadCount }
    }

    var videoLoadCount: Int {
        state.withLock { $0.videoLoadCount }
    }

    init(
        photos: [FixturePhoto] = [],
        videos: [FixtureVideo] = [],
        photoLoadGate: ManualResetLoadGate? = nil,
        gatedPhotoLoadNumber: Int = 1
    ) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(photos: photos, videos: videos)
        )
        self.photoLoadGate = photoLoadGate
        self.gatedPhotoLoadNumber = gatedPhotoLoadNumber
    }

    func indexedCount() throws -> Int { photos.count }
    func videoIndexedCount() throws -> Int { Set(videos.map(\.id)).count }
    func indexedMediaCounts() throws -> IndexedMediaCounts {
        let snapshot = state.withLock { $0 }
        return IndexedMediaCounts(
            photos: snapshot.photos.count,
            videos: Set(snapshot.videos.map(\.id)).count
        )
    }
    func photoLibraryIndexedMediaCounts() throws -> IndexedMediaCounts {
        let snapshot = state.withLock { $0 }
        return IndexedMediaCounts(
            photos: snapshot.photos.filter {
                $0.sourceId == PhotoSourceType.photokit.rawValue
            }.count,
            videos: Set(snapshot.videos.map(\.id)).count
        )
    }
    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers {
        let snapshot = state.withLock { $0 }
        return IndexedMediaIdentifiers(
            photos: Set(snapshot.photos.map(\.localIdentifier)),
            videos: Set(snapshot.videos.map(\.localIdentifier))
        )
    }

    func loadSearchMediaPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> SearchMediaPage {
        struct Descriptor {
            let mediaType: SearchMediaPageKind
            let id: String
            let date: Date?
        }
        let snapshot = state.withLock { state -> (photos: [FixturePhoto], videos: [FixtureVideo], photoLoad: Int) in
            state.photoLoadCount += 1
            state.videoLoadCount += 1
            return (state.photos, state.videos, state.photoLoadCount)
        }
        if snapshot.photoLoad == gatedPhotoLoadNumber {
            photoLoadGate?.wait()
        }
        var descriptors = snapshot.photos.map {
            Descriptor(mediaType: .photo, id: $0.id, date: $0.date)
        }
        let videosByID = Dictionary(grouping: snapshot.videos, by: \.id)
        descriptors.append(contentsOf: videosByID.values.compactMap { frames in
            frames.first.map { Descriptor(mediaType: .video, id: $0.id, date: $0.date) }
        })
        descriptors.sort { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                return lhs.mediaType.rawValue < rhs.mediaType.rawValue
            }
        }
        let start: Int
        if let cursor,
           let index = descriptors.firstIndex(where: {
               $0.id == cursor.id
                   && $0.mediaType == cursor.mediaType
                   && $0.date == cursor.creationDate
           }) {
            start = index + 1
        } else {
            start = 0
        }
        let boundedLimit = max(0, limit)
        let end = min(descriptors.count, start + boundedLimit)
        let selected = start < end ? Array(descriptors[start..<end]) : []
        let selectedPhotoIDs = Set(selected.filter { $0.mediaType == .photo }.map(\.id))
        let selectedVideoIDs = Set(selected.filter { $0.mediaType == .video }.map(\.id))
        let nextCursor: SearchMediaPageCursor?
        if end < descriptors.count, let last = selected.last {
            nextCursor = SearchMediaPageCursor(
                creationDate: last.date,
                id: last.id,
                mediaType: last.mediaType
            )
        } else {
            nextCursor = nil
        }
        return SearchMediaPage(
            photos: try makePhotoIndex(snapshot.photos.filter { selectedPhotoIDs.contains($0.id) }),
            videos: try makeVideoIndex(snapshot.videos.filter { selectedVideoIDs.contains($0.id) }),
            mediaCount: selected.count,
            totalPhotoCount: snapshot.photos.count,
            totalVideoCount: videosByID.count,
            nextCursor: nextCursor
        )
    }

    func loadPhotoEmbedding(id: String) throws -> MediaIndex? {
        let matches = state.withLock { $0.photos.filter { $0.id == id } }
        guard !matches.isEmpty else { return nil }
        return try makePhotoIndex(matches)
    }

    func loadAllEmbeddings() throws -> MediaIndex {
        let (photos, loadNumber) = state.withLock {
            $0.photoLoadCount += 1
            return ($0.photos, $0.photoLoadCount)
        }
        if loadNumber == gatedPhotoLoadNumber {
            photoLoadGate?.wait()
        }
        return try makePhotoIndex(photos)
    }

    func loadEmbeddingsForDuplicateScan(limit: Int) throws -> MediaIndex {
        var index = MediaIndex(kind: .photo)
        let photos = state.withLock { Array($0.photos.prefix(max(0, limit))) }
        for photo in photos {
            try index.append(
                MediaIndex.Row(
                    id: photo.id,
                    localIdentifier: photo.localIdentifier,
                    sourceId: photo.sourceId,
                    filePath: photo.filePath,
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
        let videos = state.withLock {
            $0.videoLoadCount += 1
            return $0.videos
        }
        return try makeVideoIndex(videos)
    }

    private func makePhotoIndex(_ photos: [FixturePhoto]) throws -> MediaIndex {
        var index = MediaIndex(kind: .photo)
        for photo in photos {
            try index.append(
                MediaIndex.Row(
                    id: photo.id,
                    localIdentifier: photo.localIdentifier,
                    sourceId: photo.sourceId,
                    filePath: photo.filePath,
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

    private func makeVideoIndex(_ videos: [FixtureVideo]) throws -> MediaIndex {
        var index = MediaIndex(kind: .videoFrame)
        for video in videos.sorted(by: {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.framePosition < $1.framePosition
        }) {
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
    func resetIndexedMedia() throws {}
    func deletePhoto(localIdentifier: String) throws {}
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {}
    func fetchRandomPhoto(sharp: Bool) throws -> SlideshowPhoto? { nil }
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
    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult {
        FreeTierReconciliationResult(retainedMediaCount: 0, didTrimMedia: false)
    }
    func photosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func videosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func geocodingCounts() throws -> GeocodingCounts {
        let snapshot = state.withLock { $0 }
        return GeocodingCounts(
            totalWithGPS: 0,
            remaining: 0,
            indexedPhotos: snapshot.photos.count,
            indexedVideos: snapshot.videos.count
        )
    }
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func insertSource(_ source: PhotoSource) throws {}
    func listSources() throws -> [PhotoSource] { [] }
    func deleteSource(_ id: String) throws {}
    func updateSourceStats(_ id: String, photoCount: Int) throws {}
    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])] { [] }
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
