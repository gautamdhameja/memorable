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

struct IndexingBatchCursor<Item> {
    private let items: [Item]
    private let batchSize: Int
    private var nextIndex = 0

    init(items: [Item], batchSize: Int) {
        self.items = items
        self.batchSize = max(1, batchSize)
    }

    var hasRemaining: Bool {
        nextIndex < items.count
    }

    mutating func nextBatch(maxCount: Int? = nil) -> [Item] {
        guard hasRemaining else { return [] }
        let requestedCount = maxCount.map { min(batchSize, max(0, $0)) } ?? batchSize
        guard requestedCount > 0 else { return [] }
        let batchEnd = min(nextIndex + requestedCount, items.count)
        let batch = Array(items[nextIndex..<batchEnd])
        nextIndex = batchEnd
        return batch
    }
}
