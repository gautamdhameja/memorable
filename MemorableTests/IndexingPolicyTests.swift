import XCTest
import os
@testable import Memorable

final class IndexingPolicyTests: XCTestCase {
    func testThermalSafetyCancelsActiveWorkAtSeriousAndCriticalLevels() {
        for thermalState in [ProcessInfo.ThermalState.serious, .critical] {
            let transition = ThermalSafetyPolicy.transition(
                from: ThermalIndexingState(),
                thermalState: thermalState,
                hasActiveWork: true
            )

            XCTAssertEqual(transition.effect, .cancelWork)
            XCTAssertTrue(transition.state.isPaused)
            XCTAssertTrue(transition.state.resumeWhenCool)
        }
    }

    func testThermalSafetyRestartsRequestedWorkAfterRecovery() {
        let transition = ThermalSafetyPolicy.transition(
            from: ThermalIndexingState(isPaused: true, resumeWhenCool: true),
            thermalState: .fair,
            hasActiveWork: false
        )

        XCTAssertEqual(transition.effect, .restartWork)
        XCTAssertEqual(transition.state, ThermalIndexingState())
    }

    func testThermalSafetyDoesNotRestartIdleWorkAfterRecovery() {
        let transition = ThermalSafetyPolicy.transition(
            from: ThermalIndexingState(isPaused: true, resumeWhenCool: false),
            thermalState: .nominal,
            hasActiveWork: false
        )

        XCTAssertEqual(transition.effect, .none)
        XCTAssertEqual(transition.state, ThermalIndexingState())
    }

    func testClearedThermalStateCannotRestartAfterMemoryPressure() {
        let hot = ThermalSafetyPolicy.transition(
            from: ThermalIndexingState(),
            thermalState: .serious,
            hasActiveWork: true
        )
        XCTAssertEqual(hot.effect, .cancelWork)

        let stateAfterMemoryPressure = ThermalIndexingState()
        let cool = ThermalSafetyPolicy.transition(
            from: stateAfterMemoryPressure,
            thermalState: .fair,
            hasActiveWork: false
        )

        XCTAssertEqual(cool.effect, .none)
        XCTAssertFalse(cool.state.resumeWhenCool)
    }

    func testCompletedFolderWorkflowClearsItsThermalResumeIntent() {
        let completedFolderIntent = UUID()
        let resumedFolderIntent = UUID()

        XCTAssertFalse(IndexingService.shouldClearThermalResumeIntent(
            currentIntentID: resumedFolderIntent,
            completingIntentID: completedFolderIntent,
            isThermallyPaused: false
        ))
        XCTAssertTrue(
            IndexingService.shouldClearThermalResumeIntent(
                currentIntentID: resumedFolderIntent,
                completingIntentID: resumedFolderIntent,
                isThermallyPaused: false
            )
        )
        XCTAssertFalse(
            IndexingService.shouldClearThermalResumeIntent(
                currentIntentID: resumedFolderIntent,
                completingIntentID: resumedFolderIntent,
                isThermallyPaused: true
            )
        )

        let backgroundThermalTransition = ThermalSafetyPolicy.transition(
            from: ThermalIndexingState(),
            thermalState: .serious,
            hasActiveWork: true
        )
        XCTAssertEqual(backgroundThermalTransition.effect, .cancelWork)
    }

    func testFailedVideoAttemptDoesNotConsumeFreeTierCapacity() {
        let outcome = VideoIndexingOutcome.notPersisted

        XCTAssertFalse(outcome.persisted)
        XCTAssertFalse(outcome.completedRequiredRebuild)
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(
                current: 499,
                videoPersisted: outcome.persisted
            ),
            499
        )
    }

    func testFailedPhotoWritesDoNotConsumeFreeTierCapacity() {
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(
                current: 499,
                persistedPhotoCount: 0
            ),
            499
        )
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(
                current: 498,
                persistedPhotoCount: 1
            ),
            499
        )
    }

    func testPendingPhotoReservesLastFreeTierSlot() {
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.remainingPhotoCapacity(
                confirmedCount: 499,
                pendingCount: 1,
                reservedAssetCount: 0,
                isPro: false
            ),
            0
        )
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.remainingPhotoCapacity(
                confirmedCount: 499,
                pendingCount: 0,
                reservedAssetCount: 1,
                isPro: false
            ),
            0
        )
    }

    func testCancelledPhotoPassDoesNotFinalizePendingWrites() {
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldFinalizePhotoPass(isCancelled: true))
        XCTAssertTrue(PhotoLibraryIndexingWorker.shouldFinalizePhotoPass(isCancelled: false))
    }

    func testCancelledVideoPassDoesNotReloadOrPublishCompletion() {
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldFinalizeVideoPass(isCancelled: true))
        XCTAssertTrue(PhotoLibraryIndexingWorker.shouldFinalizeVideoPass(isCancelled: false))
    }

    func testCancelledBlockedVideoPersistenceDoesNotReportSuccess() async {
        let state = OSAllocatedUnfairLock(initialState: (started: false, release: false))
        let task = Task {
            try await VideoPersistenceOperation.run {
                state.withLock { $0.started = true }
                while !state.withLock({ $0.release }) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return true
            }
        }

        while !state.withLock({ $0.started }) {
            await Task.yield()
        }
        task.cancel()
        state.withLock { $0.release = true }

        do {
            _ = try await task.value
            XCTFail("Cancelled video persistence must not report success")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledPhotoFallbackStopsEncodingAndWriting() {
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldContinuePhotoFallback(isCancelled: true))
        XCTAssertTrue(PhotoLibraryIndexingWorker.shouldContinuePhotoFallback(isCancelled: false))
    }

    func testCancelledDetachedDatabaseOperationCannotResumeItsCaller() async {
        let state = OSAllocatedUnfairLock(
            initialState: (started: false, release: false, callerContinued: false)
        )
        let task = Task {
            do {
                try await CancellableDetachedOperation.run {
                    state.withLock { $0.started = true }
                    while !state.withLock({ $0.release }) {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                state.withLock { $0.callerContinued = true }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        while !state.withLock({ $0.started }) {
            await Task.yield()
        }
        task.cancel()
        state.withLock { $0.release = true }

        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(state.withLock { $0.callerContinued })
    }

    func testCancelledSurpriseValidationDoesNotPersistPartialResults() async {
        let state = OSAllocatedUnfairLock(
            initialState: (evaluations: 0, persisted: false)
        )
        let task = Task {
            try await SurpriseQueryValidationOperation.run(
                candidates: ["first", "second", "third"],
                evaluate: { _ in
                    let evaluation = state.withLock { value in
                        value.evaluations += 1
                        return value.evaluations
                    }
                    if evaluation == 2 {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                    return true
                },
                persist: { _ in state.withLock { $0.persisted = true } },
                onError: { _ in }
            )
        }

        while state.withLock({ $0.evaluations }) < 2 {
            await Task.yield()
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(state.withLock { $0.persisted })
    }

    @MainActor
    func testStorageMutationWaitsForIdleAndRunsOffMainThread() async throws {
        let gate = AsyncMutationGate()
        let state = OSAllocatedUnfairLock(initialState: (mutated: false, mainThread: true))
        let task = Task { @MainActor in
            try await IndexingStorageMutation.run(
                waitForIdle: { await gate.wait() },
                mutation: {
                    state.withLock {
                        $0.mutated = true
                        $0.mainThread = Thread.isMainThread
                    }
                },
                completion: {}
            )
        }

        await Task.yield()
        XCTAssertFalse(state.withLock { $0.mutated })
        await gate.open()
        try await task.value
        XCTAssertTrue(state.withLock { $0.mutated })
        XCTAssertFalse(state.withLock { $0.mainThread })
    }

    func testCancelledFolderPassDoesNotPersistPendingWrites() {
        XCTAssertFalse(FolderIndexingWorker.shouldPersistFolderWrite(isCancelled: true))
        XCTAssertTrue(FolderIndexingWorker.shouldPersistFolderWrite(isCancelled: false))
    }

    func testPersistedVideoConsumesFreeTierCapacityWithoutCompletingRebuild() {
        let outcome = VideoIndexingOutcome.persisted(completedRequiredRebuild: false)

        XCTAssertTrue(outcome.persisted)
        XCTAssertFalse(outcome.completedRequiredRebuild)
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(
                current: 499,
                videoPersisted: outcome.persisted
            ),
            500
        )
    }

    func testPersistedVideoConsumesFreeTierCapacityWhenCompletingRebuild() {
        let outcome = VideoIndexingOutcome.persisted(completedRequiredRebuild: true)

        XCTAssertTrue(outcome.persisted)
        XCTAssertTrue(outcome.completedRequiredRebuild)
        XCTAssertEqual(
            PhotoLibraryIndexingWorker.updatedMediaCount(
                current: 499,
                videoPersisted: outcome.persisted
            ),
            500
        )
    }

    func testFolderRegistrationRemovesBookmarkWhenSourceInsertFails() async {
        var bookmark: Data?

        do {
            try await FolderSourceRegistration.register(
                bookmarkData: Data([1, 2, 3]),
                sourceId: "source-1",
                persistBookmark: { bookmark = $0 },
                insertSource: { throw RegistrationTestError.insertFailed },
                removeSource: {},
                removeBookmark: { bookmark = nil }
            )
            XCTFail("Expected source insertion to fail")
        } catch {
            XCTAssertEqual(error as? RegistrationTestError, .insertFailed)
        }
        XCTAssertNil(bookmark)
    }

    func testFolderRegistrationDoesNotInsertSourceWhenBookmarkPersistenceFails() async {
        let observation = ThreadObservation()

        do {
            try await FolderSourceRegistration.register(
                bookmarkData: Data([1, 2, 3]),
                sourceId: "source-1",
                persistBookmark: { _ in throw RegistrationTestError.bookmarkFailed },
                insertSource: { observation.markCalled() },
                removeSource: {},
                removeBookmark: {}
            )
            XCTFail("Expected bookmark persistence to fail")
        } catch {
            XCTAssertEqual(error as? RegistrationTestError, .bookmarkFailed)
        }
        XCTAssertFalse(observation.wasCalled)
    }

    func testFolderRegistrationInsertsSourceOffMainThread() async throws {
        let observation = ThreadObservation()

        try await FolderSourceRegistration.register(
            bookmarkData: Data([1, 2, 3]),
            sourceId: "source-1",
            persistBookmark: { _ in },
            insertSource: { observation.recordCurrentThread() },
            removeSource: {},
            removeBookmark: {}
        )

        XCTAssertTrue(observation.wasCalled)
        XCTAssertFalse(observation.wasOnMainThread)
    }

    func testCancellingFolderScanCancelsDetachedOperation() async {
        let observation = ThreadObservation()
        let scan = Task {
            await FolderScanOperation.run {
                observation.markCalled()
                while !Task.isCancelled {
                    await Task.yield()
                }
                observation.markCancellationSeen()
                return []
            }
        }

        while !observation.wasCalled {
            await Task.yield()
        }
        scan.cancel()
        _ = await scan.value

        XCTAssertTrue(observation.cancellationWasSeen)
    }

    func testCancellingPhotoEnrichmentTaskCancelsDetachedOperation() async {
        let observation = ThreadObservation()
        let task = Task {
            await PhotoEnrichmentTask.run {
                observation.markCalled()
                while !Task.isCancelled {
                    await Task.yield()
                }
                observation.markCancellationSeen()
                return 1
            }
        }

        while !observation.wasCalled {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertTrue(observation.cancellationWasSeen)
    }

    private enum RegistrationTestError: Error, Equatable {
        case bookmarkFailed
        case insertFailed
    }


    func testFreeTierLimitCountsPhotosAndVideosTogether() {
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia, isPro: false))
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: 499 + 1, isPro: false))
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: 0 + 500, isPro: false))
    }

    func testProUsersUseDeviceSafetyLimit() {
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia, isPro: true))
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: ProTier.maxIndexedMedia - 1, isPro: true))
        XCTAssertFalse(FreeTier.canIndexMore(indexedMediaCount: ProTier.maxIndexedMedia, isPro: true))
    }

    func testFreeUsersCanIndexBelowLimit() {
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia - 1, isPro: false))
    }

    func testAutomaticBackgroundWorkUsesPostLaunchDeferral() {
        XCTAssertGreaterThan(IndexingConfig.postLaunchAutoResumeDelaySeconds, 0)
        XCTAssertGreaterThan(IndexingConfig.surpriseValidationDelaySeconds, 0)
    }

    @MainActor
    func testProRevocationTrimsBeforeReloading() async throws {
        let state = OSAllocatedUnfairLock(initialState: (trimmed: false, reloaded: false))

        try await ProRevocationOperation.run(
            trim: { state.withLock { $0.trimmed = true } },
            reload: { _ in
                state.withLock {
                    XCTAssertTrue($0.trimmed)
                    $0.reloaded = true
                }
            }
        )

        XCTAssertTrue(state.withLock { $0.reloaded })
    }

    func testProgressiveCheckpointDoesNotExceedFreeTierLimit() {
        XCTAssertLessThanOrEqual(IndexingConfig.firstSearchableCheckpoint, FreeTier.maxIndexedMedia)
    }

    func testBatchEncodeSizeUsesConservativeDefault() {
        XCTAssertEqual(IndexingConfig.batchEncodeSize, 4)
        XCTAssertGreaterThanOrEqual(IndexingConfig.prefetchBatchCapacity, 1)
    }

    func testFolderDisplayNameRemovesControlsAndBoundsLength() {
        let unsafe = "  Album\t\u{0007}\u{0085}Name  " + String(repeating: "x", count: 200)

        let sanitized = FolderDisplayNamePolicy.sanitized(unsafe)

        XCTAssertFalse(sanitized.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        })
        XCTAssertLessThanOrEqual(sanitized.count, FolderDisplayNamePolicy.maximumCharacters)
        XCTAssertTrue(sanitized.hasPrefix("AlbumName"))
        XCTAssertEqual(FolderDisplayNamePolicy.sanitized("\t\n"), "Folder")
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

    func testBatchCursorNormalizesInvalidBatchSizeWithoutCrashing() {
        var cursor = IndexingBatchCursor(items: [1, 2], batchSize: 0)

        XCTAssertEqual(cursor.nextBatch(), [1])
        XCTAssertEqual(cursor.nextBatch(), [2])
        XCTAssertFalse(cursor.hasRemaining)
    }

    func testBatchCursorDoesNotSkipItemsWhenCapacityIsSmallerThanBatch() {
        var cursor = IndexingBatchCursor(items: Array(0..<16), batchSize: 16)

        XCTAssertEqual(cursor.nextBatch(maxCount: 1), [0])
        XCTAssertEqual(cursor.nextBatch(maxCount: 1), [1])
        XCTAssertTrue(cursor.hasRemaining)
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

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var mainThread = false
    private var sawCancellation = false

    var wasCalled: Bool { lock.withLock { called } }
    var wasOnMainThread: Bool { lock.withLock { mainThread } }
    var cancellationWasSeen: Bool { lock.withLock { sawCancellation } }

    func markCalled() {
        lock.withLock { called = true }
    }

    func recordCurrentThread() {
        lock.withLock {
            called = true
            mainThread = Thread.isMainThread
        }
    }

    func markCancellationSeen() {
        lock.withLock { sawCancellation = true }
    }
}

private actor AsyncMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
