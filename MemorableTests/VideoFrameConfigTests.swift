import XCTest
@testable import Memorable

final class VideoFrameConfigTests: XCTestCase {

    func testShortVideo() {
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 5.0), 2)
    }

    func testMediumVideo() {
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 30.0), 3)
    }

    func testLongVideo() {
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 120.0), 5)
    }

    func testBoundary10Seconds() {
        // Exactly 10 seconds should be medium
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 10.0), 3)
    }

    func testBoundary60Seconds() {
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 60.0), 3)
    }

    func testBoundaryJustOver60() {
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 60.1), 5)
    }

    func testVeryShortVideo() {
        XCTAssertEqual(VideoFrameConfig.frameCount(forDuration: 0.5), 2)
    }

    func testFramePositionsSingle() {
        let positions = VideoFrameExtractor.framePositions(count: 1)
        XCTAssertEqual(positions, [0.5])
    }

    func testFramePositionsMultiple() {
        let positions = VideoFrameExtractor.framePositions(count: 3)
        XCTAssertEqual(positions.count, 3)
        // Should span 10%-90%
        XCTAssertEqual(positions.first!, 0.1, accuracy: 0.01)
        XCTAssertEqual(positions.last!, 0.9, accuracy: 0.01)
    }

    func testFramePositionsEmpty() {
        let positions = VideoFrameExtractor.framePositions(count: 0)
        XCTAssertTrue(positions.isEmpty)
    }
}
