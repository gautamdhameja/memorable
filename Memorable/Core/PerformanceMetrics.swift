import Foundation
import os

struct PerformanceMetric: Equatable, Sendable {
    let name: String
    let durationSeconds: TimeInterval
}

/// Sendable invariant: every read and mutation of `starts` and `completed` is
/// performed under `state`; `append` is private and called only from locked scopes.
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

    func latestDuration(for name: String) -> TimeInterval? {
        state.withLock { state in
            state.completed.last(where: { $0.name == name })?.durationSeconds
        }
    }

    /// Emits one delayed, parseable summary after semantic warmup. Xcode's
    /// simulator log capture can attach after very fast warm launches, so the
    /// summary intentionally repeats the already-recorded values rather than
    /// relying on every individual timing line being captured.
    func emitStartupSnapshot(semanticSearchReady: Bool) {
        let value: (String) -> TimeInterval = { [self] name in
            latestDuration(for: name) ?? -1
        }
        let responsiveness = MainThreadResponsivenessMonitor.shared.snapshot()
        let line = [
            "app_launch_completed=1",
            "semantic_search_ready=\(semanticSearchReady ? 1 : 0)",
            "main_thread_probe_available=\(responsiveness.isAvailable ? 1 : 0)",
            "main_thread_probe_pending=\(responsiveness.isPending ? 1 : 0)",
            "startup_to_semantic_seconds=\(Self.format(value(PerformancePhase.startupToSemanticSearch)))",
            "semantic_warmup_seconds=\(Self.format(value(PerformancePhase.semanticWarmup)))",
            "launch_to_shell_seconds=\(Self.format(value(PerformancePhase.launchToShell)))",
            "photo_authorization_seconds=\(Self.format(value(PerformancePhase.photoAuthorization)))",
            "image_model_load_seconds=\(Self.format(value(PerformancePhase.imageModelLoad)))",
            "text_model_load_seconds=\(Self.format(value(PerformancePhase.textModelLoad)))",
            "tokenizer_load_seconds=\(Self.format(value(PerformancePhase.tokenizerLoad)))",
            "tokenizer_file_read_seconds=\(Self.format(value(PerformancePhase.tokenizerFileRead)))",
            "tokenizer_native_load_seconds=\(Self.format(value(PerformancePhase.tokenizerNativeLoad)))",
            "database_open_seconds=\(Self.format(value(PerformancePhase.databaseOpen)))",
            "entitlement_verification_seconds=\(Self.format(value(PerformancePhase.entitlementVerification)))",
            "index_load_seconds=\(Self.format(value(PerformancePhase.indexLoad)))",
            "main_thread_stall_seconds=\(Self.format(responsiveness.maximumStallSeconds))",
        ].joined(separator: " ")
        logger.info("[StartupSnapshot] \(line, privacy: .public)")
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

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.6f", value)
    }
}

enum PerformancePhase {
    static let launchToShell = "launch.to_shell"
    static let startupToSemanticSearch = "startup.to_semantic_search"
    static let semanticWarmup = "semantic.warmup"
    static let photoAuthorization = "startup.photo_authorization"
    static let imageModelLoad = "startup.image_model_load"
    static let textModelLoad = "startup.text_model_load"
    static let tokenizerLoad = "startup.tokenizer_load"
    static let tokenizerFileRead = "startup.tokenizer_file_read"
    static let tokenizerNativeLoad = "startup.tokenizer_native_load"
    static let databaseOpen = "startup.database_open"
    static let entitlementVerification = "startup.entitlement_verification"
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

    static func snapshot(
        completedStallSeconds: TimeInterval?,
        completedProbeCount: Int,
        pendingScheduledAt: CFAbsoluteTime?,
        now: CFAbsoluteTime
    ) -> MainThreadResponsivenessSnapshot {
        let pendingDelay = pendingScheduledAt.map { max(0, now - $0) } ?? 0
        return MainThreadResponsivenessSnapshot(
            isAvailable: completedProbeCount > 0 || pendingScheduledAt != nil,
            isPending: pendingScheduledAt != nil,
            maximumStallSeconds: max(completedStallSeconds ?? 0, pendingDelay)
        )
    }
}

struct MainThreadResponsivenessSnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let isPending: Bool
    let maximumStallSeconds: TimeInterval
}

/// Keeps at most one probe queued on the main thread. A frozen UI therefore
/// produces one useful stall duration instead of an unbounded callback backlog.
/// Sendable invariant: all probe state is accessed under `state`; the timer is
/// initialized once by the sole successful `start()` and runs on `queue`.
final class MainThreadResponsivenessMonitor: @unchecked Sendable {
    static let shared = MainThreadResponsivenessMonitor()

    private struct State: Sendable {
        var isRunning = false
        var pendingScheduledAt: CFAbsoluteTime?
        var completedProbeCount = 0
        var maximumCompletedStallSeconds: TimeInterval = 0
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
        let scheduledAt = CFAbsoluteTimeGetCurrent()
        let shouldEnqueue = state.withLock { state in
            guard state.isRunning, state.pendingScheduledAt == nil else { return false }
            state.pendingScheduledAt = scheduledAt
            return true
        }
        guard shouldEnqueue else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let observedAt = CFAbsoluteTimeGetCurrent()
            let stall = MainThreadResponsivenessPolicy.stallDuration(
                scheduledAt: scheduledAt,
                observedAt: observedAt
            )
            if let stall {
                PerformanceMetrics.shared.record(
                    PerformancePhase.mainThreadResponsiveness,
                    durationSeconds: stall
                )
            }
            self.state.withLock {
                $0.pendingScheduledAt = nil
                $0.completedProbeCount += 1
                $0.maximumCompletedStallSeconds = max(
                    $0.maximumCompletedStallSeconds,
                    stall ?? 0
                )
            }
        }
    }

    func snapshot(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> MainThreadResponsivenessSnapshot {
        let probeState = state.withLock {
            (
                completedProbeCount: $0.completedProbeCount,
                pendingScheduledAt: $0.pendingScheduledAt,
                maximumCompletedStallSeconds: $0.maximumCompletedStallSeconds
            )
        }
        return MainThreadResponsivenessPolicy.snapshot(
            completedStallSeconds: probeState.completedProbeCount > 0
                ? probeState.maximumCompletedStallSeconds
                : nil,
            completedProbeCount: probeState.completedProbeCount,
            pendingScheduledAt: probeState.pendingScheduledAt,
            now: now
        )
    }
}
