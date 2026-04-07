import XCTest
@testable import Memorable

final class DataModelTests: XCTestCase {

    // MARK: - SearchResult

    func testSearchResultEquality() {
        let a = SearchResult(id: "1", score: 0.5, localIdentifier: "abc", creationDate: nil, isVideo: false, bestFramePosition: nil)
        let b = SearchResult(id: "1", score: 0.5, localIdentifier: "abc", creationDate: nil, isVideo: false, bestFramePosition: nil)
        XCTAssertEqual(a, b)
    }

    func testSearchResultInequality() {
        let a = SearchResult(id: "1", score: 0.5, localIdentifier: "abc", creationDate: nil, isVideo: false, bestFramePosition: nil)
        let b = SearchResult(id: "2", score: 0.8, localIdentifier: "def", creationDate: nil, isVideo: false, bestFramePosition: nil)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - EmbeddingConfig

    func testEmbeddingDimensions() {
        XCTAssertEqual(EmbeddingConfig.dimensions, 768)
    }

    func testBytesPerEmbedding() {
        XCTAssertEqual(EmbeddingConfig.bytesPerEmbedding, 768 * MemoryLayout<Float16>.size)
    }

    // MARK: - PhotoSourceType

    func testPhotoSourceTypeRawValues() {
        XCTAssertEqual(PhotoSourceType.photokit.rawValue, "photokit")
        XCTAssertEqual(PhotoSourceType.folder.rawValue, "folder")
    }

    // MARK: - Float16 Conversion

    func testToFloat16Data() {
        let floats: [Float] = [0.1, 0.2, 0.3]
        let data = floats.toFloat16Data()
        XCTAssertEqual(data.count, floats.count * MemoryLayout<Float16>.size)
    }

    func testFloat16RoundTrip() {
        let original: [Float] = [1.0, -0.5, 0.0, 0.75]
        let data = original.toFloat16Data()

        let recovered = data.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: Float16.self)
            return (0..<original.count).map { Float(ptr[$0]) }
        }

        for (a, b) in zip(original, recovered) {
            XCTAssertEqual(a, b, accuracy: 0.01, "Float16 round-trip should preserve values approximately")
        }
    }

    // MARK: - IndexingProgress

    func testProgressPercentage() {
        let progress = IndexingProgress(total: 100, completed: 50, isRunning: true)
        XCTAssertEqual(progress.percentage, 50.0)
    }

    func testProgressPercentageZeroTotal() {
        let progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
        XCTAssertEqual(progress.percentage, 0)
    }
}
