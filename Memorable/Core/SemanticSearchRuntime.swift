import Foundation
import Combine

enum SemanticWarmupPriority: Equatable {
    case postPaint
    case userInitiatedSearch
}

enum SemanticSearchPhase: Equatable {
    case idle
    case warmingCore(promoted: Bool)
    case waitingForIndex
    case ready
    case failed(String)
}

@MainActor
final class SemanticSearchRuntime: ObservableObject {
    @Published private(set) var readiness = AppReadiness()
    @Published private(set) var phase: SemanticSearchPhase = .idle {
        didSet {
            #if DEBUG
            if oldValue != phase {
                logger.info("[SemanticSearchRuntime] phase changed \(String(describing: oldValue)) -> \(String(describing: self.phase)); semanticReady=\(self.readiness.isSemanticSearchReady)")
            }
            #endif
        }
    }

    private var warmupTask: Task<Void, Error>?
    private var warmupGeneration: UInt64 = 0
    private var pendingWarmupPriority: SemanticWarmupPriority?
    private var warmupLoader: ((SemanticWarmupPriority) async throws -> Void)?
    private var promotionHandler: (() -> Void)?

    var isCheckingIndexAvailability: Bool {
        readiness.index == .warming
    }

    func setWarmupLoader(_ loader: @escaping (SemanticWarmupPriority) async throws -> Void) {
        warmupLoader = loader
    }

    func setPromotionHandler(_ handler: @escaping () -> Void) {
        promotionHandler = handler
    }

    func markShellReady() {
        readiness.markShellReady()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] shell ready")
        #endif
    }

    func markSemanticModelWarming() {
        readiness.markSemanticModelWarming()
        phase = .warmingCore(promoted: false)
        #if DEBUG
        logger.info("[SemanticSearchRuntime] semantic model warming")
        #endif
    }

    func markSemanticModelReady() {
        readiness.markSemanticModelReady()
        updatePhaseAfterReadinessChange()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] semantic model ready; phase=\(String(describing: self.phase))")
        #endif
    }

    func cancelWarmupForMemoryPressure() {
        warmupTask?.cancel()
        pendingWarmupPriority = nil
        readiness.markSemanticModelUnavailable()
        phase = .failed("Search paused to reduce memory use. Tap Try Again when you are ready.")
    }

    func markIndexWarming(promoted: Bool = false) {
        readiness.markIndexWarming()
        phase = .warmingCore(promoted: promoted)
        #if DEBUG
        logger.info("[SemanticSearchRuntime] index warming promoted=\(promoted)")
        #endif
    }

    func markIndexReady() {
        readiness.markIndexReady()
        updatePhaseAfterReadinessChange()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] index ready; semanticReady=\(self.readiness.isSemanticSearchReady)")
        #endif
    }

    func markIndexUnavailable() {
        readiness.markIndexUnavailable()
        updatePhaseAfterReadinessChange()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] index unavailable; phase=\(String(describing: self.phase))")
        #endif
    }

    func markFailure(_ message: String) {
        readiness.markSemanticFailure(message)
        phase = .failed(message)
        logger.error("[SemanticSearchRuntime] semantic warmup failed")
    }

    func startPostPaintWarmup() {
        guard warmupTask == nil, !readiness.isSemanticSearchReady else {
            #if DEBUG
            logger.info("[SemanticSearchRuntime] post-paint warmup skipped; hasTask=\(self.warmupTask != nil), semanticReady=\(self.readiness.isSemanticSearchReady)")
            #endif
            return
        }
        #if DEBUG
        logger.info("[SemanticSearchRuntime] post-paint warmup starting")
        #endif
        _ = startWarmup(priority: .postPaint)
    }

    func startUserInitiatedWarmup() {
        if let warmupTask, warmupTask.isCancelled {
            pendingWarmupPriority = .userInitiatedSearch
            phase = .warmingCore(promoted: true)
            return
        }
        guard warmupTask == nil, !readiness.isSemanticSearchReady else {
            #if DEBUG
            logger.info("[SemanticSearchRuntime] user warmup promoted existing/ready path; hasTask=\(self.warmupTask != nil), semanticReady=\(self.readiness.isSemanticSearchReady)")
            #endif
            promotionHandler?()
            phase = .warmingCore(promoted: true)
            return
        }
        #if DEBUG
        logger.info("[SemanticSearchRuntime] user warmup starting")
        #endif
        _ = startWarmup(priority: .userInitiatedSearch)
    }

    func prepareForSearch() async throws {
        try Task.checkCancellation()
        if readiness.isSemanticSearchReady {
            #if DEBUG
            logger.info("[SemanticSearchRuntime] prepareForSearch skipped; already ready")
            #endif
            return
        }
        let task: Task<Void, Error>
        if let existingTask = warmupTask {
            if existingTask.isCancelled {
                try Task.checkCancellation()
                let cancelledGeneration = warmupGeneration
                pendingWarmupPriority = .userInitiatedSearch
                phase = .warmingCore(promoted: true)
                _ = try? await existingTask.value
                try Task.checkCancellation()
                // Task completion includes its drain handling. A second
                // memory warning may withdraw the pending replacement.
                guard warmupGeneration != cancelledGeneration else {
                    throw CancellationError()
                }
                if readiness.isSemanticSearchReady { return }
                guard let replacementTask = warmupTask else {
                    throw CancellationError()
                }
                try await replacementTask.value
                return
            }
            #if DEBUG
            logger.info("[SemanticSearchRuntime] prepareForSearch promoting existing warmup")
            #endif
            promotionHandler?()
            task = existingTask
        } else {
            #if DEBUG
            logger.info("[SemanticSearchRuntime] prepareForSearch starting user-initiated warmup")
            #endif
            task = startWarmup(priority: .userInitiatedSearch)
        }
        phase = .warmingCore(promoted: true)
        try await task.value
        try Task.checkCancellation()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] prepareForSearch complete; semanticReady=\(self.readiness.isSemanticSearchReady), phase=\(String(describing: self.phase))")
        #endif
    }

    private func startWarmup(priority: SemanticWarmupPriority) -> Task<Void, Error> {
        warmupGeneration &+= 1
        let generation = warmupGeneration
        let promoted = priority == .userInitiatedSearch
        phase = .warmingCore(promoted: promoted)
        #if DEBUG
        logger.info("[SemanticSearchRuntime] startWarmup priority=\(String(describing: priority)) promoted=\(promoted)")
        #endif

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                if let warmupLoader {
                    try await warmupLoader(priority)
                }
                try Task.checkCancellation()
                finishWarmup(generation: generation)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    finishCancelledWarmup(generation: generation)
                } else {
                    failWarmup(error, generation: generation)
                }
                throw error
            }
        }
        warmupTask = task

        return task
    }

    private func finishWarmup(generation: UInt64) {
        guard generation == warmupGeneration else { return }
        warmupTask = nil
        updatePhaseAfterReadinessChange()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] finishWarmup phase=\(String(describing: self.phase)), semanticReady=\(self.readiness.isSemanticSearchReady)")
        #endif
    }

    private func failWarmup(_ error: Error, generation: UInt64) {
        guard generation == warmupGeneration else { return }
        warmupTask = nil
        markFailure(UserFacingErrorMessage.message(
            for: error,
            fallback: "Search couldn't be prepared. Close and reopen Memorable, then try again."
        ))
    }

    private func finishCancelledWarmup(generation: UInt64) {
        guard generation == warmupGeneration else { return }
        warmupTask = nil
        if let pendingWarmupPriority {
            self.pendingWarmupPriority = nil
            _ = startWarmup(priority: pendingWarmupPriority)
            return
        }
        readiness.markSemanticModelUnavailable()
        phase = .failed("Search paused to reduce memory use. Tap Try Again when you are ready.")
    }

    private func updatePhaseAfterReadinessChange() {
        if readiness.isSemanticSearchReady {
            phase = .ready
        } else if readiness.isSemanticModelReady {
            phase = .waitingForIndex
        }
    }
}
