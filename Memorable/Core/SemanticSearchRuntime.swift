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
    @Published private(set) var phase: SemanticSearchPhase = .idle

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
    }

    func markSemanticModelWarming() {
        readiness.markSemanticModelWarming()
        phase = .warmingCore(promoted: false)
    }

    func markSemanticModelReady() {
        readiness.markSemanticModelReady()
        updatePhaseAfterReadinessChange()
    }

    func markIndexWarming(promoted: Bool = false) {
        readiness.markIndexWarming()
        phase = .warmingCore(promoted: promoted)
    }

    func markIndexReady() {
        readiness.markIndexReady()
        updatePhaseAfterReadinessChange()
    }

    func markIndexUnavailable() {
        readiness.markIndexUnavailable()
        updatePhaseAfterReadinessChange()
    }

    func markFailure(_ message: String) {
        readiness.markSemanticFailure(message)
        phase = .failed(message)
    }

    func startPostPaintWarmup() {
        guard warmupTask == nil, !readiness.isSemanticSearchReady else { return }
        _ = startWarmup(priority: .postPaint)
    }

    func startUserInitiatedWarmup() {
        guard warmupTask == nil, !readiness.isSemanticSearchReady else {
            promotionHandler?()
            phase = .warmingCore(promoted: true)
            return
        }
        _ = startWarmup(priority: .userInitiatedSearch)
    }

    func prepareForSearch() async throws {
        if readiness.isSemanticSearchReady { return }
        let task: Task<Void, Error>
        if let existingTask = warmupTask {
            promotionHandler?()
            task = existingTask
        } else {
            task = startWarmup(priority: .userInitiatedSearch)
        }
        phase = .warmingCore(promoted: true)
        try await task.value
    }

    private func startWarmup(priority: SemanticWarmupPriority) -> Task<Void, Error> {
        let promoted = priority == .userInitiatedSearch
        phase = .warmingCore(promoted: promoted)

        let task = Task { [weak self] in
            guard let self else { return }
            guard let warmupLoader else { return }
            try await warmupLoader(priority)
        }
        warmupTask = task

        Task { [weak self] in
            do {
                try await task.value
                await self?.finishWarmup()
            } catch {
                await self?.failWarmup(error)
            }
        }

        return task
    }

    private func finishWarmup() {
        warmupTask = nil
        updatePhaseAfterReadinessChange()
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
