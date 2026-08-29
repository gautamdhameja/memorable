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

    func testPersistedMalformedPhotoEmbeddingThrowsCorruptedIndex() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "malformed-photo"))
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE indexed_photos SET embedding = ? WHERE localIdentifier = ?",
                arguments: [Data([0]), "malformed-photo"]
            )
        }

        XCTAssertThrowsError(try database.loadAllEmbeddings()) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
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
