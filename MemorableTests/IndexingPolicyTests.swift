import XCTest
@testable import Memorable

final class IndexingPolicyTests: XCTestCase {
    func testFailedVideoAttemptDoesNotConsumeFreeTierCapacity() {
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(current: 499, videoPersisted: false),
            499
        )
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(current: 499, videoPersisted: true),
            500
        )
    }

    func testReadOnlyFallbackDisablesAutomaticAndUserStartedIndexing() {
        XCTAssertFalse(IndexingWritePolicy.canStart(storageAllowsWrites: false))
        XCTAssertTrue(IndexingWritePolicy.canStart(storageAllowsWrites: true))
    }

    func testFolderRegistrationRemovesBookmarkWhenSourceInsertFails() {
        var bookmark: Data?

        XCTAssertThrowsError(
            try FolderSourceRegistration.register(
                bookmarkData: Data([1, 2, 3]),
                sourceId: "source-1",
                persistBookmark: { bookmark = $0 },
                insertSource: { throw RegistrationTestError.insertFailed },
                removeBookmark: { bookmark = nil }
            )
        )
        XCTAssertNil(bookmark)
    }

    func testFolderRegistrationDoesNotInsertSourceWhenBookmarkPersistenceFails() {
        var inserted = false

        XCTAssertThrowsError(
            try FolderSourceRegistration.register(
                bookmarkData: Data([1, 2, 3]),
                sourceId: "source-1",
                persistBookmark: { _ in throw RegistrationTestError.bookmarkFailed },
                insertSource: { inserted = true },
                removeBookmark: {}
            )
        )
        XCTAssertFalse(inserted)
    }

    private enum RegistrationTestError: Error {
        case bookmarkFailed
        case insertFailed
    }


    func testFreeTierLimitCountsPhotosAndVideosTogether() {
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia, isPro: false))
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: 499 + 1, isPro: false))
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: 0 + 500, isPro: false))
    }

    func testProUsersIgnoreFreeTierLimit() {
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia, isPro: true))
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia + 1_000, isPro: true))
    }

    func testFreeUsersCanIndexBelowLimit() {
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia - 1, isPro: false))
    }

    func testAutomaticBackgroundWorkUsesPostLaunchDeferral() {
        XCTAssertGreaterThan(IndexingConfig.postLaunchAutoResumeDelaySeconds, 0)
        XCTAssertGreaterThan(IndexingConfig.surpriseValidationDelaySeconds, 0)
    }

    func testProgressiveCheckpointDoesNotExceedFreeTierLimit() {
        XCTAssertLessThanOrEqual(IndexingConfig.firstSearchableCheckpoint, FreeTier.maxIndexedMedia)
    }

    func testBatchEncodeSizeUsesConservativeDefault() {
        XCTAssertEqual(IndexingConfig.batchEncodeSize, 16)
        XCTAssertGreaterThanOrEqual(IndexingConfig.prefetchBatchCapacity, 1)
    }

    func testSequentialBatchCursorContinuesAfterEmptyLoadedBatch() {
        var cursor = IndexingBatchCursor(items: Array(0..<40), batchSize: 16)
        var batchNumber = 0
        var indexedItems: [Int] = []

        while cursor.hasRemaining {
            let batch = cursor.nextBatch()
            let loadedItems = batchNumber == 0 ? [] : batch
            indexedItems.append(contentsOf: loadedItems)
            batchNumber += 1
        }

        XCTAssertEqual(batchNumber, 3)
        XCTAssertEqual(indexedItems, Array(16..<40))
    }

    func testProgressEstimateWaitsForMinimumCompletedItems() {
        let progress = IndexingProgress(
            total: 100,
            completed: IndexingConfig.progressEstimateMinCompleted - 1,
            isRunning: true,
            phase: .photos,
            phaseStartedAt: Date(timeIntervalSinceNow: -10)
        )

        XCTAssertNil(progress.itemsPerSecond)
        XCTAssertNil(progress.estimatedSecondsRemaining)
    }

    func testProgressEstimateAppearsAfterMinimumCompletedItems() {
        let progress = IndexingProgress(
            total: 100,
            completed: IndexingConfig.progressEstimateMinCompleted,
            isRunning: true,
            phase: .photos,
            phaseStartedAt: Date(timeIntervalSinceNow: -10)
        )

        XCTAssertNotNil(progress.itemsPerSecond)
        XCTAssertNotNil(progress.estimatedSecondsRemaining)
    }

    func testProgressEstimateIgnoresItemsCompletedBeforeCurrentPhaseTiming() {
        let previouslyCompleted = 4_000
        let progress = IndexingProgress(
            total: 5_000,
            completed: previouslyCompleted + IndexingConfig.progressEstimateMinCompleted - 1,
            isRunning: true,
            phase: .photos,
            rateBaselineCompleted: previouslyCompleted,
            phaseStartedAt: Date(timeIntervalSinceNow: -10)
        )

        XCTAssertNil(progress.itemsPerSecond)
        XCTAssertNil(progress.estimatedSecondsRemaining)
    }
}
