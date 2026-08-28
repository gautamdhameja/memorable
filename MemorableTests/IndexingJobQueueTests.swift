import XCTest
@testable import Memorable

@MainActor
final class IndexingJobQueueTests: XCTestCase {
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class ManualClock {
        var date = Date(timeIntervalSince1970: 1_000)
        var requestedSleeps: [UInt64] = []

        func sleep(nanoseconds: UInt64) async throws {
            requestedSleeps.append(nanoseconds)
            date = date.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
            await Task.yield()
        }
    }

    private final class ControlledClock {
        private struct Waiter {
            let deadline: Date
            let continuation: CheckedContinuation<Void, Never>
        }

        var date = Date(timeIntervalSince1970: 2_000)
        private var waiters: [Waiter] = []
        var pendingWaiterCount: Int { waiters.count }

        func sleep(nanoseconds: UInt64) async throws {
            let deadline = date.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(deadline: deadline, continuation: continuation))
            }
        }

        func advance(by seconds: TimeInterval) {
            date = date.addingTimeInterval(seconds)
            let ready = waiters.filter { $0.deadline <= date }
            waiters.removeAll { $0.deadline <= date }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func testEveryTypedJobCanExecuteWithoutPhotoKit() async {
        let queue = IndexingJobQueue()
        let workflowID = UUID()
        var executed: [IndexingJobKind] = []

        for kind in IndexingJobKind.allCases {
            queue.enqueue(IndexingJob(
                workflowID: workflowID,
                kind: kind,
                priority: .maintenance
            ) {
                executed.append(kind)
                return .completed
            })
        }

        await queue.waitUntilIdle()
        XCTAssertEqual(Set(executed), Set(IndexingJobKind.allCases))
    }

    func testDependencyBlocksUntilRequiredJobCompletes() async {
        let queue = IndexingJobQueue()
        let workflowID = UUID()
        let gate = Gate()
        var executed: [IndexingJobKind] = []

        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            await gate.wait()
            executed.append(.indexPhotos)
            return .completed
        })
        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexVideos,
            priority: .userInitiated,
            dependencies: [.indexPhotos]
        ) {
            executed.append(.indexVideos)
            return .completed
        })

        await Task.yield()
        XCTAssertTrue(executed.isEmpty)
        gate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(executed, [.indexPhotos, .indexVideos])
    }

    func testPrioritySelectsHighestEligibleJob() async {
        let queue = IndexingJobQueue()
        let workflowID = UUID()
        let gate = Gate()
        var executed: [IndexingJobKind] = []

        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            await gate.wait()
            return .completed
        })
        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .geocodeMedia,
            priority: .background,
            dependencies: [.indexPhotos]
        ) {
            executed.append(.geocodeMedia)
            return .completed
        })
        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .validateSurpriseQueries,
            priority: .maintenance,
            dependencies: [.indexPhotos]
        ) {
            executed.append(.validateSurpriseQueries)
            return .completed
        })

        gate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(executed, [.validateSurpriseQueries, .geocodeMedia])
    }

    func testDelayStartsAfterDependencyCompletion() async {
        let clock = ManualClock()
        let queue = IndexingJobQueue(
            now: { clock.date },
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )
        let workflowID = UUID()
        var executed: [IndexingJobKind] = []

        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            clock.date = clock.date.addingTimeInterval(8)
            executed.append(.indexPhotos)
            return .completed
        })
        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .enrichPhotos,
            priority: .enrichment,
            dependencies: [.indexPhotos],
            delayAfterDependencies: 5
        ) {
            executed.append(.enrichPhotos)
            return .completed
        })

        await queue.waitUntilIdle()
        XCTAssertEqual(executed, [.indexPhotos, .enrichPhotos])
        XCTAssertEqual(clock.requestedSleeps, [5_000_000_000])
        XCTAssertEqual(clock.date.timeIntervalSince1970, 1_013, accuracy: 0.001)
    }

    func testCancelledStaleCompletionCannotCompleteReplacement() async {
        let queue = IndexingJobQueue()
        let staleGate = Gate()
        let firstWorkflow = UUID()
        var completions = 0

        queue.enqueue(IndexingJob(
            workflowID: firstWorkflow,
            kind: .enrichPhotos,
            priority: .enrichment
        ) {
            await staleGate.wait()
            return .completed
        })
        await Task.yield()
        queue.cancel(.enrichPhotos)
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .enrichPhotos,
            priority: .enrichment
        ) {
            completions += 1
            return .completed
        })

        staleGate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(queue.retainedCancellationCount, 0)
    }

    func testFailedDependencyCancelsDependentsAndPrunesWorkflowState() async {
        let queue = IndexingJobQueue()
        let workflowID = UUID()
        var dependentRan = false

        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexPhotos,
            priority: .userInitiated
        ) { .cancelled })
        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexVideos,
            priority: .userInitiated,
            dependencies: [.indexPhotos]
        ) {
            dependentRan = true
            return .completed
        })

        await queue.waitUntilIdle()
        XCTAssertFalse(dependentRan)
        XCTAssertEqual(queue.retainedWorkflowCount, 0)
    }

    func testCancellingPendingJobDoesNotRetainCancellationIdentity() async {
        let queue = IndexingJobQueue()
        let workflowID = UUID()
        let gate = Gate()

        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            await gate.wait()
            return .completed
        })
        queue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .enrichPhotos,
            priority: .enrichment,
            dependencies: [.indexPhotos]
        ) { .completed })

        queue.cancel(.enrichPhotos)
        XCTAssertEqual(queue.retainedCancellationCount, 0)
        gate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(queue.retainedWorkflowCount, 0)
    }

    func testUserInitiatedJobPreemptsBackgroundGeocoding() async {
        let queue = IndexingJobQueue()
        var events: [String] = []

        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .geocodeMedia,
            priority: .background
        ) {
            events.append("geocode-start")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                events.append("geocode-cancelled")
                return .cancelled
            }
            return .completed
        })
        await Task.yield()
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            events.append("index")
            return .completed
        })

        await queue.waitUntilIdle()
        XCTAssertEqual(events, ["geocode-start", "geocode-cancelled", "index"])
    }

    func testBackgroundJobDoesNotPreemptUserIndexing() async {
        let queue = IndexingJobQueue()
        let gate = Gate()
        var events: [String] = []

        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            events.append("index-start")
            await gate.wait()
            events.append("index-finish")
            return .completed
        })
        await Task.yield()
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .geocodeMedia,
            priority: .background
        ) {
            events.append("geocode")
            return .completed
        })
        await Task.yield()
        XCTAssertEqual(events, ["index-start"])

        gate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(events, ["index-start", "index-finish", "geocode"])
    }

    func testUserJobDoesNotPreemptBoundedMaintenance() async {
        let queue = IndexingJobQueue()
        let gate = Gate()
        var events: [String] = []

        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .cleanOrphans,
            priority: .maintenance
        ) {
            events.append("cleanup-start")
            await gate.wait()
            events.append("cleanup-finish")
            return .completed
        })
        await Task.yield()
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            events.append("index")
            return .completed
        })
        await Task.yield()
        XCTAssertEqual(events, ["cleanup-start"])

        gate.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(events, ["cleanup-start", "cleanup-finish", "index"])
    }

    func testDelayedAutoResumePreemptsEnrichmentWhenItBecomesEligible() async {
        let clock = ControlledClock()
        let queue = IndexingJobQueue(
            now: { clock.date },
            sleep: { try await clock.sleep(nanoseconds: $0) }
        )
        var events: [String] = []

        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexPhotos,
            priority: .userInitiated,
            delayAfterDependencies: 8
        ) {
            events.append("auto-resume")
            return .completed
        })
        await settleScheduledTasks(until: { clock.pendingWaiterCount == 1 })

        clock.advance(by: 2)
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .enrichPhotos,
            priority: .enrichment,
            delayAfterDependencies: 5
        ) {
            events.append("enrichment-start")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                events.append("enrichment-cancelled")
                return .cancelled
            }
            return .completed
        })
        await settleScheduledTasks(until: { clock.pendingWaiterCount == 2 })

        clock.advance(by: 5)
        await settleScheduledTasks(until: {
            events == ["enrichment-start"] && clock.pendingWaiterCount == 2
        })
        XCTAssertEqual(events, ["enrichment-start"])

        clock.advance(by: 1)
        await queue.waitUntilIdle()
        XCTAssertEqual(
            events,
            ["enrichment-start", "enrichment-cancelled", "auto-resume"]
        )
    }

    func testRequiredRebuildCompletesOnlyForAnActuallyEmptyLibrary() {
        XCTAssertTrue(IndexingService.shouldCompleteEmptyRequiredRebuild(
            rebuildRequired: true,
            hasMediaCandidates: false
        ))
        XCTAssertFalse(IndexingService.shouldCompleteEmptyRequiredRebuild(
            rebuildRequired: true,
            hasMediaCandidates: true
        ))
        XCTAssertFalse(IndexingService.shouldCompleteEmptyRequiredRebuild(
            rebuildRequired: false,
            hasMediaCandidates: false
        ))
    }

    func testCancelAllCancelsActiveAndPendingJobs() async {
        let queue = IndexingJobQueue()
        var activeCancelled = false
        var pendingRan = false

        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return .completed
            } catch {
                activeCancelled = true
                return .cancelled
            }
        })
        await Task.yield()
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexVideos,
            priority: .userInitiated
        ) {
            pendingRan = true
            return .completed
        })

        queue.cancelAll()
        await queue.waitUntilIdle()

        XCTAssertTrue(activeCancelled)
        XCTAssertFalse(pendingRan)
        XCTAssertEqual(queue.retainedCancellationCount, 0)
        XCTAssertEqual(queue.retainedWorkflowCount, 0)
    }

    private func settleScheduledTasks(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}
