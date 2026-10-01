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

    func testBookmarkCleanupFailureDoesNotMaskRegistrationFailure() async {
        enum RegistrationFailure: Error { case duplicate }
        enum CleanupFailure: Error { case removeDenied }

        do {
            try await FolderSourceRegistration.register(
                bookmarkData: Data([1]),
                sourceId: "failed-source",
                persistBookmark: { _ in },
                insertSource: { throw RegistrationFailure.duplicate },
                removeSource: {},
                removeBookmark: { throw CleanupFailure.removeDenied }
            )
            XCTFail("Expected registration to fail")
        } catch {
            XCTAssertTrue(error is RegistrationFailure)
        }
    }

    func testSourceRollbackFailurePreservesBookmarkForRetry() async {
        enum RollbackFailure: Error { case databaseUnavailable }
        let inserted = expectation(description: "source inserted")
        let releaseInsert = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: true)

        let registration = Task<Void, Error> {
            try await FolderSourceRegistration.register(
                bookmarkData: Data([1]),
                sourceId: "rollback-failed-source",
                persistBookmark: { _ in state.withLock { $0 = true } },
                insertSource: {
                    inserted.fulfill()
                    releaseInsert.wait()
                },
                removeSource: { throw RollbackFailure.databaseUnavailable },
                removeBookmark: { state.withLock { $0 = false } }
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
        XCTAssertTrue(state.withLock { $0 })
    }
}
