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
    private var warmupLoader: ((SemanticWarmupPriority) async throws -> Void)?
    private var promotionHandler: (() -> Void)?

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
        #if DEBUG
        logger.error("[SemanticSearchRuntime] failure: \(message)")
        #endif
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
        if readiness.isSemanticSearchReady {
            #if DEBUG
            logger.info("[SemanticSearchRuntime] prepareForSearch skipped; already ready")
            #endif
            return
        }
        let task: Task<Void, Error>
        if let existingTask = warmupTask {
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
        #if DEBUG
        logger.info("[SemanticSearchRuntime] prepareForSearch complete; semanticReady=\(self.readiness.isSemanticSearchReady), phase=\(String(describing: self.phase))")
        #endif
    }

    private func startWarmup(priority: SemanticWarmupPriority) -> Task<Void, Error> {
        let promoted = priority == .userInitiatedSearch
        phase = .warmingCore(promoted: promoted)
        #if DEBUG
        logger.info("[SemanticSearchRuntime] startWarmup priority=\(String(describing: priority)) promoted=\(promoted)")
        #endif

        let task = Task { [weak self] in
            guard let self else { return }
            guard let warmupLoader else { return }
            try await warmupLoader(priority)
        }
        warmupTask = task

        Task { [weak self] in
            do {
                try await task.value
                self?.finishWarmup()
            } catch {
                self?.failWarmup(error)
            }
        }

        return task
    }

    private func finishWarmup() {
        warmupTask = nil
        updatePhaseAfterReadinessChange()
        #if DEBUG
        logger.info("[SemanticSearchRuntime] finishWarmup phase=\(String(describing: self.phase)), semanticReady=\(self.readiness.isSemanticSearchReady)")
        #endif
    }

    private func failWarmup(_ error: Error) {
        warmupTask = nil
        markFailure(error.localizedDescription)
    }

    private func updatePhaseAfterReadinessChange() {
        if readiness.isSemanticSearchReady {
            phase = .ready
        } else if readiness.isSemanticModelReady {
            phase = .waitingForIndex
        }
    }
}
