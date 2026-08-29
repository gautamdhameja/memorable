import Photos
import XCTest
import os
@testable import Memorable

final class PhotoKitRequestControllerTests: XCTestCase {
    private final class CancelledRequests: Sendable {
        private let requestIDs = OSAllocatedUnfairLock(initialState: [PHImageRequestID]())

        func record(_ requestID: PHImageRequestID) {
            requestIDs.withLock { $0.append(requestID) }
        }

        func snapshot() -> [PHImageRequestID] {
            requestIDs.withLock { $0 }
        }
    }

    private final class Counter: Sendable {
        private let valueLock = OSAllocatedUnfairLock(initialState: 0)

        func increment() {
            valueLock.withLock { $0 += 1 }
        }

        func value() -> Int {
            valueLock.withLock { $0 }
        }
    }

    func testCancellationResumesPendingContinuation() async {
        let cancellations = CancelledRequests()
        let controller = makeController(cancellations: cancellations)
        let value: Int? = await withCheckedContinuation { continuation in
            controller.installContinuation(ContinuationGuard(continuation))
            controller.cancel()
        }

        XCTAssertNil(value)
        XCTAssertTrue(cancellations.snapshot().isEmpty)
    }

    func testCancellationBeforeRequestRegistrationCancelsLateRequest() async {
        let cancellations = CancelledRequests()
        let controller = makeController(cancellations: cancellations)
        let value: Int? = await withCheckedContinuation { continuation in
            controller.installContinuation(ContinuationGuard(continuation))
            controller.cancel()
            controller.registerRequestID(42)
        }

        XCTAssertNil(value)
        XCTAssertEqual(cancellations.snapshot(), [42])
    }

    func testCancellationCleanupRunsExactlyOnce() async {
        let cancellations = CancelledRequests()
        let cleanupCount = Counter()
        let controller = PhotoKitRequestController<Int>(
            cancelRequest: cancellations.record,
            onCancel: cleanupCount.increment
        )
        let value: Int? = await withCheckedContinuation { continuation in
            controller.installContinuation(ContinuationGuard(continuation))
            controller.registerRequestID(44)
            controller.cancel()
            controller.cancel()
        }

        XCTAssertNil(value)
        XCTAssertEqual(cancellations.snapshot(), [44])
        XCTAssertEqual(cleanupCount.value(), 1)
    }

    func testCompletionWinsOverLaterCancellation() async {
        let cancellations = CancelledRequests()
        let controller = makeController(cancellations: cancellations)
        let value: Int? = await withCheckedContinuation { continuation in
            controller.installContinuation(ContinuationGuard(continuation))
            controller.registerRequestID(17)
            controller.finish(7)
            controller.cancel()
        }

        XCTAssertEqual(value, 7)
        XCTAssertTrue(cancellations.snapshot().isEmpty)
    }

    func testReplacingTimeoutPreventsPriorDeadlineFromFiring() async {
        let cancellations = CancelledRequests()
        let firstDeadline = Counter()
        let controller = makeController(cancellations: cancellations)
        let value: Int? = await withCheckedContinuation { continuation in
            controller.installContinuation(ContinuationGuard(continuation))
            controller.scheduleTimeout(seconds: 0.01) {
                firstDeadline.increment()
            }
            controller.scheduleTimeout(seconds: 0.03) {
                controller.cancel()
            }
        }

        XCTAssertNil(value)
        XCTAssertEqual(firstDeadline.value(), 0)
    }

    func testBeginningNextPhaseStopsAssetDeadlineDuringSetup() async {
        let cancellations = CancelledRequests()
        let controller = makeController(cancellations: cancellations)
        let value: Int? = await withCheckedContinuation { continuation in
            controller.installContinuation(ContinuationGuard(continuation))
            controller.registerRequestID(23)
            controller.scheduleTimeout(seconds: 0.01) {
                controller.cancel()
            }
            XCTAssertTrue(controller.beginNextPhase())
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000)
                controller.finish(7)
            }
        }

        XCTAssertEqual(value, 7)
        XCTAssertTrue(cancellations.snapshot().isEmpty)
    }

    private func makeController(
        cancellations: CancelledRequests
    ) -> PhotoKitRequestController<Int> {
        PhotoKitRequestController(cancelRequest: cancellations.record)
    }
}
