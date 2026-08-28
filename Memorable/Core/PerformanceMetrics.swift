import Foundation

struct PerformanceMetric: Equatable {
    let name: String
    let durationSeconds: TimeInterval
}

@MainActor
final class PerformanceMetrics {
    static let shared = PerformanceMetrics()

    private var starts: [String: CFAbsoluteTime] = [:]
    private(set) var completed: [PerformanceMetric] = []

    func start(_ name: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        starts[name] = now
    }

    @discardableResult
    func end(_ name: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> PerformanceMetric? {
        guard let start = starts.removeValue(forKey: name) else { return nil }
        let metric = PerformanceMetric(name: name, durationSeconds: now - start)
        completed.append(metric)
        #if DEBUG
        logger.info("[Perf] \(name): \(String(format: "%.3f", metric.durationSeconds))s")
        #endif
        return metric
    }

    func reset() {
        starts.removeAll()
        completed.removeAll()
    }
}

enum PerformancePhase {
    static let launchToShell = "launch.to_shell"
    static let semanticWarmup = "semantic.warmup"
    static let firstQuery = "search.first_query"
    static let warmQuery = "search.warm_query"
    static let indexLoad = "index.load"
    static let indexingThroughput = "indexing.throughput"
    static let mainThreadResponsiveness = "ui.main_thread_responsiveness"
}
