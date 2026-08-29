import XCTest
import os
@testable import Memorable

@MainActor
final class FolderSourceRegistrationTests: XCTestCase {
    func testCancellationAfterInsertRollsBackSourceAndBookmark() async {
        let inserted = expectation(description: "source inserted")
        let releaseInsert = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(
            initialState: (bookmark: false, source: false)
        )

        let registration = Task<Void, Error> {
            try await FolderSourceRegistration.register(
                bookmarkData: Data([1]),
                sourceId: "cancelled-source",
                persistBookmark: { _ in state.withLock { $0.bookmark = true } },
                insertSource: {
                    state.withLock { $0.source = true }
                    inserted.fulfill()
                    releaseInsert.wait()
                },
                removeSource: { state.withLock { $0.source = false } },
                removeBookmark: { state.withLock { $0.bookmark = false } }
            )
        }

        await fulfillment(of: [inserted], timeout: 1)
        registration.cancel()
        releaseInsert.signal()

        do {
            try await registration.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(state.withLock { $0.bookmark })
        XCTAssertFalse(state.withLock { $0.source })
    }
}
