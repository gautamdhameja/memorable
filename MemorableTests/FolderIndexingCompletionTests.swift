import XCTest
@testable import Memorable

final class FolderIndexingCompletionTests: XCTestCase {
    func testCappedDirectoryScanWarnsEvenWhenEveryReturnedFileWasHandled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["one.jpg", "two.jpg", "three.jpg"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let scan = FolderScanner.scanFolder(at: folder, maximumImageCount: 2)

        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(scan.imageURLs.count, 2)
        XCTAssertEqual(FolderScanCompletionPolicy.warningOutcome(
            directoryScanWasComplete: scan.isComplete,
            failedFileCount: 0,
            successfullyHandledFileCount: scan.imageURLs.count
        ), .completedWithWarnings)
        XCTAssertFalse(FolderScanCompletionPolicy.isComplete(
            directoryScanWasComplete: scan.isComplete,
            failedFileCount: 0,
            successfullyHandledFileCount: scan.imageURLs.count
        ), "An incomplete traversal must not authorize deletion of unseen rows")
    }

    func testInaccessibleEmptyScanFailsInsteadOfReportingAnEmptyFolderComplete() {
        XCTAssertEqual(FolderScanCompletionPolicy.warningOutcome(
            directoryScanWasComplete: false,
            failedFileCount: 0,
            successfullyHandledFileCount: 0
        ), .failed)
    }

    func testCompleteEmptyScanRemainsSuccessful() {
        XCTAssertNil(FolderScanCompletionPolicy.warningOutcome(
            directoryScanWasComplete: true,
            failedFileCount: 0,
            successfullyHandledFileCount: 0
        ))
    }

    func testUnreadableFileWarningsKeepExistingPartialSuccessBehavior() {
        XCTAssertEqual(FolderScanCompletionPolicy.warningOutcome(
            directoryScanWasComplete: true,
            failedFileCount: 1,
            successfullyHandledFileCount: 1
        ), .completedWithWarnings)
        XCTAssertEqual(FolderScanCompletionPolicy.warningOutcome(
            directoryScanWasComplete: true,
            failedFileCount: 1,
            successfullyHandledFileCount: 0
        ), .failed)
    }
}
