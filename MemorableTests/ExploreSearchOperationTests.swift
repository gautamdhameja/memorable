import XCTest
@testable import Memorable

final class ExploreSearchOperationTests: XCTestCase {
    func testCancellationStopsExploreSearchBeforeResultsCanBeApplied() async {
        let started = expectation(description: "search started")
        let operation = Task {
            try await ExploreSearchOperation.run {
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        }

        await fulfillment(of: [started], timeout: 1)
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
