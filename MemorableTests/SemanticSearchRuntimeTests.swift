import XCTest
@testable import Memorable

final class SemanticSearchRuntimeTests: XCTestCase {

    private enum LoaderError: Error { case failedDuringCancellation }

    @MainActor
    func testCancelledLoaderReturningSuccessCannotReportSearchReady() async {
        let runtime = SemanticSearchRuntime()
        let started = expectation(description: "loader started")
        let finished = expectation(description: "search waiter cancelled")
        var continuation: CheckedContinuation<Void, Never>?
        runtime.setWarmupLoader { _ in
            await withCheckedContinuation { held in
                continuation = held
                started.fulfill()
            }
        }
        let waiter = Task { @MainActor in
            do {
                try await runtime.prepareForSearch()
                XCTFail("A cancelled loader must not report success")
            } catch is CancellationError {
                // The loader ignored cancellation, but readiness did not.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        runtime.cancelWarmupForMemoryPressure()
        continuation?.resume()
        await fulfillment(of: [finished], timeout: 2)
        waiter.cancel()
        XCTAssertFalse(runtime.readiness.isSemanticSearchReady)
        guard case .failed = runtime.phase else {
            return XCTFail("Expected a recoverable paused state")
        }
    }

    @MainActor
    func testGenericErrorFromCancelledLoaderDrainsBeforeRetry() async {
        let runtime = SemanticSearchRuntime()
        let started = expectation(description: "first loader started")
        let retryStarted = expectation(description: "retry requested")
        let finished = expectation(description: "retry completed")
        var continuation: CheckedContinuation<Void, Error>?
        var loadCount = 0
        runtime.setWarmupLoader { _ in
            loadCount += 1
            if loadCount == 1 {
                try await withCheckedThrowingContinuation { held in
                    continuation = held
                    started.fulfill()
                }
            } else {
                runtime.markSemanticModelReady()
                runtime.markIndexReady()
            }
        }
        runtime.startPostPaintWarmup()
        await fulfillment(of: [started], timeout: 1)
        runtime.cancelWarmupForMemoryPressure()
        let retry = Task { @MainActor in
            retryStarted.fulfill()
            do { try await runtime.prepareForSearch() }
            catch { XCTFail("Retry failed: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [retryStarted], timeout: 1)
        continuation?.resume(throwing: LoaderError.failedDuringCancellation)
        await fulfillment(of: [finished], timeout: 2)
        retry.cancel()
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testSecondMemoryWarningCanWithdrawRetryWhileLoaderDrains() async {
        let runtime = SemanticSearchRuntime()
        let started = expectation(description: "loader started")
        let retryStarted = expectation(description: "retry requested")
        let finished = expectation(description: "retry terminated")
        var continuation: CheckedContinuation<Void, Error>?
        var loadCount = 0
        runtime.setWarmupLoader { _ in
            loadCount += 1
            try await withCheckedThrowingContinuation { held in
                continuation = held
                started.fulfill()
            }
        }
        runtime.startPostPaintWarmup()
        await fulfillment(of: [started], timeout: 1)
        runtime.cancelWarmupForMemoryPressure()
        let retry = Task { @MainActor in
            retryStarted.fulfill()
            do {
                try await runtime.prepareForSearch()
                XCTFail("Withdrawn retry must not succeed")
            } catch is CancellationError {
                // The later memory warning deliberately leaves search paused.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [retryStarted], timeout: 1)
        runtime.cancelWarmupForMemoryPressure()
        continuation?.resume(throwing: LoaderError.failedDuringCancellation)
        await fulfillment(of: [finished], timeout: 2)
        retry.cancel()
        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(runtime.readiness.isSemanticSearchReady)
    }

    func testCancelledWarmupCannotConsumePendingOnboardingIndexRequest() {
        XCTAssertFalse(AppState.mayConsumePendingOnboardingRequest(isCancelled: true))
        XCTAssertTrue(AppState.mayConsumePendingOnboardingRequest(isCancelled: false))
    }

    @MainActor
    func testPreStartCancellationNeverInvokesWarmupLoader() async {
        let runtime = SemanticSearchRuntime()
        var loadCount = 0
        runtime.setWarmupLoader { _ in loadCount += 1 }

        runtime.startPostPaintWarmup()
        runtime.cancelWarmupForMemoryPressure()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(loadCount, 0)
    }

    @MainActor
    func testPostPaintWarmupCallsLoaderOnceAcrossConcurrentWaiters() async throws {
        let runtime = SemanticSearchRuntime()
        var loadCount = 0
        runtime.setWarmupLoader { _ in
            loadCount += 1
            try await Task.sleep(nanoseconds: 10_000_000)
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        runtime.startPostPaintWarmup()
        let first = Task { @MainActor in try await runtime.prepareForSearch() }
        let second = Task { @MainActor in try await runtime.prepareForSearch() }
        try await first.value
        try await second.value

        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(runtime.readiness.isSemanticSearchReady)
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testPrepareForSearchPromotesWarmup() async throws {
        let runtime = SemanticSearchRuntime()
        var priorities: [SemanticWarmupPriority] = []
        runtime.setWarmupLoader { priority in
            priorities.append(priority)
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        try await runtime.prepareForSearch()

        XCTAssertEqual(priorities, [.userInitiatedSearch])
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testPrepareForSearchPromotesExistingPostPaintWarmup() async throws {
        let runtime = SemanticSearchRuntime()
        var didPromote = false
        runtime.setPromotionHandler {
            didPromote = true
        }
        runtime.setWarmupLoader { _ in
            try await Task.sleep(nanoseconds: 10_000_000)
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        runtime.startPostPaintWarmup()
        try await runtime.prepareForSearch()

        XCTAssertTrue(didPromote)
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testModelReadyWithoutIndexWaitsForIndex() async throws {
        let runtime = SemanticSearchRuntime()
        runtime.setWarmupLoader { _ in
            runtime.markSemanticModelReady()
            runtime.markIndexUnavailable()
        }

        runtime.startPostPaintWarmup()
        try await runtime.prepareForSearch()

        XCTAssertTrue(runtime.readiness.isSemanticModelReady)
        XCTAssertFalse(runtime.readiness.isSemanticSearchReady)
        XCTAssertEqual(runtime.phase, .waitingForIndex)
    }

    @MainActor
    func testIndexAvailabilityCheckIsDistinctFromMissingIndex() {
        let runtime = SemanticSearchRuntime()

        runtime.markSemanticModelReady()
        XCTAssertFalse(runtime.isCheckingIndexAvailability)

        runtime.markIndexWarming()
        XCTAssertTrue(runtime.isCheckingIndexAvailability)

        runtime.markIndexReady()
        XCTAssertFalse(runtime.isCheckingIndexAvailability)

        runtime.markIndexWarming()
        runtime.markIndexUnavailable()
        XCTAssertFalse(runtime.isCheckingIndexAvailability)
        XCTAssertEqual(runtime.phase, .waitingForIndex)
    }

    @MainActor
    func testMemoryPressureCancellationStopsAnInitialWarmup() async {
        let runtime = SemanticSearchRuntime()
        var started = false
        var observedCancellation = false
        runtime.setWarmupLoader { _ in
            started = true
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch is CancellationError {
                observedCancellation = true
                throw CancellationError()
            }
        }

        runtime.startPostPaintWarmup()
        while !started { await Task.yield() }
        runtime.cancelWarmupForMemoryPressure()
        for _ in 0..<10 where !observedCancellation { await Task.yield() }

        XCTAssertTrue(observedCancellation)
        XCTAssertFalse(runtime.readiness.isSemanticModelReady)
        guard case .failed(let message) = runtime.phase else {
            return XCTFail("Expected a recoverable paused state")
        }
        XCTAssertTrue(message.contains("Try Again"))
    }

    @MainActor
    func testImmediateRetryWaitsForCancelledWarmupToDrain() async {
        let runtime = SemanticSearchRuntime()
        var loadCount = 0
        var firstLoadStarted = false
        var releaseCancellationCleanup = false
        runtime.setWarmupLoader { _ in
            loadCount += 1
            if loadCount == 1 {
                firstLoadStarted = true
                while !Task.isCancelled { await Task.yield() }
                while !releaseCancellationCleanup { await Task.yield() }
                throw CancellationError()
            }
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        runtime.startPostPaintWarmup()
        while !firstLoadStarted { await Task.yield() }
        runtime.cancelWarmupForMemoryPressure()
        runtime.startUserInitiatedWarmup()

        XCTAssertEqual(loadCount, 1)
        releaseCancellationCleanup = true
        while loadCount < 2 { await Task.yield() }
        while runtime.phase != .ready { await Task.yield() }

        XCTAssertEqual(loadCount, 2)
        XCTAssertTrue(runtime.readiness.isSemanticSearchReady)
    }

    @MainActor
    func testCancelledSearchWaiterCannotRestartMemoryPressureWarmup() async {
        let runtime = SemanticSearchRuntime()
        var loadCount = 0
        var firstLoadStarted = false
        var releaseCancellationCleanup = false
        runtime.setWarmupLoader { _ in
            loadCount += 1
            firstLoadStarted = true
            while !Task.isCancelled { await Task.yield() }
            while !releaseCancellationCleanup { await Task.yield() }
            throw CancellationError()
        }

        runtime.startPostPaintWarmup()
        while !firstLoadStarted { await Task.yield() }
        runtime.cancelWarmupForMemoryPressure()

        let waiter = Task { @MainActor in
            try await runtime.prepareForSearch()
        }
        waiter.cancel()
        _ = await waiter.result
        releaseCancellationCleanup = true
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(runtime.readiness.isSemanticModelReady)
        guard case .failed = runtime.phase else {
            return XCTFail("Expected memory-pressure cancellation to remain paused")
        }
    }
}
