import XCTest
import GRDB
import CoreML
import CoreLocation
import os
@testable import Memorable

final class IndexingPolicyTests: XCTestCase {
    func testIndexingHomeShowsSlideshowThroughInitialWorkflowAndReindexing() {
        // First-run presentation must survive gaps between indexing phases.
        XCTAssertTrue(IndexingHomePresentationPolicy.showsSlideshow(
            isInitialLibraryWorkflowActive: true,
            isRunning: false, isPaused: false, hasQuery: false
        ))
        // Later runs must not fall through to the empty/home library count.
        XCTAssertTrue(IndexingHomePresentationPolicy.showsSlideshow(
            isInitialLibraryWorkflowActive: false,
            isRunning: true, isPaused: false, hasQuery: false
        ))
        XCTAssertTrue(IndexingHomePresentationPolicy.showsSlideshow(
            isInitialLibraryWorkflowActive: false,
            isRunning: false, isPaused: true, hasQuery: false
        ))
        // Completion or an explicit stop returns to the regular home screen.
        XCTAssertFalse(IndexingHomePresentationPolicy.showsSlideshow(
            isInitialLibraryWorkflowActive: false,
            isRunning: false, isPaused: false, hasQuery: false
        ))
    }

    func testIndexingSlideshowDoesNotCoverQueriesDuringLaterRuns() {
        for isPaused in [false, true] {
            XCTAssertFalse(IndexingHomePresentationPolicy.showsSlideshow(
                isInitialLibraryWorkflowActive: false,
                isRunning: !isPaused, isPaused: isPaused, hasQuery: true
            ))
        }
        // Initial setup retains its existing presentation until ready.
        XCTAssertTrue(IndexingHomePresentationPolicy.showsSlideshow(
            isInitialLibraryWorkflowActive: true,
            isRunning: true, isPaused: false, hasQuery: true
        ))
    }

    func testCompletenessComparesIdentityAndModificationDates() {
        let indexedAt = Date(timeIntervalSince1970: 100)
        let indexed = ["old": IndexedMediaVersion(id: "stable", indexedAt: indexedAt)]
        XCTAssertFalse(PhotoLibraryChangeReconciler.needsIndexing(
            assets: [.init(localIdentifier: "old", modifiedAt: indexedAt)], indexed: indexed
        ))
        // Same count, different asset: a closed-app delete/add must resume.
        XCTAssertTrue(PhotoLibraryChangeReconciler.needsIndexing(
            assets: [.init(localIdentifier: "replacement", modifiedAt: indexedAt)], indexed: indexed
        ))
        XCTAssertTrue(PhotoLibraryChangeReconciler.needsIndexing(
            assets: [.init(localIdentifier: "old", modifiedAt: indexedAt.addingTimeInterval(1))], indexed: indexed
        ))
        XCTAssertFalse(PhotoLibraryChangeReconciler.needsIndexing(
            assets: [.init(localIdentifier: "old", modifiedAt: nil)], indexed: indexed
        ))
    }

    func testFullFreeTierCanRefreshRetainedMediaWithoutAddingItems() {
        let indexedAt = Date(timeIntervalSince1970: 100)
        let indexed = IndexedMediaVersion(id: "retained", indexedAt: indexedAt)
        let canAdd = FreeTier.canIndexMore(indexedMediaCount: FreeTier.maxIndexedMedia, isPro: false)
        XCTAssertFalse(canAdd)
        XCTAssertEqual(IndexedMediaFreshness.selection(
            indexed: indexed, modifiedAt: indexedAt.addingTimeInterval(1), forced: false, canAddMedia: canAdd
        ), .replace)
        XCTAssertEqual(IndexedMediaFreshness.selection(
            indexed: indexed, modifiedAt: nil, forced: true, canAddMedia: canAdd
        ), .replace)
        XCTAssertEqual(IndexedMediaFreshness.selection(
            indexed: indexed, modifiedAt: indexedAt, forced: false, canAddMedia: canAdd
        ), .skip)
        XCTAssertEqual(IndexedMediaFreshness.selection(
            indexed: nil, modifiedAt: indexedAt, forced: true, canAddMedia: canAdd
        ), .skip)
    }

    func testEditsDuringIndexingRemainNewerThanPassStart() {
        let passStartedAt = Date(timeIntervalSince1970: 100)
        let editedWhileEncoding = passStartedAt.addingTimeInterval(1)
        XCTAssertTrue(IndexedMediaFreshness.needsRefresh(
            modifiedAt: editedWhileEncoding, indexedAt: passStartedAt
        ))
    }

    func testChangedPhotoEventsSurviveCoalescingAndRespectRemoval() throws {
        var event = PhotoLibraryChangeEvent(changedPhotoIDs: ["edited", "removed"], changedVideoIDs: ["video"])
        XCTAssertTrue(event.hasWork)
        event.merge(PhotoLibraryChangeEvent(removedPhotoIDs: ["removed"], changedPhotoIDs: ["second"]))
        event.merge(PhotoLibraryChangeEvent(changedPhotoIDs: ["removed"]))
        XCTAssertEqual(event.changedPhotoIDs, ["edited", "second"])
        XCTAssertEqual(event.changedVideoIDs, ["video"])
        let database = AppDatabase(openQueue: { try DatabaseQueue() },
                                   migrate: { try AppDatabase.migrator.migrate($0) })
        let result = try PhotoLibraryChangeReconciler.reconcile(event, database: database, authorizationStatus: .limited)
        XCTAssertTrue(result.hasNewMedia)
        XCTAssertEqual(result.changedPhotoIDs, event.changedPhotoIDs)
        XCTAssertEqual(result.changedVideoIDs, ["video"])
        XCTAssertTrue(result.orphanedPhotoIDs.isEmpty)
    }

    func testCommittedReplacementRemainsObservableAfterCancellation() async throws {
        let entered = expectation(description: "replacement entered")
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (committed: false, observed: false))
        let task = Task {
            try await IndexedMediaReplacementOperation.run {
                entered.fulfill()
                release.wait()
                state.withLock { $0.committed = true }
            }
            state.withLock { $0.observed = true }
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        release.signal()
        try await task.value
        XCTAssertTrue(state.withLock { $0.committed })
        XCTAssertTrue(state.withLock { $0.observed })
    }

    func testBackgroundIndexingIdentifiersStayBundleScoped() {
        let bundleIdentifier = "com.example.memorable"
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        XCTAssertEqual(
            BackgroundIndexingIdentifiers.processing(bundleIdentifier: bundleIdentifier),
            "com.example.memorable.indexing.processing"
        )
        XCTAssertEqual(
            BackgroundIndexingIdentifiers.continuedWildcard(bundleIdentifier: bundleIdentifier),
            "com.example.memorable.indexing.continued.*"
        )
        XCTAssertEqual(
            BackgroundIndexingIdentifiers.continued(
                bundleIdentifier: bundleIdentifier,
                runID: runID
            ),
            "com.example.memorable.indexing.continued.00000000-0000-0000-0000-000000000123"
        )
    }

    func testForegroundResumeRequiresPendingIdleInitialIndex() {
        XCTAssertTrue(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: true,
            hasCompletedInitialIndexCheck: true,
            allowsAutoResume: true,
            isPending: true,
            progressIsRunning: false,
            hasLibraryWork: false
        ))
        XCTAssertFalse(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: false,
            hasCompletedInitialIndexCheck: true,
            allowsAutoResume: true,
            isPending: true,
            progressIsRunning: false,
            hasLibraryWork: false
        ))
        XCTAssertFalse(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: true,
            hasCompletedInitialIndexCheck: true,
            allowsAutoResume: true,
            isPending: false,
            progressIsRunning: false,
            hasLibraryWork: false
        ))
        XCTAssertFalse(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: true,
            hasCompletedInitialIndexCheck: true,
            allowsAutoResume: true,
            isPending: true,
            progressIsRunning: true,
            hasLibraryWork: false
        ))
        XCTAssertFalse(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: true,
            hasCompletedInitialIndexCheck: true,
            allowsAutoResume: true,
            isPending: true,
            progressIsRunning: false,
            hasLibraryWork: true
        ))
        XCTAssertFalse(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: true,
            hasCompletedInitialIndexCheck: false,
            allowsAutoResume: true,
            isPending: true,
            progressIsRunning: false,
            hasLibraryWork: false
        ))
        XCTAssertFalse(InitialIndexingForegroundResumePolicy.shouldSchedule(
            isApplicationActive: true,
            hasCompletedInitialIndexCheck: true,
            allowsAutoResume: false,
            isPending: true,
            progressIsRunning: false,
            hasLibraryWork: false
        ))
    }

    func testForegroundSemanticWarmupRequiresActiveReadyShellAndUnreadySearch() {
        XCTAssertTrue(ForegroundSemanticWarmupPolicy.shouldStart(
            isApplicationActive: true,
            isShellReady: true,
            isSemanticSearchReady: false
        ))
        XCTAssertFalse(ForegroundSemanticWarmupPolicy.shouldStart(
            isApplicationActive: false,
            isShellReady: true,
            isSemanticSearchReady: false
        ))
        XCTAssertFalse(ForegroundSemanticWarmupPolicy.shouldStart(
            isApplicationActive: true,
            isShellReady: false,
            isSemanticSearchReady: false
        ))
        XCTAssertFalse(ForegroundSemanticWarmupPolicy.shouldStart(
            isApplicationActive: true,
            isShellReady: true,
            isSemanticSearchReady: true
        ))
    }

    func testBackgroundTimePolicyStopsBeforeOrdinaryAssertionExpires() {
        XCTAssertTrue(IndexingBackgroundTimePolicy.canStartNextBatch(
            isApplicationActive: true,
            hasScheduledTaskAssertion: false,
            backgroundTimeRemaining: 0
        ))
        XCTAssertTrue(IndexingBackgroundTimePolicy.canStartNextBatch(
            isApplicationActive: false,
            hasScheduledTaskAssertion: true,
            backgroundTimeRemaining: 0
        ))
        XCTAssertTrue(IndexingBackgroundTimePolicy.canStartNextBatch(
            isApplicationActive: false,
            hasScheduledTaskAssertion: false,
            backgroundTimeRemaining: .greatestFiniteMagnitude
        ))
        XCTAssertFalse(IndexingBackgroundTimePolicy.canStartNextBatch(
            isApplicationActive: false,
            hasScheduledTaskAssertion: false,
            backgroundTimeRemaining: IndexingBackgroundTimePolicy.minimumRemainingSeconds - 0.1
        ))
    }

    func testPostIndexingWorkDefersWheneverTheApplicationIsInactive() {
        XCTAssertFalse(PostIndexingContinuationPolicy.shouldDeferUntilForeground(
            isApplicationActive: true
        ))
        XCTAssertTrue(PostIndexingContinuationPolicy.shouldDeferUntilForeground(
            isApplicationActive: false
        ))
        XCTAssertEqual(
            PostIndexingContinuationPolicy.dependencies(
                isDeferredUntilAfterBaseCompletion: false
            ),
            [.indexVideos]
        )
        XCTAssertEqual(
            PostIndexingContinuationPolicy.dependencies(
                isDeferredUntilAfterBaseCompletion: true
            ),
            []
        )
    }

    func testAutomaticMaintenanceRequiresEveryLifecycleSafetyCondition() {
        XCTAssertTrue(AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: true,
            allowsIndexingWrites: true,
            isMemoryPressureSuspended: false,
            isThermallySafe: true,
            isTaskCancelled: false
        ))
        XCTAssertFalse(AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: false,
            allowsIndexingWrites: true,
            isMemoryPressureSuspended: false,
            isThermallySafe: true,
            isTaskCancelled: false
        ))
        XCTAssertFalse(AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: true,
            allowsIndexingWrites: false,
            isMemoryPressureSuspended: false,
            isThermallySafe: true,
            isTaskCancelled: false
        ))
        XCTAssertFalse(AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: true,
            allowsIndexingWrites: true,
            isMemoryPressureSuspended: true,
            isThermallySafe: true,
            isTaskCancelled: false
        ))
        XCTAssertFalse(AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: true,
            allowsIndexingWrites: true,
            isMemoryPressureSuspended: false,
            isThermallySafe: false,
            isTaskCancelled: false
        ))
        XCTAssertFalse(AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: true,
            allowsIndexingWrites: true,
            isMemoryPressureSuspended: false,
            isThermallySafe: true,
            isTaskCancelled: true
        ))
    }

    func testScheduledExpirationInterruptsOnlyInactivePendingInitialIndexing() {
        XCTAssertTrue(ScheduledInitialIndexingExpirationPolicy.shouldInterrupt(
            isApplicationActive: false,
            isInitialIndexingPending: true
        ))
        XCTAssertFalse(ScheduledInitialIndexingExpirationPolicy.shouldInterrupt(
            isApplicationActive: true,
            isInitialIndexingPending: true
        ))
        XCTAssertFalse(ScheduledInitialIndexingExpirationPolicy.shouldInterrupt(
            isApplicationActive: false,
            isInitialIndexingPending: false
        ))
    }

    func testInitialIndexingInterruptionMarkerRoundTripsAndClears() {
        let suiteName = "InitialIndexingInterruptionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(InitialIndexingInterruptionStore.wasInterrupted(in: defaults))
        InitialIndexingInterruptionStore.markInterrupted(in: defaults)
        XCTAssertTrue(InitialIndexingInterruptionStore.wasInterrupted(in: defaults))
        InitialIndexingInterruptionStore.clear(in: defaults)
        XCTAssertFalse(InitialIndexingInterruptionStore.wasInterrupted(in: defaults))
    }

    func testContinuedProcessingProgressAllocatesPhotosBeforeVideos() {
        XCTAssertEqual(
            ContinuedIndexingProgress.completedUnits(for: IndexingProgress(
                total: 100,
                completed: 50,
                isRunning: true,
                phase: .photos
            )),
            375
        )
        XCTAssertEqual(
            ContinuedIndexingProgress.completedUnits(for: IndexingProgress(
                total: 20,
                completed: 10,
                isRunning: true,
                phase: .videos,
                photosComplete: true
            )),
            875
        )
    }

    func testPhotoLibraryWorkerStopsAtEveryRejectedBatchBoundary() {
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldInterruptBeforeNextBatch(
            canStartNextBatch: true
        ))
        XCTAssertTrue(PhotoLibraryIndexingWorker.shouldInterruptBeforeNextBatch(
            canStartNextBatch: false
        ))
    }

    @MainActor
    func testPhotoLibraryWorkerPersistsBufferedRowsBeforeCooperativeInterruption() async {
        let photo = makeOrphanPolicyPhoto(localIdentifier: "buffered-photo")
        var receivedIdentifiers: [String] = []

        let persistedCount = await PhotoLibraryIndexingWorker.persistInterruptedPhotoBatch(
            [photo]
        ) { photos in
            receivedIdentifiers = photos.map(\.localIdentifier)
            return photos.count
        }

        XCTAssertEqual(persistedCount, 1)
        XCTAssertEqual(receivedIdentifiers, ["buffered-photo"])
    }

    @MainActor
    func testPhotoLibraryWorkerSkipsPersistenceWhenInterruptedBufferIsEmpty() async {
        var didPersist = false

        let persistedCount = await PhotoLibraryIndexingWorker.persistInterruptedPhotoBatch([]) { photos in
            didPersist = true
            return photos.count
        }

        XCTAssertEqual(persistedCount, 0)
        XCTAssertFalse(didPersist)
    }

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

    func testDeferredPostIndexingWorkflowCountsAsActiveThermalWork() {
        XCTAssertTrue(ThermalWorkActivityPolicy.hasActiveWork(
            isJobQueueIdle: true,
            isProgressRunning: false,
            hasDeferredPostIndexingWorkflow: true
        ))
        XCTAssertFalse(ThermalWorkActivityPolicy.hasActiveWork(
            isJobQueueIdle: true,
            isProgressRunning: false,
            hasDeferredPostIndexingWorkflow: false
        ))

        let transition = ThermalSafetyPolicy.transition(
            from: ThermalIndexingState(),
            thermalState: .serious,
            hasActiveWork: ThermalWorkActivityPolicy.hasActiveWork(
                isJobQueueIdle: true,
                isProgressRunning: false,
                hasDeferredPostIndexingWorkflow: true
            )
        )
        XCTAssertEqual(transition.effect, .cancelWork)
        XCTAssertTrue(transition.state.resumeWhenCool)
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
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldFinalizePhotoPass(
            isCancelled: true,
            wasInterrupted: false
        ))
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldFinalizePhotoPass(
            isCancelled: false,
            wasInterrupted: true
        ))
        XCTAssertTrue(PhotoLibraryIndexingWorker.shouldFinalizePhotoPass(
            isCancelled: false,
            wasInterrupted: false
        ))
    }

    func testCancelledVideoPassDoesNotReloadOrPublishCompletion() {
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldFinalizeVideoPass(
            isCancelled: true,
            wasInterrupted: false
        ))
        XCTAssertFalse(PhotoLibraryIndexingWorker.shouldFinalizeVideoPass(
            isCancelled: false,
            wasInterrupted: true
        ))
        XCTAssertTrue(PhotoLibraryIndexingWorker.shouldFinalizeVideoPass(
            isCancelled: false,
            wasInterrupted: false
        ))
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
    func testIncompleteGeocodingIsVisibleAsSoonAsExistingIndexLoads() async {
        let database = SearchFixtureDatabase(
            photos: [surpriseFixturePhoto()],
            geocodingCounts: GeocodingCounts(
                totalWithGPS: 10,
                remaining: 4,
                indexedPhotos: 1,
                indexedVideos: 0
            )
        )
        let service = makeSurpriseLaunchService(
            database: database,
            cachedState: SurpriseQueryCache.State(
                validatedQueries: [],
                lastValidatedCount: 0
            )
        )

        let loaded = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: true,
            scheduleOrphanCleanup: false
        )

        XCTAssertTrue(loaded)
        XCTAssertEqual(service.geocodingProgress?.completed, 6)
        XCTAssertEqual(service.geocodingProgress?.total, 10)
        XCTAssertEqual(service.geocodingProgress?.phase, .queued)
        service.stopIndexing()
    }

    @MainActor
    func testGeocodingWaitsForActivationCancelsOnBackgroundAndResumesOnce() async throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var photo = makeOrphanPolicyPhoto(localIdentifier: "location-photo")
        photo.latitude = 48.8566
        photo.longitude = 2.3522
        try database.insertPhoto(photo)
        let backend = LifecycleLocationGeocoder()
        let worker = GeocodingWorker(
            database: database,
            reverseGeocoder: ReverseGeocoder(geocoder: backend, throttleNanoseconds: 0)
        )
        let searchEngine = SearchEngine(
            textEncoder: FakeTextEncoder([:]),
            database: database
        )
        let service = IndexingService(
            imageEncoder: ImageEncoder(model: UnusedImagePredictionModel()),
            searchEngine: searchEngine,
            database: database,
            surpriseQueryCacheLoader: {
                SurpriseQueryCache.State(validatedQueries: [], lastValidatedCount: 0)
            },
            geocodingWorker: worker
        )

        let loaded = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: false,
            scheduleOrphanCleanup: false
        )
        for _ in 0..<100 { await Task.yield() }

        XCTAssertTrue(loaded)
        XCTAssertEqual(backend.requestCount, 0)
        XCTAssertEqual(service.geocodingProgress?.phase, .waitingToResume)

        service.setApplicationActive(true)
        for _ in 0..<2_000 where backend.requestCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(backend.requestCount, 1)
        service.setApplicationActive(false)
        for _ in 0..<2_000 where backend.cancelCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(service.geocodingProgress?.phase, .waitingToResume)

        service.setApplicationActive(true)
        for _ in 0..<2_000 where backend.requestCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(backend.requestCount, 2)
        for _ in 0..<2_000 where service.geocodingProgress != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(service.geocodingProgress)
        XCTAssertEqual(try database.geocodingCounts().remaining, 0)
        service.stopIndexing()
    }

    @MainActor
    func testVideoGeocodingCancellationKeepsWaitingToResumePhase() async throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let video = makeGeocodingPolicyVideo(localIdentifier: "location-video")
        try database.insertVideo(
            video,
            [IndexedVideoFrame(
                id: UUID().uuidString,
                videoId: video.id,
                framePosition: 0.5,
                embedding: {
                    var embedding = [Float](repeating: 0, count: EmbeddingConfig.dimensions)
                    embedding[0] = 1
                    return embedding.toFloat16Data()
                }(),
                indexedAt: Date()
            )],
            completingRequiredRebuild: false
        )
        let backend = LifecycleLocationGeocoder()
        let service = IndexingService(
            imageEncoder: ImageEncoder(model: UnusedImagePredictionModel()),
            searchEngine: SearchEngine(textEncoder: FakeTextEncoder([:]), database: database),
            database: database,
            surpriseQueryCacheLoader: {
                SurpriseQueryCache.State(validatedQueries: [], lastValidatedCount: 0)
            },
            geocodingWorker: GeocodingWorker(
                database: database,
                reverseGeocoder: ReverseGeocoder(geocoder: backend, throttleNanoseconds: 0)
            )
        )

        let loaded = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: false,
            scheduleOrphanCleanup: false
        )
        XCTAssertTrue(loaded)
        service.setApplicationActive(true)
        for _ in 0..<2_000 where backend.requestCount == 0 { await Task.yield() }
        XCTAssertEqual(backend.requestCount, 1)

        service.setApplicationActive(false)
        for _ in 0..<2_000 where backend.cancelCount == 0 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(service.geocodingProgress?.phase, .waitingToResume)
        service.stopIndexing()
    }

    @MainActor
    func testGeocodingPausesAfterBoundedAutomaticRetries() async throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var photo = makeOrphanPolicyPhoto(localIdentifier: "unresolved-photo")
        photo.latitude = 0
        photo.longitude = 0
        try database.insertPhoto(photo)
        let backend = AlwaysTransientLocationGeocoder()
        let worker = GeocodingWorker(
            database: database,
            reverseGeocoder: ReverseGeocoder(geocoder: backend, throttleNanoseconds: 0)
        )
        let service = IndexingService(
            imageEncoder: ImageEncoder(model: UnusedImagePredictionModel()),
            searchEngine: SearchEngine(
                textEncoder: FakeTextEncoder([:]),
                database: database
            ),
            database: database,
            surpriseQueryCacheLoader: {
                SurpriseQueryCache.State(validatedQueries: [], lastValidatedCount: 0)
            },
            geocodingWorker: worker,
            geocodingRetryDelaySeconds: { _ in 0 }
        )

        let loaded = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: false,
            scheduleOrphanCleanup: false
        )
        XCTAssertTrue(loaded)
        service.setApplicationActive(true)
        for _ in 0..<20_000 where service.geocodingProgress?.phase != .paused {
            await Task.yield()
        }

        XCTAssertEqual(service.geocodingProgress?.phase, .paused)
        XCTAssertEqual(
            backend.requestCount,
            GeocodingRetryPolicy.maximumAutomaticAttempts + 1
        )
        service.stopIndexing()
    }

    @MainActor
    func testSuccessfulGeocodingRunResetsAutomaticRetryBudget() async throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        var permanentMiss = makeOrphanPolicyPhoto(localIdentifier: "a-permanent")
        permanentMiss.latitude = 0
        permanentMiss.longitude = 0
        var eventuallyResolved = makeOrphanPolicyPhoto(localIdentifier: "b-eventual")
        eventuallyResolved.latitude = 10
        eventuallyResolved.longitude = 10
        try database.insertPhotos(
            [permanentMiss, eventuallyResolved],
            completingRequiredRebuild: false
        )
        let backend = RetryResetLocationGeocoder()
        let worker = GeocodingWorker(
            database: database,
            reverseGeocoder: ReverseGeocoder(geocoder: backend, throttleNanoseconds: 0)
        )
        let service = IndexingService(
            imageEncoder: ImageEncoder(model: UnusedImagePredictionModel()),
            searchEngine: SearchEngine(textEncoder: FakeTextEncoder([:]), database: database),
            database: database,
            surpriseQueryCacheLoader: {
                SurpriseQueryCache.State(validatedQueries: [], lastValidatedCount: 0)
            },
            geocodingWorker: worker,
            geocodingRetryDelaySeconds: { _ in 0 }
        )

        let loaded = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: false,
            scheduleOrphanCleanup: false
        )
        XCTAssertTrue(loaded)
        service.setApplicationActive(true)
        for _ in 0..<40_000 where service.geocodingProgress?.phase != .paused {
            await Task.yield()
        }

        XCTAssertEqual(service.geocodingProgress?.phase, .paused)
        XCTAssertEqual(backend.eventualRequestCount, 4)
        XCTAssertEqual(backend.permanentRequestCount, 9)
        service.stopIndexing()
    }

    func testCompletedGeocodingDoesNotProduceVisibleProgress() {
        XCTAssertNil(GeocodingProgressState(
            counts: GeocodingCounts(
                totalWithGPS: 10,
                remaining: 0,
                indexedPhotos: 10,
                indexedVideos: 0
            ),
            phase: .queued
        ))
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
    func testBackgroundInterruptionKeepsResumeIntentAndForegroundRestartsIt() async {
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
        _ = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: true,
            scheduleOrphanCleanup: false
        )
        service.startIndexing()
        XCTAssertTrue(service.isInitialLibraryIndexingActive)

        service.handleBackgroundTaskExpiration()

        XCTAssertTrue(service.isInitialIndexingExperiencePending)
        XCTAssertFalse(service.isInitialLibraryIndexingActive)
        XCTAssertEqual(service.backgroundExecutionState, .pausedAwaitingForeground)
        XCTAssertTrue(InitialIndexingInterruptionStore.wasInterrupted(in: defaults))
        XCTAssertFalse(service.shouldShowInitialIndexingExperience)

        service.setApplicationActive(true)

        XCTAssertEqual(service.backgroundExecutionState, .foreground)
        XCTAssertTrue(service.progress.isRunning)
        XCTAssertFalse(InitialIndexingInterruptionStore.wasInterrupted(in: defaults))
        service.stopIndexing()
    }

    @MainActor
    func testScheduledExpirationAfterForegroundDoesNotPauseInitialIndexing() async {
        let suiteName = "InitialIndexingServiceForegroundExpirationTests.\(UUID().uuidString)"
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
        _ = await service.checkAndLoadExistingIndex(
            scheduleAutoResume: true,
            scheduleOrphanCleanup: false
        )
        service.setApplicationActive(true)
        service.startIndexing()

        service.handleScheduledBackgroundTaskExpiration()

        XCTAssertTrue(service.isInitialIndexingExperiencePending)
        XCTAssertTrue(service.isInitialLibraryIndexingActive)
        XCTAssertEqual(service.backgroundExecutionState, .foreground)
        XCTAssertFalse(InitialIndexingInterruptionStore.wasInterrupted(in: defaults))
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
    func testCommittedIndexResetPublishesHistoryResetBeforeCancellationStopsReindexing() async throws {
        let database = AppDatabase(openQueue: { try DatabaseQueue() },
                                   migrate: { try AppDatabase.migrator.migrate($0) })
        try database.insertPhoto(makeOrphanPolicyPhoto(localIdentifier: "before-reset"))
        try database.addSearchHistory("old query")
        let engine = SearchEngine(textEncoder: FakeTextEncoder([:]), database: database)
        let service = IndexingService(
            imageEncoder: ImageEncoder(model: UnusedImagePredictionModel()),
            searchEngine: engine, database: database
        )
        var events: [String] = []
        service.onIndexResetStarted = { events.append("started") }
        service.onIndexResetFinished = { didReset in
            events.append(didReset ? "committed" : "failed")
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let reset = Task { try await service.rebuildLibraryIndex() }
        do {
            try await reset.value
            XCTFail("Cancellation must stop the subsequent reindex")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(events, ["started", "committed"])
        XCTAssertTrue(try database.loadSearchHistory().isEmpty)
        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertTrue(service.indexRebuildRequired)
        XCTAssertFalse(service.isReady)
        XCTAssertFalse(service.progress.isRunning)
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

        XCTAssertEqual(events.first, "prefetch:photo-1")
        XCTAssertEqual(Set(events.dropFirst()), ["enrich:photo-1", "enrich:folder-1"])
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

    func testEnrichmentNeverTakesOverTheSearchHome() {
        for initial in [false, true] {
            for query in [false, true] {
                XCTAssertFalse(IndexingHomePresentationPolicy.showsSlideshow(
                    isInitialLibraryWorkflowActive: initial,
                    isRunning: true,
                    isPaused: false,
                    hasQuery: query,
                    phase: .enrichment
                ))
            }
        }
    }

    @MainActor
    func testPhotoEnrichmentKeepsCompletedWorkWhenCancelled() async {
        let secondStarted = expectation(description: "second photo started")
        let candidates = (0..<3).map {
            PhotoEnrichmentCandidate(localIdentifier: "photo-\($0)", pixelWidth: 100,
                                     pixelHeight: 100, sourceId: "folder", filePath: nil)
        }
        let task = Task {
            await PhotoEnrichmentBatchOperation.run(
                candidates: candidates,
                prefetchPhotoKitAssets: { _ in },
                maximumConcurrentPhotos: 1
            ) { candidate in
                if candidate.localIdentifier == "photo-1" {
                    secondStarted.fulfill()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return nil }
                }
                return PhotoEnrichmentUpdate(localIdentifier: candidate.localIdentifier,
                                             ocrText: "saved", sharpnessScore: 1, sceneLabels: nil)
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        task.cancel()
        let updates = await task.value
        XCTAssertEqual(updates?.map(\.localIdentifier), ["photo-0"])
    }

    @MainActor
    func testPhotoEnrichmentBoundsConcurrencyAndPreservesOrder() async {
        let firstPairStarted = expectation(description: "two photos run together")
        firstPairStarted.expectedFulfillmentCount = 2
        var gates: [CheckedContinuation<Void, Never>] = []
        var active = 0
        var peak = 0
        var started = 0
        let candidates = (0..<5).map {
            PhotoEnrichmentCandidate(localIdentifier: "photo-\($0)", pixelWidth: 100,
                                     pixelHeight: 100, sourceId: "folder", filePath: nil)
        }
        let task = Task {
            await PhotoEnrichmentBatchOperation.run(
                candidates: candidates, prefetchPhotoKitAssets: { _ in }, maximumConcurrentPhotos: 2
            ) { candidate in
                active += 1
                started += 1
                peak = max(peak, active)
                if started <= 2 {
                    await withCheckedContinuation { continuation in
                        gates.append(continuation)
                        firstPairStarted.fulfill()
                    }
                }
                active -= 1
                return PhotoEnrichmentUpdate(localIdentifier: candidate.localIdentifier,
                                             ocrText: nil, sharpnessScore: 1, sceneLabels: nil)
            }
        }
        await fulfillment(of: [firstPairStarted], timeout: 1)
        XCTAssertEqual(started, 2)
        for gate in gates.reversed() { gate.resume() }
        let updates = await task.value
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(updates?.map(\.localIdentifier), candidates.map(\.localIdentifier))
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

    func testAutomaticResumeStartsImmediatelyWhileBackgroundWorkRemainsDeferred() {
        XCTAssertEqual(IndexingConfig.postLaunchAutoResumeDelaySeconds, 0)
        XCTAssertGreaterThan(IndexingConfig.postLaunchMaintenanceDelaySeconds, 0)
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

    func testGeocodingRetryUsesBoundedExponentialBackoff() {
        XCTAssertEqual(GeocodingRetryPolicy.delaySeconds(afterAttempt: 0), 30)
        XCTAssertEqual(GeocodingRetryPolicy.delaySeconds(afterAttempt: 1), 60)
        XCTAssertEqual(GeocodingRetryPolicy.delaySeconds(afterAttempt: 2), 120)
        XCTAssertEqual(GeocodingRetryPolicy.delaySeconds(afterAttempt: 20), 900)
        XCTAssertTrue(GeocodingRetryPolicy.allowsAutomaticRetry(afterAttempt: 4))
        XCTAssertFalse(GeocodingRetryPolicy.allowsAutomaticRetry(afterAttempt: 5))
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

    func testInitialIndexingExperienceTracksBaseWorkflowActivity() {
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

}

@MainActor
private final class LifecycleLocationGeocoder: LocationGeocoding {
    private(set) var requestCount = 0
    private(set) var cancelCount = 0
    private var firstRequestContinuation: CheckedContinuation<LocationStrings?, Error>?

    func resolve(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> LocationStrings? {
        requestCount += 1
        if requestCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        return LocationStrings(
            city: "Paris",
            state: "Île-de-France",
            country: "France",
            name: "Paris"
        )
    }

    func cancel() {
        cancelCount += 1
        firstRequestContinuation?.resume(throwing: CancellationError())
        firstRequestContinuation = nil
    }
}

@MainActor
private final class AlwaysTransientLocationGeocoder: LocationGeocoding {
    private(set) var requestCount = 0

    func resolve(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> LocationStrings? {
        requestCount += 1
        throw URLError(.timedOut)
    }

    func cancel() {}
}

@MainActor
private final class RetryResetLocationGeocoder: LocationGeocoding {
    private(set) var permanentRequestCount = 0
    private(set) var eventualRequestCount = 0

    func resolve(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> LocationStrings? {
        if location.coordinate.latitude == 0 {
            permanentRequestCount += 1
            throw URLError(.timedOut)
        }
        eventualRequestCount += 1
        guard eventualRequestCount == 4 else { throw URLError(.timedOut) }
        return LocationStrings(
            city: "Test City",
            state: "Test State",
            country: "Test Country",
            name: nil
        )
    }

    func cancel() {}
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

private func makeGeocodingPolicyVideo(localIdentifier: String) -> IndexedVideo {
    IndexedVideo(
        id: UUID().uuidString,
        localIdentifier: localIdentifier,
        creationDate: Date(timeIntervalSince1970: 100),
        latitude: 48.8566,
        longitude: 2.3522,
        duration: 10,
        pixelWidth: 100,
        pixelHeight: 100,
        frameCount: 1,
        indexedAt: Date(timeIntervalSince1970: 200)
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
