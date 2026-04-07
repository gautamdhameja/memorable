import XCTest
@testable import Memorable

final class SharedUtilitiesTests: XCTestCase {

    // MARK: - L2 Normalization

    func testL2NormalizeUnitVector() {
        var vec: [Float] = [1.0, 0.0, 0.0]
        vec.l2Normalize()
        XCTAssertEqual(vec[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(vec[1], 0.0, accuracy: 0.001)
    }

    func testL2NormalizeProducesUnitLength() {
        var vec: [Float] = [3.0, 4.0]
        vec.l2Normalize()

        let norm = sqrt(vec[0] * vec[0] + vec[1] * vec[1])
        XCTAssertEqual(norm, 1.0, accuracy: 0.001, "Normalized vector should have unit length")
    }

    func testL2NormalizeZeroVector() {
        var vec: [Float] = [0.0, 0.0, 0.0]
        vec.l2Normalize()
        // Should not crash, vector stays zero
        XCTAssertEqual(vec, [0.0, 0.0, 0.0])
    }

    func testL2NormalizePreservesDirection() {
        var vec: [Float] = [2.0, 2.0]
        vec.l2Normalize()
        // Both components should be equal (45 degree direction preserved)
        XCTAssertEqual(vec[0], vec[1], accuracy: 0.001)
    }

    // MARK: - Array Chunking

    func testChunkedEvenSplit() {
        let arr = [1, 2, 3, 4, 5, 6]
        let chunks = arr.chunked(into: 2)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], [1, 2])
        XCTAssertEqual(chunks[1], [3, 4])
        XCTAssertEqual(chunks[2], [5, 6])
    }

    func testChunkedUnevenSplit() {
        let arr = [1, 2, 3, 4, 5]
        let chunks = arr.chunked(into: 2)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[2], [5])
    }

    func testChunkedSingleChunk() {
        let arr = [1, 2, 3]
        let chunks = arr.chunked(into: 10)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], [1, 2, 3])
    }

    func testChunkedEmpty() {
        let arr: [Int] = []
        let chunks = arr.chunked(into: 5)
        XCTAssertTrue(chunks.isEmpty)
    }

    // MARK: - Safe Array Access

    func testSafeSubscriptValid() {
        let arr = [10, 20, 30]
        XCTAssertEqual(arr[safe: 0], 10)
        XCTAssertEqual(arr[safe: 2], 30)
    }

    func testSafeSubscriptOutOfBounds() {
        let arr = [10, 20, 30]
        XCTAssertNil(arr[safe: 3])
        XCTAssertNil(arr[safe: -1])
    }

    func testSafeSubscriptEmpty() {
        let arr: [Int] = []
        XCTAssertNil(arr[safe: 0])
    }
}
