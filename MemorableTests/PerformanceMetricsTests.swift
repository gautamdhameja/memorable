import XCTest
@testable import Memorable

@MainActor
final class PerformanceMetricsTests: XCTestCase {

    func testCompletedDurationIsRecorded() {
        let metrics = PerformanceMetrics()

        metrics.start(PerformancePhase.launchToShell, now: 10)
        let metric = metrics.end(PerformancePhase.launchToShell, now: 12.5)

        XCTAssertEqual(metric?.name, PerformancePhase.launchToShell)
        XCTAssertEqual(metric?.durationSeconds ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(metrics.completed.count, 1)
    }

    func testUnknownPhaseEndIsIgnored() {
        let metrics = PerformanceMetrics()

        XCTAssertNil(metrics.end("unknown", now: 12))
        XCTAssertTrue(metrics.completed.isEmpty)
    }

    func testLatestDurationReturnsNewestCompletedValue() {
        let metrics = PerformanceMetrics()

        metrics.record(PerformancePhase.indexLoad, durationSeconds: 0.4)
        metrics.record(PerformancePhase.indexLoad, durationSeconds: 0.2)

        XCTAssertEqual(
            metrics.latestDuration(for: PerformancePhase.indexLoad) ?? 0,
            0.2,
            accuracy: 0.001
        )
        XCTAssertNil(metrics.latestDuration(for: "missing"))
    }

    func testRecorderDistinguishesSearchAndIndexPhases() {
        let metrics = PerformanceMetrics()

        metrics.start(PerformancePhase.firstQuery, now: 1)
        metrics.start(PerformancePhase.warmQuery, now: 3)
        metrics.start(PerformancePhase.indexingThroughput, now: 5)

        metrics.end(PerformancePhase.firstQuery, now: 2)
        metrics.end(PerformancePhase.warmQuery, now: 4)
        metrics.end(PerformancePhase.indexingThroughput, now: 8)

        XCTAssertEqual(metrics.completed.map(\.name), [
            PerformancePhase.firstQuery,
            PerformancePhase.warmQuery,
            PerformancePhase.indexingThroughput,
        ])
    }

    func testCompletedMetricsRemainBounded() {
        let metrics = PerformanceMetrics()

        for index in 0..<(PerformanceMetrics.completedMetricLimit + 10) {
            let name = "metric-\(index)"
            metrics.start(name, now: Double(index))
            metrics.end(name, now: Double(index + 1))
        }

        XCTAssertEqual(metrics.completed.count, PerformanceMetrics.completedMetricLimit)
        XCTAssertEqual(metrics.completed.first?.name, "metric-10")
    }

    func testDirectDurationRecordingIsThreadSafeAndBounded() async {
        let metrics = PerformanceMetrics()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    metrics.record("concurrent-\(index)", durationSeconds: 0.01)
                }
            }
        }

        XCTAssertEqual(metrics.completed.count, PerformanceMetrics.completedMetricLimit)
    }

    func testMainThreadResponsivenessPolicyIgnoresHealthyScheduling() {
        XCTAssertNil(MainThreadResponsivenessPolicy.stallDuration(
            scheduledAt: 10,
            observedAt: 10.05
        ))
        XCTAssertEqual(
            MainThreadResponsivenessPolicy.stallDuration(
                scheduledAt: 10,
                observedAt: 10.25
            ) ?? 0,
            0.25,
            accuracy: 0.001
        )
    }
}
