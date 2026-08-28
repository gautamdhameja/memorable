import XCTest
import os
@testable import Memorable

final class TokenizerConcurrencyTests: XCTestCase {
    private final class ResultStore: Sendable {
        private let values: OSAllocatedUnfairLock<[[Int32]?]>

        init(count: Int) {
            values = OSAllocatedUnfairLock(initialState: Array(repeating: nil, count: count))
        }

        func set(_ value: [Int32], at index: Int) {
            values.withLock { $0[index] = value }
        }

        func snapshot() -> [[Int32]?] {
            values.withLock { $0 }
        }
    }

    func testConcurrentTokenizationThroughEvictionMatchesSingleThreadedResults() throws {
        let referenceTokenizer = try CLIPTokenizer()
        let concurrentTokenizer = try CLIPTokenizer()
        let queries = (0..<1_250).map { index in
            "unique image search query number \(index) with café 📷"
        }
        let expected = queries.map { referenceTokenizer.tokenize(text: $0) }

        // Warm beyond the 1,000-entry limit so this test covers eviction before
        // exercising the same tokenizer from multiple concurrent callers.
        for query in queries {
            _ = concurrentTokenizer.tokenize(text: query)
        }

        let iterationCount = queries.count * 2
        let results = ResultStore(count: iterationCount)
        DispatchQueue.concurrentPerform(iterations: iterationCount) { index in
            let queryIndex = index % queries.count
            results.set(
                concurrentTokenizer.tokenize(text: queries[queryIndex]),
                at: index
            )
        }

        for (index, actual) in results.snapshot().enumerated() {
            XCTAssertEqual(actual, expected[index % queries.count])
        }
    }
}
