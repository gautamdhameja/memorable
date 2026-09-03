import XCTest
@testable import Memorable

@MainActor
final class BackgroundIndexingControllerTests: XCTestCase {
    private final class TaskHandle: BackgroundIndexingTaskHandle {
        private(set) var completions: [Bool] = []
        private(set) var progressUpdates: [(Int64, String, String)] = []
        private var expirationHandler: (@MainActor @Sendable () -> Void)?
        private let completionRecorded: (Bool) -> Void

        init(completionRecorded: @escaping (Bool) -> Void = { _ in }) {
            self.completionRecorded = completionRecorded
        }

        func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
            expirationHandler = handler
        }

        func setTaskCompleted(success: Bool) {
            completions.append(success)
            completionRecorded(success)
        }

        func updateProgress(completedUnits: Int64, title: String, subtitle: String) {
            progressUpdates.append((completedUnits, title, subtitle))
        }

        func expire() {
            expirationHandler?()
        }
    }

    func testCompletedLaunchFinishesSystemTaskSuccessfully() async {
        let controller = BackgroundIndexingController()
        let task = TaskHandle()
        controller.configure(resume: { .completed }, expire: {})

        await controller.handleLaunch(task)?.value

        XCTAssertEqual(task.completions, [true])
        XCTAssertFalse(controller.hasActiveSystemTask)
    }

    func testRetryableFailureSchedulesRecoveryBeforeFailingTask() async {
        var events: [String] = []
        let controller = BackgroundIndexingController {
            events.append("recovery")
        }
        let task = TaskHandle { success in
            events.append("completion=\(success)")
        }
        controller.configure(resume: { .retryableFailure }, expire: {})

        await controller.handleLaunch(task)?.value

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(events, ["recovery", "completion=false"])
        XCTAssertFalse(controller.hasActiveSystemTask)
    }

    func testTerminalFailureFinishesTaskWithoutSchedulingRecovery() async {
        var recoveryCount = 0
        let controller = BackgroundIndexingController {
            recoveryCount += 1
        }
        let task = TaskHandle()
        controller.configure(resume: { .terminalFailure }, expire: {})

        await controller.handleLaunch(task)?.value

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertFalse(controller.hasActiveSystemTask)
    }

    func testUnconfiguredLaunchFailsClosedInsteadOfLeakingAssertion() async {
        let controller = BackgroundIndexingController()
        let task = TaskHandle()

        await controller.handleLaunch(task)?.value

        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(controller.hasActiveSystemTask)
    }

    func testRunningLaunchRetainsAssertionAndRejectsDuplicateLaunch() async {
        let controller = BackgroundIndexingController()
        let firstTask = TaskHandle()
        let duplicateTask = TaskHandle()
        controller.configure(resume: { .running }, expire: {})

        await controller.handleLaunch(firstTask)?.value
        let duplicateRunner = controller.handleLaunch(duplicateTask)

        XCTAssertTrue(controller.hasActiveSystemTask)
        XCTAssertTrue(firstTask.completions.isEmpty)
        XCTAssertNil(duplicateRunner)
        XCTAssertEqual(duplicateTask.completions, [false])

        controller.initialIndexingWasInterrupted()
        XCTAssertEqual(firstTask.completions, [false])
    }

    func testExpirationCancelsSuspendedRunnerSchedulesRecoveryBeforeCompletionAndCannotCompleteLate() async {
        var expirationCount = 0
        var recoveryCount = 0
        var cancellationCount = 0
        var resumeStarted = false
        var events: [String] = []
        let controller = BackgroundIndexingController {
            recoveryCount += 1
            events.append("recovery")
        }
        let task = TaskHandle { success in
            events.append("completion=\(success)")
        }
        controller.configure(
            resume: {
                resumeStarted = true
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    cancellationCount += 1
                } catch {
                    XCTFail("Unexpected suspended resume error: \(error)")
                }
                return .completed
            },
            expire: { expirationCount += 1 }
        )
        let runner = controller.handleLaunch(task)
        for _ in 0..<1_000 where !resumeStarted {
            await Task.yield()
        }
        XCTAssertTrue(resumeStarted)

        task.expire()
        await runner?.value

        XCTAssertEqual(expirationCount, 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(events, ["recovery", "completion=false"])
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(controller.hasActiveSystemTask)
    }

    func testTerminalInitialIndexingOutcomesDoNotScheduleRecovery() async {
        var completionRecoveryCount = 0
        let completionController = BackgroundIndexingController {
            completionRecoveryCount += 1
        }
        let completionTask = TaskHandle()
        completionController.configure(resume: { .running }, expire: {})
        await completionController.handleLaunch(completionTask)?.value

        completionController.initialIndexingDidComplete()

        XCTAssertEqual(completionTask.completions, [true])
        XCTAssertEqual(completionRecoveryCount, 0)
        XCTAssertFalse(completionController.hasActiveSystemTask)

        var stoppedRecoveryCount = 0
        let stoppedController = BackgroundIndexingController {
            stoppedRecoveryCount += 1
        }
        let stoppedTask = TaskHandle()
        stoppedController.configure(resume: { .running }, expire: {})
        await stoppedController.handleLaunch(stoppedTask)?.value

        stoppedController.initialIndexingWasStopped()

        XCTAssertEqual(stoppedTask.completions, [false])
        XCTAssertEqual(stoppedRecoveryCount, 0)
        XCTAssertFalse(stoppedController.hasActiveSystemTask)
    }

    func testContinuedProcessingRequiresAnActiveUserInitiatedStart() {
        XCTAssertTrue(ContinuedProcessingSubmissionPolicy.shouldSubmit(
            isApplicationActive: true,
            isUserInitiated: true
        ))
        XCTAssertFalse(ContinuedProcessingSubmissionPolicy.shouldSubmit(
            isApplicationActive: false,
            isUserInitiated: true
        ))
        XCTAssertFalse(ContinuedProcessingSubmissionPolicy.shouldSubmit(
            isApplicationActive: true,
            isUserInitiated: false
        ))
        XCTAssertFalse(ContinuedProcessingSubmissionPolicy.shouldSubmit(
            isApplicationActive: false,
            isUserInitiated: false
        ))
    }

    func testProgressUpdatesAreCoalescedUntilValueOrSubtitleChanges() async {
        let controller = BackgroundIndexingController()
        let task = TaskHandle()
        controller.configure(resume: { .running }, expire: {})
        await controller.handleLaunch(task)?.value
        let progress = IndexingProgress(total: 100, completed: 50, isRunning: true, phase: .photos)

        controller.update(progress: progress)
        controller.update(progress: progress)

        XCTAssertEqual(task.progressUpdates.count, 2)
        XCTAssertEqual(task.progressUpdates.last?.0, 375)
        controller.initialIndexingWasStopped()
    }
}
