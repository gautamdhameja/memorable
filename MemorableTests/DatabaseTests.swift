import XCTest
import GRDB
import os
@testable import Memorable

final class DatabaseTests: XCTestCase {

    override func tearDown() {
        AppDatabase.isInMemoryFallback = false
        UserDefaults.standard.removeObject(forKey: "indexing.needsFastFormatPhotoRebuild")
        super.tearDown()
    }

    func testSuccessfulInMemoryMigrationDoesNotMarkFallback() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertFalse(AppDatabase.isInMemoryFallback)
        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertEqual(try database.videoIndexedCount(), 0)
    }

    func testMemoryQueriesIgnoreRowsOutsideLegacySafetyWindow() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let calendar = Calendar.current
        let matchingDate = calendar.date(
            byAdding: .year,
            value: -1,
            to: Date()
        )!
        let queue = try database.dbQueue.rawQueue()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO indexed_photos (
                        id, localIdentifier, creationDate, pixelWidth, pixelHeight,
                        embedding, indexedAt, sharpnessScore
                    ) VALUES (?, ?, ?, 1, 1, ?, ?, 100)
                """,
                arguments: ["outside", "outside", matchingDate, Data([0]), matchingDate]
            )
            for index in 0..<SearchIndexLimits.maximumPhotoRows {
                try db.execute(
                    sql: """
                        INSERT INTO indexed_photos (
                            id, localIdentifier, pixelWidth, pixelHeight,
                            embedding, indexedAt, sharpnessScore
                        ) VALUES (?, ?, 1, 1, zeroblob(?), ?, 0)
                    """,
                    arguments: [
                        "recent-\(index)",
                        "recent-\(index)",
                        EmbeddingConfig.bytesPerEmbedding,
                        Date(timeIntervalSince1970: TimeInterval(index)),
                    ]
                )
            }
        }

        XCTAssertTrue(try database.onThisDayPhotos().isEmpty)
        XCTAssertNotEqual(try database.fetchRandomPhoto(sharp: true)?.id, "outside")
    }

    func testCombinedMediaReadsReturnPhotoAndVideoInOneSnapshot() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let photo = makePhoto(localIdentifier: "photo-1")
        let video = makeVideo(localIdentifier: "video-1")
        try database.insertPhoto(photo)
        try database.insertVideo(
            video,
            [
                IndexedVideoFrame(
                    id: UUID().uuidString,
                    videoId: video.id,
                    framePosition: 0.5,
                    embedding: floatVector(first: 1).toFloat16Data(),
                    indexedAt: Date(timeIntervalSince1970: 200)
                )
            ],
            completingRequiredRebuild: false
        )

        let counts = try database.indexedMediaCounts()
        let identifiers = try database.allIndexedMediaIdentifiers()
        let geocodingCounts = try database.geocodingCounts()

        XCTAssertEqual(counts.photos, 1)
        XCTAssertEqual(counts.videos, 1)
        XCTAssertEqual(counts.total, 2)
        XCTAssertEqual(identifiers.photos, ["photo-1"])
        XCTAssertEqual(identifiers.videos, ["video-1"])
        XCTAssertEqual(geocodingCounts.totalWithGPS, 0)
        XCTAssertEqual(geocodingCounts.remaining, 0)
        XCTAssertEqual(geocodingCounts.indexedPhotos, 1)
        XCTAssertEqual(geocodingCounts.indexedVideos, 1)
    }

    func testPhotoPersistenceRejectsMalformedEmbedding() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var malformedPhoto = makePhoto(localIdentifier: "malformed-write")
        malformedPhoto.embedding = Data([0])

        XCTAssertThrowsError(try database.insertPhoto(malformedPhoto)) { error in
            XCTAssertEqual(error as? SearchEngineError, .invalidEmbedding)
        }
        XCTAssertThrowsError(
            try database.insertPhotos(
                [malformedPhoto],
                completingRequiredRebuild: false
            )
        ) { error in
            XCTAssertEqual(error as? SearchEngineError, .invalidEmbedding)
        }
        XCTAssertEqual(try database.indexedCount(), 0)
    }

    func testVideoFrameIndexRejectsUnsafePersistedPositions() throws {
        for position in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try MediaIndex(
                kind: .videoFrame,
                ids: ["video"],
                localIdentifiers: ["local-video"],
                dates: [nil],
                latitudes: [nil],
                longitudes: [nil],
                ocrTexts: [nil],
                locationCities: [nil],
                locationStates: [nil],
                locationCountries: [nil],
                locationNames: [nil],
                sceneLabels: [nil],
                framePositions: [position],
                embeddings: float16Vector(first: 1)
            )) { error in
                XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
            }
        }
    }

    func testMigrationFailureUsesUsableReadOnlyInMemoryFallback() throws {
        var migrationAttempt = 0
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { queue in
                migrationAttempt += 1
                if migrationAttempt == 1 {
                    throw StubMigrationError.failed
                }
                try AppDatabase.migrator.migrate(queue)
            }
        )

        XCTAssertTrue(AppDatabase.isInMemoryFallback)
        XCTAssertFalse(database.allowsIndexingWrites)
        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertEqual(try database.videoIndexedCount(), 0)
        XCTAssertThrowsError(try database.insertPhoto(makePhoto(localIdentifier: "blocked-photo"))) { error in
            XCTAssertEqual(error as? DatabaseCapabilityError, .indexingUnavailableInFallback)
        }
    }

    func testFailureOfPersistentAndFallbackMigrationIsRecoverable() {
        XCTAssertThrowsError(
            try AppDatabase(
                openQueue: { try DatabaseQueue() },
                migrate: { _ in throw StubMigrationError.failed },
                fallbackMigrate: { _ in throw StubMigrationError.failed }
            )
        ) { error in
            XCTAssertNotNil(error as? DatabaseInitializationError)
        }
    }

    func testInsertedBasePhotoDefaultsToNeedingEnrichment() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photo-1"))

        let candidates = try database.photosNeedingEnrichment(limit: 10)

        XCTAssertEqual(candidates.map(\.localIdentifier), ["photo-1"])
        XCTAssertEqual(candidates.map(\.sourceId), [PhotoSourceType.photokit.rawValue])
        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 1)
    }

    func testLegacyOversizedMetadataIsBoundedBeforeIndexRetention() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "legacy-metadata"))
        let oversized = "a" + String(repeating: "\u{0301}", count: 100_000)
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_photos
                    SET ocrText = ?, sceneLabels = ?, locationName = ?
                    WHERE localIdentifier = ?
                """,
                arguments: [oversized, oversized, oversized, "legacy-metadata"]
            )
        }

        let index = try database.loadAllEmbeddings()

        XCTAssertLessThanOrEqual(
            try XCTUnwrap(index.ocrTexts.first ?? nil).unicodeScalars.count,
            PersistedMetadataTextPolicy.maximumOCRCharacters
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(index.sceneLabels.first ?? nil).unicodeScalars.count,
            PersistedMetadataTextPolicy.maximumSceneLabelCharacters
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(index.locationNames.first ?? nil).unicodeScalars.count,
            PersistedMetadataTextPolicy.maximumLocationCharacters
        )
    }

    func testOversizedPhotoEmbeddingIsRejectedAtSQLProjectionBoundary() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "malformed-photo"))
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE indexed_photos SET embedding = zeroblob(?) WHERE localIdentifier = ?",
                arguments: [16 * 1_024 * 1_024, "malformed-photo"]
            )
        }

        XCTAssertThrowsError(try database.loadAllEmbeddings()) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
        XCTAssertThrowsError(try database.loadEmbeddingsForDuplicateScan(limit: 1)) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
        XCTAssertThrowsError(try database.fetchRandomPhoto(sharp: false)) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testOversizedVideoEmbeddingIsRejectedAtSQLProjectionBoundary() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let video = makeVideo(localIdentifier: "malformed-video")
        let frame = makeFrame(videoId: video.id, position: 0.5)
        try database.insertVideo(video, [frame], completingRequiredRebuild: false)
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE indexed_video_frames SET embedding = zeroblob(?) WHERE id = ?",
                arguments: [16 * 1_024 * 1_024, frame.id]
            )
        }

        XCTAssertThrowsError(try database.loadAllVideoEmbeddings()) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testStreamingEmbeddingLoadsPreserveSearchIndexColumns() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let photo = makePhoto(
            localIdentifier: "folder-photo",
            sourceId: "folder-source",
            filePath: "/folder/photo.jpg"
        )
        let video = makeVideo(localIdentifier: "video-1")
        try database.insertPhoto(photo)
        try database.insertVideo(
            video,
            [
                IndexedVideoFrame(
                    id: UUID().uuidString,
                    videoId: video.id,
                    framePosition: 0.75,
                    embedding: floatVector(first: 0.5).toFloat16Data(),
                    indexedAt: Date(timeIntervalSince1970: 200)
                )
            ],
            completingRequiredRebuild: false
        )

        let photoIndex = try database.loadAllEmbeddings()
        let videoIndex = try database.loadAllVideoEmbeddings()

        XCTAssertEqual(photoIndex.kind, .photo)
        XCTAssertEqual(photoIndex.ids, [photo.id])
        XCTAssertEqual(photoIndex.localIdentifiers, ["folder-photo"])
        XCTAssertEqual(photoIndex.sourceIds, ["folder-source"])
        XCTAssertEqual(photoIndex.filePaths, ["/folder/photo.jpg"])
        XCTAssertEqual(photoIndex.embeddings.count, EmbeddingConfig.dimensions)

        XCTAssertEqual(videoIndex.kind, .videoFrame)
        XCTAssertEqual(videoIndex.ids, [video.id])
        XCTAssertEqual(videoIndex.localIdentifiers, ["video-1"])
        XCTAssertEqual(videoIndex.framePositions, [0.75])
        XCTAssertEqual(videoIndex.embeddings.count, EmbeddingConfig.dimensions)
    }

    func testSearchMediaPagesCoverMixedMediaWithoutOverlapOrSplitVideos() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var newestPhoto = makePhoto(localIdentifier: "photo-new")
        newestPhoto.creationDate = Date(timeIntervalSince1970: 400)
        var oldestPhoto = makePhoto(localIdentifier: "photo-old")
        oldestPhoto.creationDate = Date(timeIntervalSince1970: 100)
        try database.insertPhotos([newestPhoto, oldestPhoto], completingRequiredRebuild: false)

        var video = makeVideo(localIdentifier: "video-middle")
        video.creationDate = Date(timeIntervalSince1970: 300)
        try database.insertVideo(
            video,
            [
                makeFrame(videoId: video.id, position: 0.1),
                makeFrame(videoId: video.id, position: 0.5),
                makeFrame(videoId: video.id, position: 0.9),
            ],
            completingRequiredRebuild: false
        )

        var cursor: SearchMediaPageCursor?
        var mediaIDs: [String] = []
        var videoFrameCounts: [Int] = []
        var pageNumber = 0
        repeat {
            let page = try database.loadSearchMediaPage(after: cursor, limit: 1)
            if pageNumber == 0 {
                XCTAssertEqual(page.totalPhotoCount, 2)
                XCTAssertEqual(page.totalVideoCount, 1)
            } else {
                XCTAssertEqual(page.totalPhotoCount, 0)
                XCTAssertEqual(page.totalVideoCount, 0)
            }
            mediaIDs.append(contentsOf: page.photos.ids)
            if page.videos.count > 0 {
                mediaIDs.append(contentsOf: Set(page.videos.ids))
                videoFrameCounts.append(page.videos.count)
            }
            cursor = page.nextCursor
            pageNumber += 1
        } while cursor != nil

        XCTAssertEqual(Set(mediaIDs), [newestPhoto.id, video.id, oldestPhoto.id])
        XCTAssertEqual(mediaIDs.count, 3)
        XCTAssertEqual(videoFrameCounts, [3])
    }

    func testSearchMediaPagingPreservesGlobalTieAndNilDateOrder() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var tiedPhoto = makePhoto(localIdentifier: "tied-photo")
        tiedPhoto.id = "shared-id"
        tiedPhoto.creationDate = Date(timeIntervalSince1970: 200)
        var nilDatePhoto = makePhoto(localIdentifier: "nil-photo")
        nilDatePhoto.id = "a-nil-photo"
        nilDatePhoto.creationDate = nil
        var excludedFolderPhoto = makePhoto(
            localIdentifier: "folder-photo",
            sourceId: "folder-source",
            filePath: "/folder/photo.jpg"
        )
        excludedFolderPhoto.id = "newest-folder"
        excludedFolderPhoto.creationDate = Date(timeIntervalSince1970: 300)
        try database.insertPhotos(
            [tiedPhoto, nilDatePhoto, excludedFolderPhoto],
            completingRequiredRebuild: false
        )

        var tiedVideo = makeVideo(localIdentifier: "tied-video")
        tiedVideo.id = "shared-id"
        tiedVideo.creationDate = Date(timeIntervalSince1970: 200)
        try database.insertVideo(
            tiedVideo,
            [makeFrame(videoId: tiedVideo.id, position: 0.5)],
            completingRequiredRebuild: false
        )
        var nilDateVideo = makeVideo(localIdentifier: "nil-video")
        nilDateVideo.id = "z-nil-video"
        nilDateVideo.creationDate = nil
        try database.insertVideo(
            nilDateVideo,
            [makeFrame(videoId: nilDateVideo.id, position: 0.5)],
            completingRequiredRebuild: false
        )

        var searchCursor: SearchMediaPageCursor?
        var searchOrder: [(SearchMediaPageKind, String)] = []
        repeat {
            let page = try database.loadSearchMediaPage(after: searchCursor, limit: 1)
            if let photoID = page.photos.ids.first {
                searchOrder.append((.photo, photoID))
            }
            if let videoID = page.videos.ids.first {
                searchOrder.append((.video, videoID))
            }
            searchCursor = page.nextCursor
        } while searchCursor != nil

        XCTAssertEqual(searchOrder.map(\.0), [.photo, .photo, .video, .photo, .video])
        XCTAssertEqual(
            searchOrder.map(\.1),
            ["newest-folder", "shared-id", "shared-id", "a-nil-photo", "z-nil-video"]
        )

        var identifierCursor: SearchMediaPageCursor?
        var identifiers: [String] = []
        repeat {
            let page = try database.loadIndexedMediaIdentifierPage(
                after: identifierCursor,
                limit: 1
            )
            identifiers.append(contentsOf: page.photos)
            identifiers.append(contentsOf: page.videos)
            identifierCursor = page.nextCursor
        } while identifierCursor != nil
        XCTAssertEqual(identifiers, ["tied-photo", "tied-video", "nil-photo", "nil-video"])
    }

    func testSearchPagingQueriesUseOrderingIndexesWithoutUnionMaterialization() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let cursor = SearchMediaPageCursor(
            creationDate: Date(timeIntervalSince1970: 200),
            id: "cursor-id",
            mediaType: .photo
        )
        let photoQuery = AppDatabase.mediaPageDescriptorQuery(
            mediaType: .photo,
            includesLocalIdentifier: true,
            sourceID: PhotoSourceType.photokit.rawValue,
            after: cursor,
            limit: 10
        )
        let sourceVideoQuery = AppDatabase.mediaPageDescriptorQuery(
            mediaType: .video,
            includesLocalIdentifier: true,
            sourceID: PhotoSourceType.photokit.rawValue,
            after: cursor,
            limit: 10
        )
        let wholeLibraryVideoQuery = AppDatabase.mediaPageDescriptorQuery(
            mediaType: .video,
            includesLocalIdentifier: false,
            sourceID: nil,
            after: cursor,
            limit: 10
        )

        let plans = try database.dbQueue.read { db in
            try [photoQuery, sourceVideoQuery, wholeLibraryVideoQuery].map { query in
                try Row.fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN \(query.sql)",
                    arguments: query.arguments
                ).map { $0["detail"] as String }.joined(separator: " ")
            }
        }

        XCTAssertTrue(plans[0].contains("idx_photos_source_search_order"), plans[0])
        XCTAssertTrue(plans[1].contains("idx_videos_source_search_order"), plans[1])
        XCTAssertTrue(plans[2].contains("idx_videos_search_order"), plans[2])
        XCTAssertFalse(plans.joined().contains("UNION"))
        XCTAssertFalse(plans.joined().contains("USE TEMP B-TREE"), plans.joined())
    }

    func testFolderPathBatchLookupUsesFilePathIndex() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let plan = try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT filePath FROM indexed_photos
                    WHERE filePath IN (?, ?)
                """,
                arguments: ["/folder/a.jpg", "/folder/b.jpg"]
            ).map { $0["detail"] as String }.joined(separator: " ")
        }

        XCTAssertTrue(plan.contains("idx_photos_file_path"), plan)
    }

    func testInsertVideoRejectsFrameCountsOutsideSafeRange() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let video = makeVideo(localIdentifier: "invalid-frame-count-video")

        XCTAssertThrowsError(
            try database.insertVideo(video, [], completingRequiredRebuild: false)
        ) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
        XCTAssertThrowsError(
            try database.insertVideo(
                video,
                (0...SearchIndexLimits.maximumVideoFramesPerMedia).map {
                    makeFrame(videoId: video.id, position: Double($0) / 10)
                },
                completingRequiredRebuild: false
            )
        ) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
        XCTAssertThrowsError(
            try database.insertVideo(
                video,
                [makeFrame(videoId: "another-video", position: 0.5)],
                completingRequiredRebuild: false
            )
        ) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
        XCTAssertEqual(try database.videoIndexedCount(), 0)
    }

    func testSearchPageRejectsPersistedVideoWithoutFrames() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.dbQueue.write { db in
            try makeVideo(localIdentifier: "corrupt-empty-video").insert(db)
        }

        XCTAssertThrowsError(try database.loadSearchMediaPage(after: nil, limit: 1)) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testSearchPageRejectsPersistedVideoWithExcessFrames() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var video = makeVideo(localIdentifier: "corrupt-excess-video")
        video.frameCount = SearchIndexLimits.maximumVideoFramesPerMedia + 1
        try database.dbQueue.write { db in
            try video.insert(db)
            for index in 0...SearchIndexLimits.maximumVideoFramesPerMedia {
                try makeFrame(
                    videoId: video.id,
                    position: Double(index) / 10
                ).insert(db)
            }
        }

        XCTAssertThrowsError(try database.loadSearchMediaPage(after: nil, limit: 1)) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testBatchExistenceFindsIdentifiersOlderThanResidentWindow() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let queue = try database.dbQueue.rawQueue()
        try queue.write { db in
            try db.execute(
                sql: """
                    WITH RECURSIVE sequence(value) AS (
                        SELECT 0
                        UNION ALL
                        SELECT value + 1 FROM sequence WHERE value < ?
                    )
                    INSERT INTO indexed_photos (
                        id, localIdentifier, creationDate, pixelWidth, pixelHeight,
                        embedding, indexedAt, sourceId
                    )
                    SELECT printf('photo-%05d', value), printf('local-%05d', value),
                           ?, 1, 1, zeroblob(?), ?, ?
                    FROM sequence
                """,
                arguments: [
                    SearchIndexLimits.residentMediaItems,
                    Date(timeIntervalSince1970: 100),
                    EmbeddingConfig.bytesPerEmbedding,
                    Date(timeIntervalSince1970: 100),
                    PhotoSourceType.photokit.rawValue,
                ]
            )
        }

        let existing = try database.existingPhotoIdentifiers(in: [
            "local-00000",
            "local-08000",
            "missing",
        ])

        XCTAssertEqual(existing, ["local-00000", "local-08000"])
    }

    func testBoundedEmbeddingLoadsUseDeterministicNewestFirstOrdering() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var olderPhoto = makePhoto(localIdentifier: "older-photo")
        olderPhoto.id = "photo-c"
        olderPhoto.creationDate = Date(timeIntervalSince1970: 100)
        var newestPhotoB = makePhoto(localIdentifier: "newest-photo-b")
        newestPhotoB.id = "photo-b"
        newestPhotoB.creationDate = Date(timeIntervalSince1970: 200)
        var newestPhotoA = makePhoto(localIdentifier: "newest-photo-a")
        newestPhotoA.id = "photo-a"
        newestPhotoA.creationDate = Date(timeIntervalSince1970: 200)
        try database.insertPhotos(
            [olderPhoto, newestPhotoB, newestPhotoA],
            completingRequiredRebuild: false
        )

        var olderVideo = makeVideo(localIdentifier: "older-video")
        olderVideo.id = "video-z"
        olderVideo.creationDate = Date(timeIntervalSince1970: 100)
        var newestVideo = makeVideo(localIdentifier: "newest-video")
        newestVideo.id = "a-video"
        newestVideo.creationDate = Date(timeIntervalSince1970: 200)
        try database.insertVideo(
            olderVideo,
            [makeFrame(videoId: olderVideo.id, position: 0.5)],
            completingRequiredRebuild: false
        )
        try database.insertVideo(
            newestVideo,
            [
                makeFrame(videoId: newestVideo.id, position: 0.9),
                makeFrame(videoId: newestVideo.id, position: 0.1)
            ],
            completingRequiredRebuild: false
        )

        let photoIndex = try database.loadPhotoEmbeddings(limit: 2)
        let videoIndex = try database.loadVideoEmbeddings(limit: 2)
        let identifiers = try database.loadIndexedMediaIdentifiers(limit: 2)

        XCTAssertEqual(photoIndex.ids, ["photo-a", "photo-b"])
        XCTAssertEqual(videoIndex.ids, ["a-video", "a-video"])
        XCTAssertEqual(videoIndex.framePositions, [0.1, 0.9])
        XCTAssertEqual(identifiers.photos, ["newest-photo-a"])
        XCTAssertEqual(identifiers.videos, ["newest-video"])
    }

    func testSearchIndexLimitsBoundLegacyDatabaseRows() {
        XCTAssertEqual(SearchIndexLimits.maximumMediaItems, 8_000)
        XCTAssertEqual(SearchIndexLimits.maximumPhotoRows, 8_000)
        XCTAssertEqual(SearchIndexLimits.maximumVideoFrameRows, 40_000)
        XCTAssertEqual(SearchIndexLimits.maximumTotalRows, 40_000)
    }

    func testDuplicateScanEmbeddingLoadAppliesDatabaseLimit() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhotos(
            (1...3).map { makePhoto(localIdentifier: "photo-\($0)") },
            completingRequiredRebuild: false
        )

        let index = try database.loadEmbeddingsForDuplicateScan(limit: 2)

        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.embeddings.count, 2 * EmbeddingConfig.dimensions)
    }

    func testSearchEmbeddingLoadsShareCombinedMediaWindow() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhotos(
            (1...2).map { makePhoto(localIdentifier: "photo-\($0)") },
            completingRequiredRebuild: false
        )
        for number in 1...2 {
            let video = makeVideo(localIdentifier: "video-\(number)")
            try database.insertVideo(
                video,
                [IndexedVideoFrame(
                    id: UUID().uuidString,
                    videoId: video.id,
                    framePosition: 0.5,
                    embedding: floatVector(first: 1).toFloat16Data(),
                    indexedAt: Date(timeIntervalSince1970: 200)
                )],
                completingRequiredRebuild: false
            )
        }

        let photos = try database.loadPhotoEmbeddings(limit: 3, mediaLimit: 3)
        let videos = try database.loadVideoEmbeddings(limit: 15, mediaLimit: 3)

        XCTAssertEqual(photos.count + videos.uniqueIDCount, 3)
    }

    func testDuplicateScanExcludesFolderSources() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photokit-photo"))
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-photo",
            sourceId: "folder-source",
            filePath: "/folder/photo.jpg"
        ))

        let index = try database.loadEmbeddingsForDuplicateScan(limit: 10)

        XCTAssertEqual(index.localIdentifiers, ["photokit-photo"])
        XCTAssertEqual(index.sourceIds, [PhotoSourceType.photokit.rawValue])
    }

    func testPhotoLibraryMaintenanceExcludesFolderSources() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photokit-photo"))
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-photo",
            sourceId: "folder-source",
            filePath: "/folder/photo.jpg"
        ))
        let photoKitVideo = makeVideo(localIdentifier: "photokit-video")
        try database.insertVideo(
            photoKitVideo,
            [makeFrame(videoId: photoKitVideo.id, position: 0.5)],
            completingRequiredRebuild: false
        )
        let folderVideo = makeVideo(
            localIdentifier: "folder-video",
            sourceId: "folder-source"
        )
        try database.insertVideo(
            folderVideo,
            [makeFrame(videoId: folderVideo.id, position: 0.5)],
            completingRequiredRebuild: false
        )

        let photoIDs = try database.allIndexedIdentifiers()
        let mediaIDs = try database.allIndexedMediaIdentifiers()
        let counts = try database.photoLibraryIndexedMediaCounts()
        var pageCursor: SearchMediaPageCursor?
        var pagedPhotoIDs: [String] = []
        var pagedVideoIDs: [String] = []
        repeat {
            let page = try database.loadIndexedMediaIdentifierPage(
                after: pageCursor,
                limit: 1
            )
            pagedPhotoIDs.append(contentsOf: page.photos)
            pagedVideoIDs.append(contentsOf: page.videos)
            pageCursor = page.nextCursor
        } while pageCursor != nil
        let wholeLibraryPage = try database.loadSearchMediaPage(after: nil, limit: 10)

        XCTAssertEqual(photoIDs, ["photokit-photo"])
        XCTAssertEqual(mediaIDs.photos, ["photokit-photo"])
        XCTAssertEqual(mediaIDs.videos, ["photokit-video"])
        XCTAssertEqual(Set(pagedPhotoIDs), ["photokit-photo"])
        XCTAssertEqual(Set(pagedVideoIDs), ["photokit-video"])
        XCTAssertEqual(counts.photos, 1)
        XCTAssertEqual(counts.videos, 1)
        XCTAssertEqual(try database.indexedMediaCounts().photos, 2)
        XCTAssertEqual(try database.indexedMediaCounts().videos, 2)
        XCTAssertEqual(
            Set(wholeLibraryPage.videos.localIdentifiers),
            ["photokit-video", "folder-video"]
        )
    }

    func testPhotoEnrichmentUpdateMarksRowCompleteEvenWithoutOcr() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photo-1"))

        try database.updatePhotoEnrichment([PhotoEnrichmentUpdate(
            localIdentifier: "photo-1",
            ocrText: nil,
            sharpnessScore: 72,
            sceneLabels: nil
        )])

        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 0)
        XCTAssertTrue(try database.photosNeedingEnrichment(limit: 10).isEmpty)
    }

    func testPhotoEnrichmentUpdatesCompleteMultipleRowsAsOneBatch() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhotos(
            [
                makePhoto(localIdentifier: "photo-1"),
                makePhoto(localIdentifier: "photo-2")
            ],
            completingRequiredRebuild: false
        )

        try database.updatePhotoEnrichment([
            PhotoEnrichmentUpdate(
                localIdentifier: "photo-1",
                ocrText: "first",
                sharpnessScore: 72,
                sceneLabels: nil
            ),
            PhotoEnrichmentUpdate(
                localIdentifier: "photo-2",
                ocrText: nil,
                sharpnessScore: 81,
                sceneLabels: "outdoor"
            )
        ])

        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 0)
    }

    func testFailedPhotoEnrichmentIsDeferredWithoutBeingCompleted() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photo-retry"))
        let attemptedAt = Date()

        try database.updatePhotoEnrichment([
            PhotoEnrichmentUpdate(
                localIdentifier: "photo-retry",
                ocrText: nil,
                sharpnessScore: nil,
                sceneLabels: nil,
                outcome: .loadFailed(at: attemptedAt)
            )
        ])

        let state = try database.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT enrichmentComplete, enrichmentAttemptedAt FROM indexed_photos WHERE localIdentifier = ?",
                arguments: ["photo-retry"]
            )
        }
        XCTAssertEqual(state?["enrichmentComplete"] as Bool?, false)
        let storedAttemptedAt = try XCTUnwrap(state?["enrichmentAttemptedAt"] as Date?)
        XCTAssertEqual(storedAttemptedAt.timeIntervalSince1970, attemptedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 0)

        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE indexed_photos SET enrichmentAttemptedAt = ? WHERE localIdentifier = ?",
                arguments: [
                    attemptedAt.addingTimeInterval(-IndexingConfig.enrichmentRetryDelaySeconds - 1),
                    "photo-retry"
                ]
            )
        }

        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 1)
    }

    func testFolderEnrichmentCandidateCarriesSourceIdAndFilePath() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-image.jpg",
            sourceId: "folder-source-1",
            filePath: "/tmp/folder-image.jpg"
        ))

        let candidate = try XCTUnwrap(database.photosNeedingEnrichment(limit: 10).first)

        XCTAssertEqual(candidate.localIdentifier, "folder-image.jpg")
        XCTAssertEqual(candidate.sourceId, "folder-source-1")
        XCTAssertEqual(candidate.filePath, "/tmp/folder-image.jpg")
    }

    func testDeletePhotoRemovesOnlyMatchingIdentifier() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "delete-me"))
        try database.insertPhoto(makePhoto(localIdentifier: "keep-me"))

        try database.deletePhoto(localIdentifier: "delete-me")

        XCTAssertFalse(try database.isIndexed(localIdentifier: "delete-me"))
        XCTAssertTrue(try database.isIndexed(localIdentifier: "keep-me"))
        XCTAssertEqual(try database.indexedCount(), 1)
    }

    func testDeleteSourceRemovesPersistedBookmark() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceId = "folder-source-delete"
        UserDefaults.standard.set(Data([1, 2, 3]), forKey: AppKeys.folderBookmark(sourceId: sourceId))
        try database.insertSource(PhotoSource(
            id: sourceId,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/folder",
            name: "Folder",
            addedAt: Date(timeIntervalSince1970: 100),
            lastIndexedAt: nil,
            photoCount: 0
        ))

        try database.deleteSource(sourceId)

        XCTAssertNil(UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceId)))
        XCTAssertTrue(try database.listSources().isEmpty)
    }

    func testDeleteSourceKeepsRowsWhenBookmarkCleanupFails() throws {
        enum ForcedFailure: Error { case removeDenied }
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceID = "folder-source-cleanup-failure"
        try database.insertSource(PhotoSource(
            id: sourceID,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/folder-cleanup-failure",
            name: "Folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 0
        ))
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-photo-cleanup-failure",
            sourceId: sourceID,
            filePath: "/tmp/folder-cleanup-failure/photo.jpg"
        ))

        XCTAssertThrowsError(try database.deleteSource(sourceID) { _ in
            throw ForcedFailure.removeDenied
        }) {
            XCTAssertEqual($0 as? FolderSourceDeletionError, .bookmarkCleanupFailed)
        }
        XCTAssertEqual(try database.listSources().map(\.id), [sourceID])
        XCTAssertTrue(try database.isIndexed(localIdentifier: "folder-photo-cleanup-failure"))
    }

    func testDeleteSourcePropagatesDatabaseFailureAfterRemovingBookmark() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-source-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    atPath: databaseURL.path + suffix
                )
            }
        }
        let queue = try DatabaseQueue(path: databaseURL.path)
        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceID = "folder-source-database-failure"
        try database.insertSource(PhotoSource(
            id: sourceID,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/folder-database-failure",
            name: "Folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 0
        ))
        try queue.close()
        var didRemoveBookmark = false

        XCTAssertThrowsError(try database.deleteSource(sourceID) { _ in
            didRemoveBookmark = true
        }) { error in
            XCTAssertTrue(error is DatabaseError)
        }
        XCTAssertTrue(didRemoveBookmark)

        let verificationQueue = try DatabaseQueue(path: databaseURL.path)
        let persistedSourceIDs = try verificationQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM photo_sources")
        }
        XCTAssertEqual(persistedSourceIDs, [sourceID])
    }

    func testDatabaseInitializationEagerlyMigratesLegacyFolderBookmarks() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let sourceID = UUID().uuidString
        let bookmark = Data([9, 8, 7])
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceID)
        UserDefaults.standard.set(bookmark, forKey: legacyKey)
        defer { try? FolderBookmarkStore.remove(for: sourceID) }
        try queue.write { db in
            try PhotoSource(
                id: sourceID,
                type: PhotoSourceType.folder.rawValue,
                path: "/tmp/migration-folder",
                name: "Migration folder",
                addedAt: Date(),
                lastIndexedAt: nil,
                photoCount: 0
            ).insert(db)
        }

        _ = AppDatabase(openQueue: { queue }, migrate: { _ in })

        XCTAssertNil(UserDefaults.standard.data(forKey: legacyKey))
        XCTAssertEqual(FolderBookmarkStore.data(for: sourceID), bookmark)
    }

    func testLegacyBookmarkMigrationContinuesAfterPerSourcePersistenceFailure() throws {
        enum ForcedFailure: Error { case writeDenied }
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let failingSourceID = "failing-migration-source"
        let succeedingSourceID = "succeeding-migration-source"
        try queue.write { db in
            try PhotoSource(
                id: failingSourceID,
                type: PhotoSourceType.folder.rawValue,
                path: "/tmp/failing-migration",
                name: "Failing migration",
                addedAt: Date(),
                lastIndexedAt: nil,
                photoCount: 0
            ).insert(db)
            try PhotoSource(
                id: succeedingSourceID,
                type: PhotoSourceType.folder.rawValue,
                path: "/tmp/succeeding-migration",
                name: "Succeeding migration",
                addedAt: Date(),
                lastIndexedAt: nil,
                photoCount: 0
            ).insert(db)
        }
        var migratedSourceIDs: [String] = []

        let failedSourceIDs = AppDatabase.migrateLegacyFolderBookmarks(in: queue) { sourceID in
            if sourceID == failingSourceID {
                throw ForcedFailure.writeDenied
            }
            migratedSourceIDs.append(sourceID)
        }

        XCTAssertEqual(failedSourceIDs, [failingSourceID])
        XCTAssertEqual(migratedSourceIDs, [succeedingSourceID])
    }

    func testBookmarkMigrationFailureDoesNotDemotePersistentDatabase() throws {
        enum ForcedFailure: Error { case writeDenied }
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let sourceID = "persistent-source-with-failed-bookmark-migration"
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceID)
        UserDefaults.standard.set(Data([1, 2, 3]), forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }
        try queue.write { db in
            try PhotoSource(
                id: sourceID,
                type: PhotoSourceType.folder.rawValue,
                path: "/tmp/persistent-source",
                name: "Persistent source",
                addedAt: Date(),
                lastIndexedAt: nil,
                photoCount: 0
            ).insert(db)
        }

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { _ in },
            migrateLegacyBookmark: { _ in throw ForcedFailure.writeDenied }
        )

        XCTAssertTrue(database.allowsIndexingWrites)
        XCTAssertEqual(try database.listSources().map(\.id), [sourceID])
        XCTAssertEqual(UserDefaults.standard.data(forKey: legacyKey), Data([1, 2, 3]))
    }

    func testFreeTierReconciliationRemovesOnlyDerivedFolderMedia() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceID = "folder-source-refund"
        UserDefaults.standard.set(
            Data([4, 5, 6]),
            forKey: AppKeys.folderBookmark(sourceId: sourceID)
        )
        try database.insertSource(PhotoSource(
            id: sourceID,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/refund-folder",
            name: "Refund folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 1
        ))
        try database.insertPhoto(makePhoto(localIdentifier: "library-photo"))
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-photo",
            sourceId: sourceID,
            filePath: "/tmp/refund-folder/photo.jpg"
        ))

        let result = try database.reconcileFreeTier(FreeTier.maxIndexedMedia)

        XCTAssertEqual(result.retainedMediaCount, 1)
        XCTAssertFalse(result.didTrimMedia)
        XCTAssertEqual(try database.listSources().map(\.id), [sourceID])
        XCTAssertEqual(try database.loadAllEmbeddings().sourceIds, [PhotoSourceType.photokit.rawValue])
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceID)),
            Data([4, 5, 6])
        )
        let preservedSource = try XCTUnwrap(database.listSources().first)
        XCTAssertEqual(preservedSource.photoCount, 0)
        XCTAssertNil(preservedSource.lastIndexedAt)
    }

    func testInvalidatedFreeTierReconciliationRollsBackAllMutations() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceID = "folder-source-stale-reconciliation"
        try database.insertSource(PhotoSource(
            id: sourceID,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/stale-reconciliation-folder",
            name: "Stale reconciliation folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 1
        ))
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-photo-stale-reconciliation",
            sourceId: sourceID,
            filePath: "/tmp/stale-reconciliation-folder/photo.jpg"
        ))
        let validityChecks = OSAllocatedUnfairLock(initialState: 0)

        XCTAssertThrowsError(try database.reconcileFreeTier(
            FreeTier.maxIndexedMedia,
            whilePermitted: {
                validityChecks.withLock {
                    $0 += 1
                    return $0 == 1
                }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(try database.isIndexed(
            localIdentifier: "folder-photo-stale-reconciliation"
        ))
        XCTAssertEqual(try database.listSources().map(\.id), [sourceID])
    }

    func testFolderSourceRegistrationRejectsDuplicatesAndCapsCardinality() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        func source(_ index: Int, path: String? = nil) -> PhotoSource {
            PhotoSource(
                id: "source-\(index)",
                type: PhotoSourceType.folder.rawValue,
                path: path ?? "/tmp/folder-\(index)",
                name: "Folder \(index)",
                addedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                lastIndexedAt: nil,
                photoCount: 0
            )
        }

        try database.insertSource(source(0))
        XCTAssertThrowsError(try database.insertSource(source(100, path: "/tmp/folder-0"))) {
            XCTAssertEqual($0 as? PhotoSourceRegistrationError, .duplicateFolder)
        }
        for index in 1..<PhotoSourcePolicy.maximumFolderSources {
            try database.insertSource(source(index))
        }

        XCTAssertEqual(try database.listSources().count, PhotoSourcePolicy.maximumFolderSources)
        XCTAssertThrowsError(try database.insertSource(source(999))) {
            XCTAssertEqual($0 as? PhotoSourceRegistrationError, .sourceLimitReached)
        }
    }

    func testListSourcesReturnsGrandfatheredFoldersBeyondCurrentInsertionLimit() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let legacyCount = PhotoSourcePolicy.maximumFolderSources + 3
        try database.dbQueue.write { db in
            for index in 0..<legacyCount {
                try PhotoSource(
                    id: "legacy-source-\(index)",
                    type: PhotoSourceType.folder.rawValue,
                    path: "/tmp/legacy-folder-\(index)",
                    name: "Legacy folder \(index)",
                    addedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    lastIndexedAt: nil,
                    photoCount: 0
                ).insert(db)
            }
        }

        XCTAssertEqual(try database.listSources().count, legacyCount)
        XCTAssertThrowsError(try database.insertSource(PhotoSource(
            id: "new-source-over-limit",
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/new-source-over-limit",
            name: "New folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 0
        ))) {
            XCTAssertEqual($0 as? PhotoSourceRegistrationError, .sourceLimitReached)
        }
    }

    func testIndexResetPreservesFolderSourcesAndBookmarks() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceID = "folder-source-rebuild"
        try database.insertSource(PhotoSource(
            id: sourceID,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/rebuild-folder",
            name: "Rebuild folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 0
        ))
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-photo-before-reset",
            sourceId: sourceID,
            filePath: "/tmp/rebuild-folder/photo.jpg"
        ))
        try database.updateSourceStats(sourceID, photoCount: 1)
        UserDefaults.standard.set(
            Data([7, 8, 9]),
            forKey: AppKeys.folderBookmark(sourceId: sourceID)
        )

        try database.resetIndexedMedia()

        XCTAssertEqual(try database.listSources().map(\.id), [sourceID])
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceID)),
            Data([7, 8, 9])
        )
        XCTAssertEqual(try database.indexedCount(), 0)
        let preservedSource = try XCTUnwrap(database.listSources().first)
        XCTAssertEqual(preservedSource.photoCount, 0)
        XCTAssertNil(preservedSource.lastIndexedAt)
    }

    func testFolderLocalIdentifierUsesSourceAndRelativePath() {
        let folderA = URL(fileURLWithPath: "/tmp/a")
        let folderB = URL(fileURLWithPath: "/tmp/b")
        let first = FolderScanner.localIdentifier(
            for: URL(fileURLWithPath: "/tmp/a/nested/IMG_0001.JPG"),
            within: folderA,
            sourceId: "source-a"
        )
        let second = FolderScanner.localIdentifier(
            for: URL(fileURLWithPath: "/tmp/b/nested/IMG_0001.JPG"),
            within: folderB,
            sourceId: "source-b"
        )
        let sibling = FolderScanner.localIdentifier(
            for: URL(fileURLWithPath: "/tmp/a/other/IMG_0001.JPG"),
            within: folderA,
            sourceId: "source-a"
        )

        XCTAssertEqual(first, "folder:source-a:nested/IMG_0001.JPG")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, sibling)
    }

    func testPhotoEnrichmentMigrationCreatesPendingLookupIndex() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        let indexNames = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(indexed_photos)")
                .map { $0["name"] as String }
        }

        XCTAssertTrue(indexNames.contains("idx_photos_enrichment_pending"))
    }

    func testFreshDatabaseDoesNotRequireIndexRebuild() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertFalse(try database.indexRebuildRequired())
    }

    func testAlreadyMigratedEmptyDatabaseDoesNotRequireIndexRebuild() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertFalse(try database.indexRebuildRequired())
    }

    func testOrientationWipeRecordsRequiredIndexRebuild() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2-siglip2-model-swap")
        try insertLegacyPhoto(localIdentifier: "pre-orientation-photo", into: queue)

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertTrue(try database.indexRebuildRequired())
        try database.clearIndexRebuildRequired()
        XCTAssertFalse(try database.indexRebuildRequired())
    }

    func testPopulatedV1DatabaseRecordsRequiredRebuildBeforeModelSwapWipe() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try insertLegacyPhoto(localIdentifier: "pre-model-swap-photo", into: queue)

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertTrue(try database.indexRebuildRequired())
    }

    func testInterruptedRebuildAfterFirstPhotoBatchPreservesProgressOnNextLaunch() throws {
        let interruptedQueue = try {
            let database = try makeDatabaseRequiringRebuild()

            XCTAssertTrue(try database.indexRebuildRequired())

            try database.resetIndexedMedia()

            XCTAssertEqual(try database.indexedCount(), 0)
            XCTAssertTrue(try database.indexRebuildRequired())

            let completedRebuild = try database.insertPhotos(
                [makePhoto(localIdentifier: "rebuilt-photo")],
                completingRequiredRebuild: true
            )

            XCTAssertTrue(completedRebuild)
            return try database.dbQueue.rawQueue()
        }()

        // The first indexing run has stopped without end-of-pass cleanup.
        // Launch against only the database state committed before interruption.
        let relaunchedDatabase = AppDatabase(
            openQueue: { interruptedQueue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertFalse(try relaunchedDatabase.indexRebuildRequired())
        XCTAssertTrue(try relaunchedDatabase.isIndexed(localIdentifier: "rebuilt-photo"))
        XCTAssertEqual(try relaunchedDatabase.indexedCount(), 1)
    }

    func testFirstVideoFrameBatchAfterRebuildWipeClearsRequirement() throws {
        let database = try makeDatabaseRequiringRebuild()
        let video = makeVideo(localIdentifier: "rebuilt-video")

        let completedRebuild = try database.insertVideo(
            video,
            [
                IndexedVideoFrame(
                    id: UUID().uuidString,
                    videoId: video.id,
                    framePosition: 0.5,
                    embedding: floatVector(first: 1).toFloat16Data(),
                    indexedAt: Date(timeIntervalSince1970: 200)
                )
            ],
            completingRequiredRebuild: true
        )

        XCTAssertTrue(completedRebuild)
        XCTAssertEqual(try database.videoIndexedCount(), 1)
        XCTAssertFalse(try database.indexRebuildRequired())
    }

    func testMigrationRemovesVideoRecordsWithoutFrames() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v7-index-rebuild-state")
        try queue.write { db in
            try makeVideo(localIdentifier: "incomplete-video").insert(db)
        }

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertEqual(try database.videoIndexedCount(), 0)
        XCTAssertFalse(try database.indexRebuildRequired())
    }

    func testFastFormatWipeUsesSameRequiredIndexRebuildState() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4-photo-enrichment-state")
        try queue.write { db in
            try makePhoto(localIdentifier: "fast-format-photo").insert(db)
        }

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertTrue(try database.indexRebuildRequired())
    }

    func testAlreadyMigratedDatabaseWithEmbeddingsRequiresIndexRebuild() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try makePhoto(localIdentifier: "flipped-photo").insert(db)
        }

        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertEqual(try database.indexedCount(), 1)
        XCTAssertTrue(try database.indexRebuildRequired())
    }

    func testNewBatchDoesNotClearRequirementWhileOldEmbeddingsRemain() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try makePhoto(localIdentifier: "flipped-photo").insert(db)
        }
        let database = AppDatabase(
            openQueue: { queue },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        try database.insertPhotos(
            [makePhoto(localIdentifier: "new-photo")],
            completingRequiredRebuild: true
        )

        XCTAssertEqual(try database.indexedCount(), 2)
        XCTAssertTrue(try database.indexRebuildRequired())
    }

}

private enum StubMigrationError: Error {
    case failed
}

private func makeDatabaseRequiringRebuild() throws -> AppDatabase {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator.migrate(queue, upTo: "v2-siglip2-model-swap")
    try insertLegacyPhoto(localIdentifier: "pre-orientation-photo", into: queue)
    return AppDatabase(
        openQueue: { queue },
        migrate: { try AppDatabase.migrator.migrate($0) }
    )
}

private func insertLegacyPhoto(localIdentifier: String, into queue: DatabaseQueue) throws {
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO indexed_photos (
                    id, localIdentifier, pixelWidth, pixelHeight, embedding, indexedAt
                ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString,
                localIdentifier,
                100,
                100,
                floatVector(first: 1).toFloat16Data(),
                Date(timeIntervalSince1970: 200)
            ]
        )
    }
}

private func makePhoto(
    localIdentifier: String,
    sourceId: String = PhotoSourceType.photokit.rawValue,
    filePath: String? = nil
) -> IndexedPhoto {
    IndexedPhoto(
        id: UUID().uuidString,
        localIdentifier: localIdentifier,
        creationDate: Date(timeIntervalSince1970: 100),
        latitude: nil,
        longitude: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        embedding: floatVector(first: 1).toFloat16Data(),
        indexedAt: Date(timeIntervalSince1970: 200),
        sourceId: sourceId,
        filePath: filePath
    )
}

private func makeVideo(
    localIdentifier: String,
    sourceId: String = PhotoSourceType.photokit.rawValue
) -> IndexedVideo {
    var video = IndexedVideo(
        id: UUID().uuidString,
        localIdentifier: localIdentifier,
        creationDate: Date(timeIntervalSince1970: 100),
        latitude: nil,
        longitude: nil,
        duration: 10,
        pixelWidth: 1920,
        pixelHeight: 1080,
        frameCount: 1,
        indexedAt: Date(timeIntervalSince1970: 200)
    )
    video.sourceId = sourceId
    return video
}

private func makeFrame(videoId: String, position: Double) -> IndexedVideoFrame {
    IndexedVideoFrame(
        id: UUID().uuidString,
        videoId: videoId,
        framePosition: position,
        embedding: floatVector(first: Float(position)).toFloat16Data(),
        indexedAt: Date(timeIntervalSince1970: 200)
    )
}
