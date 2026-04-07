import XCTest
@testable import Memorable

final class AppConstantsTests: XCTestCase {

    // MARK: - AppKeys

    func testFolderBookmarkKey() {
        let key = AppKeys.folderBookmark(sourceId: "abc123")
        XCTAssertEqual(key, "folder_bookmark_abc123")
    }

    func testFolderBookmarkKeyUniqueness() {
        let key1 = AppKeys.folderBookmark(sourceId: "a")
        let key2 = AppKeys.folderBookmark(sourceId: "b")
        XCTAssertNotEqual(key1, key2)
    }

    func testOnboardingKeyStable() {
        // Key must never change — existing users depend on it
        XCTAssertEqual(AppKeys.onboardingComplete, "onboarding_complete")
    }

    // MARK: - IndexingConfig

    func testBatchSizePositive() {
        XCTAssertGreaterThan(IndexingConfig.batchInsertSize, 0)
        XCTAssertGreaterThan(IndexingConfig.batchEncodeSize, 0)
    }

    func testOrphanRatioReasonable() {
        XCTAssertGreaterThan(IndexingConfig.maxOrphanRatio, 0)
        XCTAssertLessThan(IndexingConfig.maxOrphanRatio, 1.0)
    }

    func testLargeLibraryThreshold() {
        XCTAssertGreaterThan(IndexingConfig.largeLibraryThreshold, 0)
    }

    // MARK: - TimeoutConfig

    func testTimeoutsPositive() {
        XCTAssertGreaterThan(TimeoutConfig.imageLoad, 0)
        XCTAssertGreaterThan(TimeoutConfig.videoLoad, 0)
    }

    func testVideoTimeoutLongerThanImage() {
        XCTAssertGreaterThanOrEqual(TimeoutConfig.videoLoad, TimeoutConfig.imageLoad,
            "Video loading should have at least as long a timeout as image loading")
    }

    // MARK: - FreeTier

    func testFreeTierLimit() {
        XCTAssertGreaterThan(FreeTier.maxPhotos, 0)
    }
}
