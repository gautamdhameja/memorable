import XCTest
import GRDB
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

        let photoIDs = try database.allIndexedIdentifiers()
        let mediaIDs = try database.allIndexedMediaIdentifiers()
        let counts = try database.photoLibraryIndexedMediaCounts()

        XCTAssertEqual(photoIDs, ["photokit-photo"])
        XCTAssertEqual(mediaIDs.photos, ["photokit-photo"])
        XCTAssertEqual(counts.photos, 1)
        XCTAssertEqual(try database.indexedMediaCounts().photos, 2)
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
    }

    func testDatabaseInitializationEagerlyMigratesLegacyFolderBookmarks() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        let sourceID = UUID().uuidString
        let bookmark = Data([9, 8, 7])
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceID)
        UserDefaults.standard.set(bookmark, forKey: legacyKey)
        defer { FolderBookmarkStore.remove(for: sourceID) }
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

    func testLegacyBookmarkMigrationPropagatesPersistenceFailure() throws {
        enum ForcedFailure: Error { case writeDenied }
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            try PhotoSource(
                id: UUID().uuidString,
                type: PhotoSourceType.folder.rawValue,
                path: "/tmp/failing-migration",
                name: "Failing migration",
                addedAt: Date(),
                lastIndexedAt: nil,
                photoCount: 0
            ).insert(db)
        }

        XCTAssertThrowsError(
            try AppDatabase.migrateLegacyFolderBookmarks(in: queue) { _ in
                throw ForcedFailure.writeDenied
            }
        ) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
    }

    func testFreeTierReconciliationRemovesFolderMediaSourcesAndBookmarks() throws {
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
        XCTAssertEqual(result.removedFolderSourceIDs, [sourceID])
        XCTAssertTrue(try database.listSources().isEmpty)
        XCTAssertEqual(try database.loadAllEmbeddings().sourceIds, [PhotoSourceType.photokit.rawValue])
        XCTAssertNil(UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceID)))
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

    func testDeleteAllRemovesFolderSourcesAndBookmarks() throws {
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
        UserDefaults.standard.set(
            Data([7, 8, 9]),
            forKey: AppKeys.folderBookmark(sourceId: sourceID)
        )

        try database.deleteAll()

        XCTAssertTrue(try database.listSources().isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceID)))
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

            try database.deleteAll()

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

private func makeVideo(localIdentifier: String) -> IndexedVideo {
    IndexedVideo(
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
