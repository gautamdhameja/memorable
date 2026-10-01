import XCTest
@testable import Memorable

@MainActor
final class ProFolderIndexingOperationTests: XCTestCase {
    func testPendingFolderJobRechecksEntitlementBeforeExecution() async {
        let queue = IndexingJobQueue()
        let blockerStarted = expectation(description: "blocker started")
        let releaseBlocker = AsyncGate()
        var isPro = true
        var folderOperationRan = false

        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexPhotos,
            priority: .userInitiated
        ) {
            blockerStarted.fulfill()
            await releaseBlocker.wait()
            return .completed
        })
        queue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexFolder,
            priority: .userInitiated
        ) {
            await ProFolderIndexingOperation.run(isEntitled: { isPro }) {
                folderOperationRan = true
                return .completed
            }
        })

        await fulfillment(of: [blockerStarted], timeout: 1)
        isPro = false
        await releaseBlocker.open()
        await queue.waitUntilIdle()

        XCTAssertFalse(folderOperationRan)
    }

    func testFailedFolderOperationDoesNotCompleteItsJob() async {
        let outcome = await ProFolderIndexingOperation.run(isEntitled: { true }) {
            .failed
        }

        XCTAssertEqual(outcome, .cancelled)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
