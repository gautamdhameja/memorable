import CoreML
import GRDB
import Photos
import UIKit
import XCTest
@testable import Memorable

@MainActor
final class PhotoLibraryIndexingWorkerTests: XCTestCase {
    func testDatabaseCountFailureCannotCompleteAnInitialPass() async throws {
        let database = makeDatabase()
        try database.dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE indexed_photos RENAME TO unavailable_photos")
        }
        let worker = makeWorker(database: database)

        let session = await worker.indexPhotos()

        XCTAssertTrue(session.hasRetryableFailure)
        XCTAssertFalse(session.wasInterrupted)
    }

    func testFailedPersistenceRetainsSuccessfulIndividualRetriesAndMarksRunIncomplete() async throws {
        let database = makeDatabase()
        try database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_one_photo BEFORE INSERT ON indexed_photos
                WHEN NEW.localIdentifier = 'unwritable'
                BEGIN SELECT RAISE(ABORT, 'injected write failure'); END
                """)
        }
        let worker = makeWorker(database: database)
        let session = makeSession()

        let count = await worker.persistPhotoBatch(
            [makePhoto("writable"), makePhoto("unwritable")], session: session
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(try database.indexedCount(), 1)
        XCTAssertTrue(try database.isIndexed(localIdentifier: "writable"))
        XCTAssertFalse(try database.isIndexed(localIdentifier: "unwritable"))
        XCTAssertTrue(session.hasRetryableFailure)
    }

    func testSuccessfulPersistenceDoesNotMarkRunIncomplete() async throws {
        let database = makeDatabase()
        let session = makeSession()
        let worker = makeWorker(database: database)

        let count = await worker.persistPhotoBatch([makePhoto("saved")], session: session)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(try database.indexedCount(), 1)
        XCTAssertFalse(session.hasRetryableFailure)
    }

    func testUnrecoveredImageEncodingFailureMarksRunIncomplete() async {
        let session = makeSession()
        let worker = makeWorker(database: makeDatabase())
        do {
            _ = try await worker.encodeFallbackPhoto(makeImage(), session: session)
            XCTFail("Expected the injected prediction failure")
        } catch {
            XCTAssertTrue(session.hasRetryableFailure)
        }
    }

    func testCancelledEncodingIsNotMisclassifiedAsRetryableFailure() async {
        let session = makeSession()
        let worker = makeWorker(database: makeDatabase())
        let image = makeImage()
        let task = Task { try await worker.encodeFallbackPhoto(image, session: session) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(session.hasRetryableFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLocalMediaSkipIsDistinctFromVideoFailure() {
        XCTAssertNotEqual(VideoIndexingOutcome.notPersisted, .retryableFailure)
        XCTAssertFalse(VideoIndexingOutcome.retryableFailure.persisted)
        XCTAssertFalse(VideoIndexingOutcome.retryableFailure.completedRequiredRebuild)
    }

    func testDeniedPhotoAccessCannotCertifyAnEmptyInitialPass() async {
        let worker = makeWorker(database: makeDatabase(), authorizationStatus: { .denied })

        let session = await worker.indexPhotos()

        XCTAssertTrue(session.hasRetryableFailure)
    }

    func testRevokedAccessBeforeVideoPassCannotCertifyCompletion() async {
        let worker = makeWorker(database: makeDatabase(), authorizationStatus: { .restricted })
        let session = makeSession()

        await worker.indexVideos(session: session)

        XCTAssertTrue(session.hasRetryableFailure)
    }

    func testLimitedAccessAllowsCompletionForTheAccessibleLibrary() async {
        let worker = makeWorker(database: makeDatabase(), authorizationStatus: { .limited })
        let session = makeSession()

        await worker.indexVideos(session: session)

        XCTAssertFalse(session.hasRetryableFailure)
    }

    private func makeDatabase() -> AppDatabase {
        AppDatabase(openQueue: { try DatabaseQueue() },
                    migrate: { try AppDatabase.migrator.migrate($0) })
    }

    private func makeWorker(
        database: AppDatabase,
        authorizationStatus: @escaping @Sendable () -> PHAuthorizationStatus = { .authorized }
    ) -> PhotoLibraryIndexingWorker {
        PhotoLibraryIndexingWorker(
            imageEncoder: ImageEncoder(model: FailingWorkerPredictionModel()),
            database: database,
            callbacks: .init(
                searchableCount: { 0 }, rebuildRequired: { false },
                completeRequiredRebuild: {}, currentProgress: { IndexingProgress(total: 0, completed: 0, isRunning: false) },
                setProgress: { _ in }, setHitFreeLimit: { _ in },
                shouldStartNextBatch: { true }, reloadSearchIndex: { true },
                didReplaceMedia: { _ in }
            ),
            authorizationStatus: authorizationStatus
        )
    }

    private func makeSession() -> PhotoLibraryIndexingWorker.Session {
        PhotoLibraryIndexingWorker.Session(
            videoAssets: PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil),
            isPro: true, startedAt: CFAbsoluteTimeGetCurrent(),
            indexedMediaCount: 0
        )
    }

    private func makePhoto(_ identifier: String) -> IndexedPhoto {
        IndexedPhoto(
            id: UUID().uuidString, localIdentifier: identifier,
            pixelWidth: 224, pixelHeight: 224,
            embedding: [Float](repeating: 0.1, count: EmbeddingConfig.dimensions).toFloat16Data(),
            indexedAt: Date()
        )
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 224, height: 224)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        }
    }
}

private final class FailingWorkerPredictionModel: CoreMLModelPredicting {
    func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
        throw ImageEncoder.ImageEncoderError.outputExtractionFailed
    }
}
