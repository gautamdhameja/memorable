import Foundation
import os

enum SearchSuggestionVisibilityPolicy {
    static func shouldShow(
        indexingProgress: IndexingProgress,
        isReady: Bool,
        hasValidatedSuggestions: Bool
    ) -> Bool {
        !indexingProgress.isRunning && isReady && hasValidatedSuggestions
    }
}

enum IndexingHomePresentationPolicy {
    static func showsSlideshow(
        isInitialLibraryWorkflowActive: Bool,
        isRunning: Bool,
        isPaused: Bool,
        hasQuery: Bool,
        phase: IndexingPhase = .photos
    ) -> Bool {
        phase != .enrichment
            && (isInitialLibraryWorkflowActive || ((isRunning || isPaused) && !hasQuery))
    }
}

enum InitialIndexingExperienceStore {
    static func isPending(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppKeys.initialIndexingExperiencePending)
    }

    static func begin(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: AppKeys.initialIndexingExperiencePending)
    }

    static func isCompleted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppKeys.initialIndexingExperienceCompleted)
    }

    static func complete(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: AppKeys.initialIndexingExperiencePending)
        defaults.set(true, forKey: AppKeys.initialIndexingExperienceCompleted)
    }
}

enum InitialIndexingExperiencePolicy {
    static func shouldBegin(
        hasKnownExistingIndex: Bool,
        hasCompletedInitialExperience: Bool,
        isReady: Bool,
        searchableCount: Int
    ) -> Bool {
        !hasCompletedInitialExperience
            && !hasKnownExistingIndex
            && !isReady
            && searchableCount == 0
    }

    static func shouldShow(
        isInitialLibraryWorkflowActive: Bool
    ) -> Bool {
        isInitialLibraryWorkflowActive
    }

    static func shouldResumePendingRun(
        scheduleAutoResume: Bool,
        didLoadIndex: Bool,
        isPending: Bool
    ) -> Bool {
        scheduleAutoResume && !didLoadIndex && isPending
    }
}

enum InitialIndexingForegroundResumePolicy {
    static func shouldSchedule(
        isApplicationActive: Bool,
        hasCompletedInitialIndexCheck: Bool,
        allowsAutoResume: Bool,
        isPending: Bool,
        progressIsRunning: Bool,
        hasLibraryWork: Bool
    ) -> Bool {
        isApplicationActive
            && hasCompletedInitialIndexCheck
            && allowsAutoResume
            && isPending
            && !progressIsRunning
            && !hasLibraryWork
    }
}

enum ForegroundSemanticWarmupPolicy {
    static func shouldStart(
        isApplicationActive: Bool,
        isShellReady: Bool,
        isSemanticSearchReady: Bool
    ) -> Bool {
        isApplicationActive && isShellReady && !isSemanticSearchReady
    }
}

enum IndexingBackgroundTimePolicy {
    /// Leave enough time for the current database write and cancellation path
    /// to finish before UIKit's finite background assertion expires.
    static let minimumRemainingSeconds: TimeInterval = 10

    static func canStartNextBatch(
        isApplicationActive: Bool,
        hasScheduledTaskAssertion: Bool,
        backgroundTimeRemaining: TimeInterval
    ) -> Bool {
        isApplicationActive
            || hasScheduledTaskAssertion
            || backgroundTimeRemaining == .greatestFiniteMagnitude
            || backgroundTimeRemaining >= minimumRemainingSeconds
    }
}

enum PostIndexingContinuationPolicy {
    static func shouldDeferUntilForeground(isApplicationActive: Bool) -> Bool {
        !isApplicationActive
    }

    static func dependencies(
        isDeferredUntilAfterBaseCompletion: Bool
    ) -> Set<IndexingJobKind> {
        isDeferredUntilAfterBaseCompletion ? [] : [.indexVideos]
    }
}

enum AutomaticMaintenanceEligibilityPolicy {
    static func canSchedule(
        isApplicationActive: Bool,
        allowsIndexingWrites: Bool,
        isMemoryPressureSuspended: Bool,
        isThermallySafe: Bool,
        isTaskCancelled: Bool
    ) -> Bool {
        isApplicationActive
            && allowsIndexingWrites
            && !isMemoryPressureSuspended
            && isThermallySafe
            && !isTaskCancelled
    }
}

enum ScheduledInitialIndexingExpirationPolicy {
    static func shouldInterrupt(
        isApplicationActive: Bool,
        isInitialIndexingPending: Bool
    ) -> Bool {
        !isApplicationActive && isInitialIndexingPending
    }
}

enum InitialIndexingInterruptionStore {
    private static let interruptedKey = "indexing.initialCheckpoint.interrupted"

    static func markInterrupted(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: interruptedKey)
    }

    static func wasInterrupted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: interruptedKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: interruptedKey)
    }
}

enum ContinuedIndexingProgress {
    static let totalUnits: Int64 = 1_000

    static func completedUnits(for progress: IndexingProgress) -> Int64 {
        let fraction = progress.total > 0
            ? min(1, max(0, Double(progress.completed) / Double(progress.total)))
            : 0
        let completed: Double
        switch progress.phase {
        case .photos:
            completed = fraction * 750
        case .videos:
            completed = 750 + (fraction * 250)
        case .enrichment:
            completed = 1_000
        case .idle:
            completed = 0
        }
        return Int64(completed.rounded(.down))
    }
}

struct IndexingProgressPublisher {
    static let minimumInterval: TimeInterval = 0.25

    private var lastPublishedAt: TimeInterval?
    private var lastPhase: IndexingPhase?

    mutating func publish(
        _ progress: IndexingProgress,
        force: Bool = false,
        now: TimeInterval = CFAbsoluteTimeGetCurrent(),
        using action: (IndexingProgress) -> Void
    ) {
        let elapsed = lastPublishedAt.map { now - $0 } ?? .infinity
        guard force
                || lastPublishedAt == nil
                || lastPhase != progress.phase
                || !progress.isRunning
                || progress.completed >= progress.total
                || elapsed >= Self.minimumInterval else {
            return
        }
        lastPublishedAt = now
        lastPhase = progress.phase
        action(progress)
    }
}

enum ThermalIndexingEffect: Equatable {
    case none
    case cancelWork
    case restartWork
}

struct ThermalIndexingState: Equatable {
    var isPaused = false
    var resumeWhenCool = false
}

enum ThermalWorkActivityPolicy {
    static func hasActiveWork(
        isJobQueueIdle: Bool,
        isProgressRunning: Bool,
        hasDeferredPostIndexingWorkflow: Bool
    ) -> Bool {
        !isJobQueueIdle
            || isProgressRunning
            || hasDeferredPostIndexingWorkflow
    }
}

enum ThermalSafetyPolicy {
    static func shouldPause(for state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    static func transition(
        from current: ThermalIndexingState,
        thermalState: ProcessInfo.ThermalState,
        hasActiveWork: Bool
    ) -> (state: ThermalIndexingState, effect: ThermalIndexingEffect) {
        if shouldPause(for: thermalState) {
            guard current.isPaused || current.resumeWhenCool || hasActiveWork else {
                return (current, .none)
            }
            return (
                ThermalIndexingState(
                    isPaused: true,
                    resumeWhenCool: current.resumeWhenCool || hasActiveWork
                ),
                hasActiveWork ? .cancelWork : .none
            )
        }
        guard current.isPaused else { return (current, .none) }
        return (
            ThermalIndexingState(),
            current.resumeWhenCool ? .restartWork : .none
        )
    }
}

/// Sendable invariant: the non-Sendable observer token is read and cleared
/// atomically under `token`, so concurrent cancellation removes it at most once.
final class NotificationObservation: @unchecked Sendable {
    private let token: OSAllocatedUnfairLock<NSObjectProtocol?>

    init(token: NSObjectProtocol) {
        self.token = OSAllocatedUnfairLock(uncheckedState: token)
    }

    func cancel() {
        let token = token.withLockUnchecked { stored in
            defer { stored = nil }
            return stored
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}

enum ProRevocationOperation {
    static func run<Result: Sendable>(
        trim: @escaping @Sendable () throws -> Result,
        reload: @MainActor @escaping (Result) async -> Void
    ) async throws {
        let result = try await CancellableDetachedOperation.run(
            priority: .userInitiated,
            trim
        )
        await reload(result)
    }
}

enum DuplicateScanGenerationPolicy {
    static func acceptsCompletion(
        startedGeneration: UInt,
        currentGeneration: UInt,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && startedGeneration == currentGeneration
    }
}

@MainActor
enum IndexingStorageMutation {
    static func run(
        waitForIdle: () async -> Void,
        mutation: @escaping @Sendable () throws -> Void,
        completion: () async throws -> Void
    ) async throws {
        await waitForIdle()
        try Task.checkCancellation()
        try await CancellableDetachedOperation.run(priority: .userInitiated, mutation)
        try Task.checkCancellation()
        try await completion()
    }
}

enum PhotoEnrichmentTask {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let task = Task.detached(priority: .utility) { () -> Value? in
            guard !Task.isCancelled else { return nil }
            let value = await operation()
            guard !Task.isCancelled else { return nil }
            return value
        }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : value
    }
}

@MainActor
enum PhotoEnrichmentBatchOperation {
    static func run(
        candidates: [PhotoEnrichmentCandidate],
        prefetchPhotoKitAssets: ([String]) async -> Void,
        maximumConcurrentPhotos: Int = IndexingConfig.enrichmentConcurrency,
        enrich: @escaping @MainActor @Sendable (PhotoEnrichmentCandidate) async -> PhotoEnrichmentUpdate?
    ) async -> [PhotoEnrichmentUpdate]? {
        guard !Task.isCancelled else { return nil }
        let photoKitIdentifiers = candidates.compactMap { candidate in
            candidate.sourceId == PhotoSourceType.photokit.rawValue
                ? candidate.localIdentifier
                : nil
        }
        if !photoKitIdentifiers.isEmpty {
            await prefetchPhotoKitAssets(photoKitIdentifiers)
        }
        guard !Task.isCancelled else { return nil }

        // Keep completed results when cancellation interrupts the rest of a
        // batch, so frequent searches do not repeatedly discard analysis.
        return await withTaskGroup(of: (Int, PhotoEnrichmentUpdate?).self) { group in
            var next = 0
            var updates = [PhotoEnrichmentUpdate?](repeating: nil, count: candidates.count)
            let limit = min(candidates.count, max(1, maximumConcurrentPhotos))
            for index in 0..<limit {
                let candidate = candidates[index]
                group.addTask { (index, await enrich(candidate)) }
                next += 1
            }
            while let (index, update) = await group.next() {
                if let update { updates[index] = update }
                if Task.isCancelled || update == nil {
                    group.cancelAll()
                }
                if !group.isCancelled, next < candidates.count {
                    let index = next
                    let candidate = candidates[index]
                    group.addTask { (index, await enrich(candidate)) }
                    next += 1
                }
            }
            return updates.compactMap { $0 }
        }
    }
}

@MainActor
enum ProFolderIndexingOperation {
    static func run(
        isEntitled: () -> Bool,
        operation: () async -> FolderIndexingOutcome
    ) async -> IndexingJobOutcome {
        guard isEntitled() else { return .cancelled }
        switch await operation() {
        case .completed, .completedWithWarnings:
            return Task.isCancelled ? .cancelled : .completed
        case .failed, .cancelled:
            return .cancelled
        }
    }
}

enum SavedFolderReindexPolicy {
    static func sourcesToReindex(
        from sources: [PhotoSource],
        isPro: Bool
    ) -> [PhotoSource] {
        guard isPro else { return [] }
        return sources.filter {
            $0.type == PhotoSourceType.folder.rawValue && $0.lastIndexedAt == nil
        }
    }
}

enum OrphanCleanupSafetyPolicy {
    static func orphanRatio(
        candidateRemovalCount: Int,
        photoLibraryIndexedCount: Int
    ) -> Double {
        Double(candidateRemovalCount) / Double(max(photoLibraryIndexedCount, 1))
    }

    static func exceedsSafetyThreshold(
        candidateRemovalCount: Int,
        photoLibraryIndexedCount: Int
    ) -> Bool {
        orphanRatio(
            candidateRemovalCount: candidateRemovalCount,
            photoLibraryIndexedCount: photoLibraryIndexedCount
        ) > IndexingConfig.maxOrphanRatio
    }
}

enum ProUnlockIndexingRecoveryPolicy {
    static func shouldStartLibraryIndexing(
        isMemoryPressureSuspended: Bool,
        hasLibraryIndexingWork: Bool
    ) -> Bool {
        !isMemoryPressureSuspended && !hasLibraryIndexingWork
    }
}
