import XCTest
import os
@testable import Memorable

final class TokenizerConcurrencyTests: XCTestCase {
    private final class ResultStore: Sendable {
        private let values: OSAllocatedUnfairLock<[Result<[Int32], Error>?]>

        init(count: Int) {
            values = OSAllocatedUnfairLock(initialState: Array(repeating: nil, count: count))
        }

        func set(_ value: Result<[Int32], Error>, at index: Int) {
            values.withLock { $0[index] = value }
        }

        func snapshot() -> [Result<[Int32], Error>?] {
            values.withLock { $0 }
        }
    }

    func testConcurrentTokenizationMatchesSingleThreadedResults() throws {
        let referenceTokenizer = try CLIPTokenizer()
        let concurrentTokenizer = try CLIPTokenizer()
        let queries = (0..<1_250).map { index in
            "unique image search query number \(index) with café 📷"
        }
        let expected = try queries.map { try referenceTokenizer.tokenize(text: $0) }

        let iterationCount = queries.count * 2
        let results = ResultStore(count: iterationCount)
        DispatchQueue.concurrentPerform(iterations: iterationCount) { index in
            let queryIndex = index % queries.count
            results.set(
                Result { try concurrentTokenizer.tokenize(text: queries[queryIndex]) },
                at: index
            )
        }

        for (index, actual) in results.snapshot().enumerated() {
            XCTAssertEqual(try XCTUnwrap(actual).get(), expected[index % queries.count])
        }
    }
}
