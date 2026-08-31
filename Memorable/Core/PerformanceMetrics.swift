import Foundation
import os

struct PerformanceMetric: Equatable, Sendable {
    let name: String
    let durationSeconds: TimeInterval
}

final class PerformanceMetrics: @unchecked Sendable {
    static let shared = PerformanceMetrics()
    static let completedMetricLimit = 100

    private struct State: Sendable {
        var starts: [String: CFAbsoluteTime] = [:]
        var completed: [PerformanceMetric] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var completed: [PerformanceMetric] {
        state.withLock { $0.completed }
    }

    func start(_ name: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        state.withLock { $0.starts[name] = now }
    }

    @discardableResult
    func end(_ name: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> PerformanceMetric? {
        let metric = state.withLock { state -> PerformanceMetric? in
            guard let start = state.starts.removeValue(forKey: name) else { return nil }
            return Self.append(
                PerformanceMetric(name: name, durationSeconds: now - start),
                to: &state
            )
        }
        guard let metric else { return nil }
        logger.info("[Perf] \(name): \(String(format: "%.3f", metric.durationSeconds))s")
        return metric
    }

    @discardableResult
    func record(_ name: String, durationSeconds: TimeInterval) -> PerformanceMetric {
        let metric = state.withLock { state in
            Self.append(
                PerformanceMetric(
                    name: name,
                    durationSeconds: max(0, durationSeconds)
                ),
                to: &state
            )
        }
        logger.info("[Perf] \(name): \(String(format: "%.3f", metric.durationSeconds))s")
        return metric
    }

    func reset() {
        state.withLock {
            $0.starts.removeAll()
            $0.completed.removeAll()
        }
    }

    private static func append(
        _ metric: PerformanceMetric,
        to state: inout State
    ) -> PerformanceMetric {
        state.completed.append(metric)
        if state.completed.count > completedMetricLimit {
            state.completed.removeFirst(state.completed.count - completedMetricLimit)
        }
        return metric
    }
}

enum PerformancePhase {
    static let launchToShell = "launch.to_shell"
    static let semanticWarmup = "semantic.warmup"
    static let firstQuery = "search.first_query"
    static let warmQuery = "search.warm_query"
    static let queryParsing = "search.query_parsing"
    static let textEncoding = "search.text_encoding"
    static let residentScoring = "search.resident_scoring"
    static let tailPageLoading = "search.tail_page_loading"
    static let tailPageScoring = "search.tail_page_scoring"
    static let indexLoad = "index.load"
    static let indexingThroughput = "indexing.throughput"
    static let mainThreadResponsiveness = "ui.main_thread_responsiveness"
    static let postIndexGeocoding = "background.post_index_geocoding"
    static let surpriseValidation = "background.surprise_validation"
}

enum MainThreadResponsivenessPolicy {
    static let sampleIntervalSeconds: TimeInterval = 1
    static let reportThresholdSeconds: TimeInterval = 0.1

    static func stallDuration(
        scheduledAt: CFAbsoluteTime,
        observedAt: CFAbsoluteTime
    ) -> TimeInterval? {
        let delay = observedAt - scheduledAt
        guard delay >= reportThresholdSeconds else { return nil }
        return delay
    }
}

/// Keeps at most one probe queued on the main thread. A frozen UI therefore
/// produces one useful stall duration instead of an unbounded callback backlog.
final class MainThreadResponsivenessMonitor: @unchecked Sendable {
    static let shared = MainThreadResponsivenessMonitor()

    private struct State: Sendable {
        var isRunning = false
        var probePending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.blockdeep.memorable.main-thread-monitor")
    private var timer: DispatchSourceTimer?

    func start() {
        let shouldStart = state.withLock { state in
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
        guard shouldStart else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + MainThreadResponsivenessPolicy.sampleIntervalSeconds,
            repeating: MainThreadResponsivenessPolicy.sampleIntervalSeconds,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in self?.enqueueProbe() }
        self.timer = timer
        timer.resume()
    }

    private func enqueueProbe() {
        let shouldEnqueue = state.withLock { state in
            guard state.isRunning, !state.probePending else { return false }
            state.probePending = true
            return true
        }
        guard shouldEnqueue else { return }

        let scheduledAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.withLock { $0.probePending = false }
            guard let stall = MainThreadResponsivenessPolicy.stallDuration(
                scheduledAt: scheduledAt,
                observedAt: CFAbsoluteTimeGetCurrent()
            ) else { return }
            PerformanceMetrics.shared.record(
                PerformancePhase.mainThreadResponsiveness,
                durationSeconds: stall
            )
        }
    }
}
