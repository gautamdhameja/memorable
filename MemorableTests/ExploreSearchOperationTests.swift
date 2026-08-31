import XCTest
import os
@testable import Memorable

final class ExploreSearchOperationTests: XCTestCase {
    func testExploreRetriesWhenMemoryFilteringRemovesFirstMatches() async throws {
        let filteredPhoto = SearchResult(
            id: "filtered",
            score: 0.4,
            localIdentifier: "filtered",
            creationDate: nil,
            isVideo: false,
            bestFramePosition: nil
        )
        let eligiblePhoto = SearchResult(
            id: "eligible",
            score: 0.5,
            localIdentifier: "eligible",
            creationDate: nil,
            isVideo: false,
            bestFramePosition: nil
        )
        let attempts = OSAllocatedUnfairLock(initialState: [String]())

        let match = try await ExploreSearchOperation.firstEligibleMatch(
            suggestions: ["first", "second", "unused"],
            search: { query in
                attempts.withLock { $0.append(query) }
                return query == "first" ? [filteredPhoto] : [eligiblePhoto]
            },
            filter: { results in
                results.filter { $0.id == eligiblePhoto.id }
            }
        )

        XCTAssertEqual(attempts.withLock { $0 }, ["first", "second"])
        XCTAssertEqual(match?.query, "second")
        XCTAssertEqual(match?.results, [eligiblePhoto])
    }

    func testExploreStopsAfterBoundedSuggestionAttempts() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: [String]())

        let match = try await ExploreSearchOperation.firstEligibleMatch(
            suggestions: ["one", "two", "three", "four"],
            search: { query in
                attempts.withLock { $0.append(query) }
                return []
            },
            filter: { $0 }
        )

        XCTAssertNil(match)
        XCTAssertEqual(
            attempts.withLock { $0 },
            ["one", "two", "three"]
        )
    }

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
