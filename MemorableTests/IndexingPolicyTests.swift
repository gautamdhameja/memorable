import XCTest
import GRDB
import CoreML
import os
@testable import Memorable

final class IndexingPolicyTests: XCTestCase {
    func testDuplicateScanGenerationRejectsCancelledOrSupersededResults() {
        XCTAssertTrue(DuplicateScanGenerationPolicy.acceptsCompletion(
            startedGeneration: 4,
            currentGeneration: 4,
            isCancelled: false
        ))
        XCTAssertFalse(DuplicateScanGenerationPolicy.acceptsCompletion(
            startedGeneration: 4,
            currentGeneration: 5,
            isCancelled: false
        ))
        XCTAssertFalse(DuplicateScanGenerationPolicy.acceptsCompletion(
            startedGeneration: 4,
            currentGeneration: 4,
            isCancelled: true
        ))
    }

    func testIndexingProgressPublisherThrottlesIntermediateUpdatesButPublishesCompletion() {
        var publisher = IndexingProgressPublisher()
        var published: [Int] = []
        let record: (IndexingProgress) -> Void = { published.append($0.completed) }

        publisher.publish(
            IndexingProgress(total: 100, completed: 0, isRunning: true, phase: .photos),
            now: 1,
            using: record
        )
        publisher.publish(
            IndexingProgress(total: 100, completed: 1, isRunning: true, phase: .photos),
            now: 1.1,
            using: record
        )
        publisher.publish(
            IndexingProgress(total: 100, completed: 2, isRunning: true, phase: .photos),
            now: 1.3,
            using: record
        )
        publisher.publish(
            IndexingProgress(total: 100, completed: 2, isRunning: false, phase: .photos),
            now: 1.31,
            using: record
        )

        XCTAssertEqual(published, [0, 2, 2])
    }

    func testIncrementalPhotoChangeReconcilerHandlesSameCountReplacement() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makeOrphanPolicyPhoto(localIdentifier: "removed-photo"))
        for index in 0..<9 {
            try database.insertPhoto(makeOrphanPolicyPhoto(
                localIdentifier: "retained-photo-\(index)"
            ))
        }
        let event = PhotoLibraryChangeEvent(
            insertedPhotoIDs: ["new-photo"],
            removedPhotoIDs: ["removed-photo"]
        )

        let result = try PhotoLibraryChangeReconciler.reconcile(
            event,
            database: database,
            authorizationStatus: .authorized
        )

        XCTAssertTrue(result.hasNewMedia)
        XCTAssertEqual(result.orphanedPhotoIDs, ["removed-photo"])
        XCTAssertTrue(result.orphanedVideoIDs.isEmpty)
    }

    func testIncrementalPhotoChangeReconcilerDoesNotDeleteUnderLimitedAccess() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makeOrphanPolicyPhoto(localIdentifier: "hidden-photo"))

        let result = try PhotoLibraryChangeReconciler.reconcile(
            PhotoLibraryChangeEvent(removedPhotoIDs: ["hidden-photo"]),
            database: database,
            authorizationStatus: .limited
        )

        XCTAssertFalse(result.hasNewMedia)
        XCTAssertTrue(result.orphanedPhotoIDs.isEmpty)
    }

    func testOrphanCleanupRequiresFullPhotosAuthorization() {
        XCTAssertTrue(PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(.authorized))
        XCTAssertFalse(PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(.limited))
        XCTAssertFalse(PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(.denied))
        XCTAssertFalse(PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(.restricted))
        XCTAssertFalse(PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(.notDetermined))
    }

    func testFolderScanIsIncompleteWhenAnyDiscoveredFileFails() {
        XCTAssertTrue(FolderScanCompletionPolicy.isComplete(
            directoryScanWasComplete: true,
            failedFileCount: 0,
            successfullyHandledFileCount: 1
        ))
        XCTAssertFalse(FolderScanCompletionPolicy.isComplete(
            directoryScanWasComplete: true,
            failedFileCount: 1,
            successfullyHandledFileCount: 0
        ))
        XCTAssertTrue(FolderScanCompletionPolicy.isComplete(
            directoryScanWasComplete: true,
            failedFileCount: 1,
            successfullyHandledFileCount: 1
        ))
        XCTAssertFalse(FolderScanCompletionPolicy.isComplete(
            directoryScanWasComplete: false,
            failedFileCount: 0,
            successfullyHandledFileCount: 1
        ))
    }

    func testFolderWarningOutcomeCompletesRecoveryWithoutMaskingHardFailures() {
        XCTAssertTrue(FolderIndexingOutcome.completed.didComplete)
        XCTAssertTrue(FolderIndexingOutcome.completedWithWarnings.didComplete)
        XCTAssertFalse(FolderIndexingOutcome.failed.didComplete)
        XCTAssertFalse(FolderIndexingOutcome.cancelled.didComplete)
    }

    func testPhotoLibraryChangeEventsCoalesceWithoutReintroducingRemovedInserts() {
        var event = PhotoLibraryChangeEvent(insertedPhotoIDs: ["one", "two"])
        event.merge(PhotoLibraryChangeEvent(
            insertedPhotoIDs: ["three"],
            removedPhotoIDs: ["two"]
        ))

        XCTAssertEqual(event.insertedPhotoIDs, ["one", "three"])
        XCTAssertEqual(event.removedPhotoIDs, ["two"])
    }

    func testPhotoChangeCallbacksCoalesceWhileIndexingAndDrainWhenIdle() {
        var state = PhotoChangeScanState()

        XCTAssertFalse(state.requestScan(isIndexing: true))
        XCTAssertTrue(state.hasPendingChange)
        XCTAssertTrue(state.startPendingScanIfPossible(isIndexing: false))
        XCTAssertTrue(state.isScanning)
        XCTAssertFalse(state.hasPendingChange)
    }

    func testPhotoChangeCallbacksCoalesceDuringScanIntoOneFollowUp() {
        var state = PhotoChangeScanState()

        XCTAssertTrue(state.requestScan(isIndexing: false))
        XCTAssertFalse(state.requestScan(isIndexing: false))
        XCTAssertFalse(state.requestScan(isIndexing: false))
        XCTAssertTrue(state.hasPendingChange)
        XCTAssertTrue(state.finishScan(isIndexing: false))
        XCTAssertFalse(state.hasPendingChange)
        XCTAssertTrue(state.isScanning)
        XCTAssertFalse(state.finishScan(isIndexing: false))
    }

    func testSameCountReplacementReportsNewAndOrphanedPhotoAndVideo() {
        let result = PhotoLibraryChangeDiff.evaluate(
            libraryPhotos: ["new-photo"],
            libraryVideos: ["new-video"],
            indexedPhotos: ["old-photo"],
            indexedVideos: ["old-video"],
            allowsOrphanCleanup: true
        )

        XCTAssertTrue(result.hasNewMedia)
        XCTAssertEqual(result.orphanedPhotoIDs, ["old-photo"])
        XCTAssertEqual(result.orphanedVideoIDs, ["old-video"])
    }

    func testLimitedPhotoAccessNeverAuthorizesOrphanCleanup() {
        let result = PhotoLibraryChangeDiff.evaluate(
            libraryPhotos: ["new-photo"],
            libraryVideos: [],
            indexedPhotos: ["old-photo"],
            indexedVideos: ["old-video"],
            allowsOrphanCleanup: false
        )

        XCTAssertTrue(result.hasNewMedia)
        XCTAssertTrue(result.orphanedPhotoIDs.isEmpty)
        XCTAssertTrue(result.orphanedVideoIDs.isEmpty)
    }

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
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(state.withLock { $0.persisted })
    }

    func testSurpriseValidationRechecksABoundedCachedShortlistWithoutAdvancingBaseline() {
        let cachedQueries = (0..<20).map { "query-\($0)" }
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: cachedQueries,
            lastValidatedCount: 100
        )

        let plan = SurpriseQueries.validationPlan(
            cachedState: cachedState,
            currentSize: 105
        )

        XCTAssertEqual(plan.candidates.count, SurpriseQueries.cachedRevalidationLimit)
        XCTAssertTrue(plan.candidates.allSatisfy(cachedQueries.contains))
        XCTAssertEqual(plan.persistedCount, 100)
        XCTAssertTrue(plan.revalidatesCachedSubset)

        let validated = Array(plan.candidates.dropLast())
        let updated = SurpriseQueries.updatedCacheState(
            validatedQueries: validated,
            plan: plan,
            previous: cachedState
        )
        XCTAssertEqual(updated.lastValidatedCount, 100)
        XCTAssertEqual(updated.validatedQueries.count, cachedQueries.count - 1)
        XCTAssertTrue(validated.allSatisfy(updated.validatedQueries.contains))
    }

    func testSurpriseValidationReusesCacheWhenIndexRevisionIsUnchanged() {
        let revision = surpriseContentRevision(seed: 100)
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour", "mountain view"],
            lastValidatedCount: 105,
            contentRevision: revision
        )

        let plan = SurpriseQueries.validationPlan(
            cachedState: cachedState,
            currentSize: 105,
            currentRevision: revision
        )

        XCTAssertTrue(plan.reusesUnchangedCache)
        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testSurpriseSuggestionsHydrateImmediatelyForCurrentIndexRevision() {
        let revision = surpriseContentRevision(seed: 100)
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour", "mountain view"],
            lastValidatedCount: 100,
            contentRevision: revision
        )

        XCTAssertEqual(
            SurpriseQueries.cachedQueries(
                from: cachedState,
                matching: revision
            ),
            ["golden hour", "mountain view"]
        )
    }

    func testSurpriseSuggestionsDoNotHydrateForStaleIndexRevision() {
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour"],
            lastValidatedCount: 100,
            contentRevision: surpriseContentRevision(seed: 100)
        )

        XCTAssertTrue(
            SurpriseQueries.cachedQueries(
                from: cachedState,
                matching: surpriseContentRevision(seed: 101)
            ).isEmpty
        )
    }

    @MainActor
    func testExistingIndexPublishesCurrentSurpriseCacheBeforeReadyCallback() async throws {
        let database = SearchFixtureDatabase(photos: [surpriseFixturePhoto()])
        let revision = try database.searchIndexContentRevision()
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour", "mountain view"],
            lastValidatedCount: 1,
            contentRevision: revision
        )
        let service = makeSurpriseLaunchService(
            database: database,
            cachedState: cachedState
        )
        var suggestionsAtReady: [String] = []
        service.onIndexReady = {
            suggestionsAtReady = service.validatedSearchSuggestions
        }

        let didLoad = await service.loadExistingIndexIfAvailable(
            loadPriority: .userInitiated
        )

        XCTAssertTrue(didLoad)
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(service.validatedSearchSuggestions, cachedState.validatedQueries)
        XCTAssertEqual(suggestionsAtReady, cachedState.validatedQueries)
    }

    @MainActor
    func testSurpriseCacheRevisionFailureDoesNotBlockExistingIndexReadiness() async throws {
        let database = SearchFixtureDatabase(photos: [surpriseFixturePhoto()])
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour"],
            lastValidatedCount: 1,
            contentRevision: try database.searchIndexContentRevision()
        )
        let service = makeSurpriseLaunchService(
            database: database,
            cachedState: cachedState,
            searchIndexContentRevisionLoader: {
                throw SurpriseLaunchTestError.revisionUnavailable
            }
        )

        let didLoad = await service.loadExistingIndexIfAvailable(
            loadPriority: .userInitiated
        )

        XCTAssertTrue(didLoad)
        XCTAssertTrue(service.isReady)
        XCTAssertTrue(service.validatedSearchSuggestions.isEmpty)
    }

    @MainActor
    func testUnusableSurpriseCacheSkipsRevisionReadDuringIndexLoad() async {
        let database = SearchFixtureDatabase(photos: [surpriseFixturePhoto()])
        let revisionRead = ThreadObservation()
        let mismatchedRevision = surpriseContentRevision(seed: 1)
        let service = makeSurpriseLaunchService(
            database: database,
            cachedState: SurpriseQueryCache.State(
                validatedQueries: ["golden hour"],
                lastValidatedCount: 1,
                contentRevision: mismatchedRevision
            ),
            searchIndexContentRevisionLoader: {
                revisionRead.markCalled()
                return mismatchedRevision
            }
        )

        let didLoad = await service.loadExistingIndexIfAvailable(
            loadPriority: .userInitiated
        )

        XCTAssertTrue(didLoad)
        XCTAssertTrue(service.isReady)
        XCTAssertFalse(revisionRead.wasCalled)
        XCTAssertTrue(service.validatedSearchSuggestions.isEmpty)
    }

    @MainActor
    func testExistingIndexDoesNotRestoreSurpriseCacheOverActiveIndexing() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [surpriseFixturePhoto()],
            photoLoadGate: loadGate
        )
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour"],
            lastValidatedCount: 1,
            contentRevision: try database.searchIndexContentRevision()
        )
        let service = makeSurpriseLaunchService(
            database: database,
            cachedState: cachedState
        )
        var didCallReady = false
        service.onIndexReady = { didCallReady = true }
        let loadTask = Task { @MainActor in
            await service.loadExistingIndexIfAvailable(loadPriority: .userInitiated)
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                loadGate.started.wait()
                continuation.resume()
            }
        }
        service.progress = IndexingProgress(total: 1, completed: 0, isRunning: true)
        loadGate.open()
        let didLoad = await loadTask.value

        XCTAssertFalse(didLoad)
        XCTAssertTrue(service.progress.isRunning)
        XCTAssertTrue(service.validatedSearchSuggestions.isEmpty)
        XCTAssertFalse(didCallReady)
    }

    func testSurpriseCachePrefilterRejectsUnusableCacheWithoutARevisionQuery() {
        let revision = surpriseContentRevision(seed: 100)
        XCTAssertTrue(
            SurpriseQueryCache.State(
                validatedQueries: ["golden hour"],
                lastValidatedCount: 100,
                contentRevision: revision
            ).couldMatch(photoCount: 100, videoCount: 5)
        )
        XCTAssertFalse(
            SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 100,
                contentRevision: revision
            ).couldMatch(photoCount: 100, videoCount: 5)
        )
        XCTAssertFalse(
            SurpriseQueryCache.State(
                validatedQueries: ["golden hour"],
                lastValidatedCount: 100
            ).couldMatch(photoCount: 100, videoCount: 5)
        )
        XCTAssertFalse(
            SurpriseQueryCache.State(
                validatedQueries: ["golden hour"],
                lastValidatedCount: 100,
                contentRevision: revision
            ).couldMatch(photoCount: 101, videoCount: 5)
        )
        XCTAssertFalse(
            SurpriseQueryCache.State(
                validatedQueries: ["golden hour"],
                lastValidatedCount: 100,
                contentRevision: revision
            ).couldMatch(photoCount: 100, videoCount: 6)
        )
    }

    func testSurpriseValidationUsesFullCandidateSetAfterCumulativeGrowthThreshold() {
        let cachedState = SurpriseQueryCache.State(
            validatedQueries: ["golden hour"],
            lastValidatedCount: 100
        )

        let plan = SurpriseQueries.validationPlan(
            cachedState: cachedState,
            currentSize: 110
        )

        XCTAssertEqual(plan.candidates, SurpriseQueries.candidates)
        XCTAssertEqual(plan.persistedCount, 110)
        XCTAssertFalse(plan.revalidatesCachedSubset)

        let updated = SurpriseQueries.updatedCacheState(
            validatedQueries: ["sunset over water"],
            plan: plan,
            previous: cachedState
        )
        XCTAssertEqual(updated.validatedQueries, ["sunset over water"])
        XCTAssertEqual(updated.lastValidatedCount, 110)
    }

    private func surpriseContentRevision(seed: Int) -> SearchIndexContentRevision {
        SearchIndexContentRevision(
            photoCount: seed,
            videoCount: 5,
            videoFrameCount: 15,
            latestPhotoRowID: Int64(seed),
            latestVideoRowID: 5,
            latestVideoFrameRowID: 15,
            latestPhotoID: "photo-\(seed)",
            latestVideoID: "video-5",
            latestVideoFrameID: "frame-15",
            latestPhotoIndexedAt: Date(timeIntervalSince1970: TimeInterval(seed)),
            latestVideoIndexedAt: Date(timeIntervalSince1970: 200),
            latestVideoFrameIndexedAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func surpriseFixturePhoto() -> FixturePhoto {
        FixturePhoto(
            id: "photo-1",
            localIdentifier: "local-photo-1",
            date: Date(timeIntervalSince1970: 100),
            embedding: float16Vector(first: 1)
        )
    }

    @MainActor
    private func makeSurpriseLaunchService(
        database: SearchFixtureDatabase,
        cachedState: SurpriseQueryCache.State,
        searchIndexContentRevisionLoader: (@Sendable () throws -> SearchIndexContentRevision)? = nil,
        initialIndexingDefaults: UserDefaults = .standard
    ) -> IndexingService {
        let searchEngine = SearchEngine(
            textEncoder: FakeTextEncoder([:]),
            database: database
        )
        return IndexingService(
            imageEncoder: ImageEncoder(model: UnusedImagePredictionModel()),
            searchEngine: searchEngine,
            database: database,
            surpriseQueryCacheLoader: { cachedState },
            searchIndexContentRevisionLoader: searchIndexContentRevisionLoader,
            initialIndexingDefaults: initialIndexingDefaults
        )
    }

    @MainActor
    func testPendingZeroRowInitialIndexResumesThroughServiceAndStopDismissesIt() async {
        let suiteName = "InitialIndexingServiceResumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        InitialIndexingExperienceStore.begin(in: defaults)
        let service = makeSurpriseLaunchService(
            database: SearchFixtureDatabase(),
            cachedState: SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 0
            ),
            initialIndexingDefaults: defaults
        )

        let loaded = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: true,
            scheduleOrphanCleanup: false
        )

        XCTAssertFalse(loaded)
        XCTAssertTrue(service.progress.isRunning)
        XCTAssertTrue(service.isInitialLibraryIndexingActive)
        XCTAssertTrue(service.shouldShowInitialIndexingExperience)

        service.stopIndexing()
        XCTAssertFalse(service.isInitialIndexingExperiencePending)
        XCTAssertFalse(service.isInitialLibraryIndexingActive)
        XCTAssertTrue(InitialIndexingExperienceStore.isCompleted(in: defaults))
    }

    @MainActor
    func testPendingStateCannotMakeUnrelatedIndexingLookInitial() {
        let suiteName = "InitialIndexingServiceIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        InitialIndexingExperienceStore.begin(in: defaults)
        let service = makeSurpriseLaunchService(
            database: SearchFixtureDatabase(),
            cachedState: SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 0
            ),
            initialIndexingDefaults: defaults
        )

        service.progress.isRunning = true

        XCTAssertFalse(service.isInitialLibraryIndexingActive)
        XCTAssertFalse(service.shouldShowInitialIndexingExperience)
        service.stopIndexing()
    }

    @MainActor
    func testBackgroundInterruptionKeepsResumeIntentButDeactivatesInitialUI() {
        let suiteName = "InitialIndexingServiceInterruptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = makeSurpriseLaunchService(
            database: SearchFixtureDatabase(),
            cachedState: SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 0
            ),
            initialIndexingDefaults: defaults
        )
        service.startIndexing()
        XCTAssertTrue(service.isInitialLibraryIndexingActive)

        service.handleBackgroundTaskExpiration()

        XCTAssertTrue(service.isInitialIndexingExperiencePending)
        XCTAssertFalse(service.isInitialLibraryIndexingActive)
        service.progress.isRunning = true
        XCTAssertFalse(service.shouldShowInitialIndexingExperience)
        service.stopIndexing()
    }

    @MainActor
    func testCompletedEmptyInitialExperienceKeepsLaterIndexingInNormalUI() {
        let suiteName = "InitialIndexingServiceCompletedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        InitialIndexingExperienceStore.complete(in: defaults)
        let service = makeSurpriseLaunchService(
            database: SearchFixtureDatabase(),
            cachedState: SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 0
            ),
            initialIndexingDefaults: defaults
        )

        service.startIndexing()

        XCTAssertTrue(service.progress.isRunning)
        XCTAssertFalse(service.isInitialLibraryIndexingActive)
        XCTAssertFalse(service.shouldShowInitialIndexingExperience)
        service.stopIndexing()
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

    func testFolderPendingBatchIsClearedBeforePersistenceCanFail() {
        var batch = [1, 2, 3]
        let pending = FolderPendingBatch.takeAll(&batch)

        XCTAssertEqual(pending, [1, 2, 3])
        XCTAssertTrue(batch.isEmpty)
    }

    func testSavedFolderReindexPolicySelectsOnlyUnfinishedFoldersForPro() {
        let empty = PhotoSource(
            id: "empty-folder",
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/empty-folder",
            name: "Empty folder",
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 0
        )
        let populated = PhotoSource(
            id: "populated-folder",
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/populated-folder",
            name: "Populated folder",
            addedAt: Date(),
            lastIndexedAt: Date(),
            photoCount: 4
        )

        XCTAssertEqual(
            SavedFolderReindexPolicy.sourcesToReindex(
                from: [empty, populated],
                isPro: true
            ).map(\.id),
            [empty.id]
        )
        XCTAssertTrue(SavedFolderReindexPolicy.sourcesToReindex(
            from: [empty, populated],
            isPro: false
        ).isEmpty)
    }

    func testFolderVolumeCannotAuthorizePhotoLibraryOrphanDeletion() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makeOrphanPolicyPhoto(localIdentifier: "photokit-photo"))
        for index in 0..<9 {
            try database.insertPhoto(makeOrphanPolicyPhoto(
                localIdentifier: "folder-photo-\(index)",
                sourceId: "folder-source",
                filePath: "/folder/photo-\(index).jpg"
            ))
        }

        let allIndexedCount = try database.indexedMediaCounts().total
        let photoLibraryIndexedCount = try database.photoLibraryIndexedMediaCounts().total

        XCTAssertEqual(allIndexedCount, 10)
        XCTAssertEqual(photoLibraryIndexedCount, 1)
        XCTAssertTrue(OrphanCleanupSafetyPolicy.exceedsSafetyThreshold(
            candidateRemovalCount: 1,
            photoLibraryIndexedCount: photoLibraryIndexedCount
        ))
        XCTAssertFalse(OrphanCleanupSafetyPolicy.exceedsSafetyThreshold(
            candidateRemovalCount: 1,
            photoLibraryIndexedCount: allIndexedCount
        ), "This demonstrates why folder-backed rows must not be used as the denominator")
    }

    func testProUnlockRecoveryStartsLibraryIndexingOnlyWhenSafeAndNotAlreadyQueued() {
        XCTAssertTrue(ProUnlockIndexingRecoveryPolicy.shouldStartLibraryIndexing(
            isMemoryPressureSuspended: false,
            hasLibraryIndexingWork: false
        ))
        XCTAssertFalse(ProUnlockIndexingRecoveryPolicy.shouldStartLibraryIndexing(
            isMemoryPressureSuspended: true,
            hasLibraryIndexingWork: false
        ))
        XCTAssertFalse(ProUnlockIndexingRecoveryPolicy.shouldStartLibraryIndexing(
            isMemoryPressureSuspended: false,
            hasLibraryIndexingWork: true
        ))
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
                return FolderScanner.ScanResult(imageURLs: [], isComplete: false)
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

    @MainActor
    func testPhotoEnrichmentBatchPrefetchesPhotoKitAssetsBeforeProcessing() async {
        let photoKitCandidate = PhotoEnrichmentCandidate(
            localIdentifier: "photo-1",
            pixelWidth: 100,
            pixelHeight: 100,
            sourceId: PhotoSourceType.photokit.rawValue,
            filePath: nil
        )
        let folderCandidate = PhotoEnrichmentCandidate(
            localIdentifier: "folder-1",
            pixelWidth: 100,
            pixelHeight: 100,
            sourceId: "folder-source",
            filePath: "/tmp/folder-1.jpg"
        )
        var events: [String] = []

        let updates = await PhotoEnrichmentBatchOperation.run(
            candidates: [photoKitCandidate, folderCandidate],
            prefetchPhotoKitAssets: { identifiers in
                events.append("prefetch:\(identifiers.joined(separator: ","))")
            },
            enrich: { candidate in
                events.append("enrich:\(candidate.localIdentifier)")
                return PhotoEnrichmentUpdate(
                    localIdentifier: candidate.localIdentifier,
                    ocrText: nil,
                    sharpnessScore: 1,
                    sceneLabels: nil
                )
            }
        )

        XCTAssertEqual(events, ["prefetch:photo-1", "enrich:photo-1", "enrich:folder-1"])
        XCTAssertEqual(updates?.map(\.localIdentifier), ["photo-1", "folder-1"])
    }

    @MainActor
    func testCancelledPhotoEnrichmentBatchSkipsPrefetchAndProcessing() async {
        let candidate = PhotoEnrichmentCandidate(
            localIdentifier: "photo-1",
            pixelWidth: 100,
            pixelHeight: 100,
            sourceId: PhotoSourceType.photokit.rawValue,
            filePath: nil
        )
        var events: [String] = []
        let task = Task { @MainActor in
            await PhotoEnrichmentBatchOperation.run(
                candidates: [candidate],
                prefetchPhotoKitAssets: { _ in events.append("prefetch") },
                enrich: { _ in
                    events.append("enrich")
                    return nil
                }
            )
        }

        task.cancel()
        let updates = await task.value

        XCTAssertNil(updates)
        XCTAssertTrue(events.isEmpty)
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

    func testProUsersCanIndexBeyondResidentSearchWindow() {
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia, isPro: true))
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: 8_000, isPro: true))
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: 80_000, isPro: true))
    }

    func testFreeUsersCanIndexBelowLimit() {
        XCTAssertTrue(FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia - 1, isPro: false))
    }

    func testAutomaticBackgroundWorkUsesPostLaunchDeferral() {
        XCTAssertGreaterThan(IndexingConfig.postLaunchAutoResumeDelaySeconds, 0)
        XCTAssertGreaterThan(IndexingConfig.surpriseValidationDelaySeconds, 0)
        XCTAssertGreaterThan(IndexingConfig.userSearchBackgroundWorkDelaySeconds, 0)
        XCTAssertGreaterThan(IndexingConfig.geocodingProgressPublishIntervalSeconds, 0)
    }

    func testGeocodingProgressPublicationIsThrottled() {
        XCTAssertFalse(GeocodingProgressPublicationPolicy.shouldPublish(elapsed: 0))
        XCTAssertFalse(GeocodingProgressPublicationPolicy.shouldPublish(
            elapsed: IndexingConfig.geocodingProgressPublishIntervalSeconds / 2
        ))
        XCTAssertTrue(GeocodingProgressPublicationPolicy.shouldPublish(
            elapsed: IndexingConfig.geocodingProgressPublishIntervalSeconds
        ))
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

    func testSearchSuggestionsStayHiddenUntilVideoIndexingFinishes() {
        let videoProgress = IndexingProgress(
            total: 100,
            completed: 80,
            isRunning: true,
            phase: .videos,
            photosComplete: true,
            searchableCount: 70
        )
        let idleProgress = IndexingProgress(
            total: 100,
            completed: 100,
            isRunning: false,
            phase: .idle,
            photosComplete: true,
            searchableCount: 100
        )

        XCTAssertFalse(SearchSuggestionVisibilityPolicy.shouldShow(
            indexingProgress: videoProgress,
            isReady: true,
            hasValidatedSuggestions: true
        ))
        XCTAssertTrue(SearchSuggestionVisibilityPolicy.shouldShow(
            indexingProgress: idleProgress,
            isReady: true,
            hasValidatedSuggestions: true
        ))
        XCTAssertFalse(SearchSuggestionVisibilityPolicy.shouldShow(
            indexingProgress: idleProgress,
            isReady: false,
            hasValidatedSuggestions: true
        ))
        XCTAssertFalse(SearchSuggestionVisibilityPolicy.shouldShow(
            indexingProgress: idleProgress,
            isReady: true,
            hasValidatedSuggestions: false
        ))
    }

    func testInitialIndexingExperienceBeginsOnlyWithoutAKnownIndex() {
        XCTAssertTrue(InitialIndexingExperiencePolicy.shouldBegin(
            hasKnownExistingIndex: false,
            hasCompletedInitialExperience: false,
            isReady: false,
            searchableCount: 0
        ))
        XCTAssertFalse(InitialIndexingExperiencePolicy.shouldBegin(
            hasKnownExistingIndex: true,
            hasCompletedInitialExperience: false,
            isReady: false,
            searchableCount: 0
        ))
        XCTAssertFalse(InitialIndexingExperiencePolicy.shouldBegin(
            hasKnownExistingIndex: false,
            hasCompletedInitialExperience: false,
            isReady: true,
            searchableCount: 1
        ))
        XCTAssertFalse(InitialIndexingExperiencePolicy.shouldBegin(
            hasKnownExistingIndex: false,
            hasCompletedInitialExperience: true,
            isReady: false,
            searchableCount: 0
        ))
    }

    func testInitialIndexingExperienceStaysVisibleBetweenBaseIndexingAndEnrichment() {
        XCTAssertTrue(InitialIndexingExperiencePolicy.shouldShow(
            isInitialLibraryWorkflowActive: true
        ))
        XCTAssertFalse(InitialIndexingExperiencePolicy.shouldShow(
            isInitialLibraryWorkflowActive: false
        ))
    }

    @MainActor
    func testInitialPresentationSurvivesBaseProgressCompletion() {
        let suiteName = "InitialIndexingServiceTransitionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = makeSurpriseLaunchService(
            database: SearchFixtureDatabase(),
            cachedState: SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 0
            ),
            initialIndexingDefaults: defaults
        )
        service.startIndexing()

        service.progress = IndexingProgress(
            total: 100,
            completed: 100,
            isRunning: false,
            phase: .photos,
            photosComplete: true,
            searchableCount: 100
        )

        XCTAssertFalse(service.progress.isRunning)
        XCTAssertTrue(service.isInitialLibraryIndexingActive)
        XCTAssertTrue(service.shouldShowInitialIndexingExperience)
        service.stopIndexing()
    }

    func testInitialIndexingExperienceStorePersistsPendingAndCompletionState() {
        let suiteName = "InitialIndexingExperienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(InitialIndexingExperienceStore.isPending(in: defaults))
        XCTAssertFalse(InitialIndexingExperienceStore.isCompleted(in: defaults))
        InitialIndexingExperienceStore.begin(in: defaults)
        XCTAssertTrue(InitialIndexingExperienceStore.isPending(in: defaults))
        XCTAssertFalse(InitialIndexingExperienceStore.isCompleted(in: defaults))
        InitialIndexingExperienceStore.complete(in: defaults)
        XCTAssertFalse(InitialIndexingExperienceStore.isPending(in: defaults))
        XCTAssertTrue(InitialIndexingExperienceStore.isCompleted(in: defaults))
    }

    func testPendingInitialIndexWithoutPersistedRowsRequiresLaunchResume() {
        XCTAssertTrue(InitialIndexingExperiencePolicy.shouldResumePendingRun(
            scheduleAutoResume: true,
            didLoadIndex: false,
            isPending: true
        ))
        XCTAssertFalse(InitialIndexingExperiencePolicy.shouldResumePendingRun(
            scheduleAutoResume: true,
            didLoadIndex: true,
            isPending: true
        ))
        XCTAssertFalse(InitialIndexingExperiencePolicy.shouldResumePendingRun(
            scheduleAutoResume: false,
            didLoadIndex: false,
            isPending: true
        ))
    }
}

private enum SurpriseLaunchTestError: Error {
    case revisionUnavailable
}

private final class UnusedImagePredictionModel: CoreMLModelPredicting {
    private enum PredictionError: Error {
        case unexpectedlyInvoked
    }

    func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
        throw PredictionError.unexpectedlyInvoked
    }

    func predictions(
        from inputBatch: MLBatchProvider,
        options: MLPredictionOptions
    ) throws -> MLBatchProvider {
        throw PredictionError.unexpectedlyInvoked
    }
}

private func makeOrphanPolicyPhoto(
    localIdentifier: String,
    sourceId: String = PhotoSourceType.photokit.rawValue,
    filePath: String? = nil
) -> IndexedPhoto {
    var embedding = [Float](repeating: 0, count: EmbeddingConfig.dimensions)
    embedding[0] = 1
    return IndexedPhoto(
        id: UUID().uuidString,
        localIdentifier: localIdentifier,
        creationDate: Date(timeIntervalSince1970: 100),
        latitude: nil,
        longitude: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        embedding: embedding.toFloat16Data(),
        indexedAt: Date(timeIntervalSince1970: 200),
        sourceId: sourceId,
        filePath: filePath
    )
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
