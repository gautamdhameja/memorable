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
        let line = [
            "app_launch_completed=1",
            "semantic_search_ready=\(semanticSearchReady ? 1 : 0)",
            "semantic_warmup_seconds=\(Self.format(value(PerformancePhase.semanticWarmup)))",
            "launch_to_shell_seconds=\(Self.format(value(PerformancePhase.launchToShell)))",
            "photo_authorization_seconds=\(Self.format(value(PerformancePhase.photoAuthorization)))",
            "image_model_load_seconds=\(Self.format(value(PerformancePhase.imageModelLoad)))",
            "text_model_load_seconds=\(Self.format(value(PerformancePhase.textModelLoad)))",
            "tokenizer_load_seconds=\(Self.format(value(PerformancePhase.tokenizerLoad)))",
            "tokenizer_file_read_seconds=\(Self.format(value(PerformancePhase.tokenizerFileRead)))",
            "tokenizer_proto_decode_seconds=\(Self.format(value(PerformancePhase.tokenizerProtoDecode)))",
            "tokenizer_table_build_seconds=\(Self.format(value(PerformancePhase.tokenizerTableBuild)))",
            "database_open_seconds=\(Self.format(value(PerformancePhase.databaseOpen)))",
            "entitlement_verification_seconds=\(Self.format(value(PerformancePhase.entitlementVerification)))",
            "index_load_seconds=\(Self.format(value(PerformancePhase.indexLoad)))",
            "main_thread_stall_seconds=\(Self.format(max(0, value(PerformancePhase.mainThreadResponsiveness))))",
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
    static let semanticWarmup = "semantic.warmup"
    static let photoAuthorization = "startup.photo_authorization"
    static let imageModelLoad = "startup.image_model_load"
    static let textModelLoad = "startup.text_model_load"
    static let tokenizerLoad = "startup.tokenizer_load"
    static let tokenizerFileRead = "startup.tokenizer_file_read"
    static let tokenizerProtoDecode = "startup.tokenizer_proto_decode"
    static let tokenizerTableBuild = "startup.tokenizer_table_build"
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
