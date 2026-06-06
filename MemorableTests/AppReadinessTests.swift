import XCTest
@testable import Memorable

final class AppReadinessTests: XCTestCase {

    func testInitialReadinessHasNoReadyStates() {
        let readiness = AppReadiness()

        XCTAssertFalse(readiness.isShellReady)
        XCTAssertFalse(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isIndexReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testShellReadyDoesNotImplySemanticReadiness() {
        var readiness = AppReadiness()

        readiness.markShellReady()

        XCTAssertTrue(readiness.isShellReady)
        XCTAssertFalse(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isIndexReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testSemanticModelReadyWithoutIndexIsNotSearchReady() {
        var readiness = AppReadiness()

        readiness.markSemanticModelReady()

        XCTAssertTrue(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testSemanticModelAndIndexReadyMarksSemanticSearchReady() {
        var readiness = AppReadiness()

        readiness.markSemanticModelReady()
        readiness.markIndexReady()

        XCTAssertTrue(readiness.isSemanticSearchReady)
    }

    func testMemoryRecoveryCanDropOnlyIndexReadiness() {
        var readiness = AppReadiness()
        readiness.markShellReady()
        readiness.markSemanticModelReady()
        readiness.markIndexReady()

        readiness.markIndexUnavailable()

        XCTAssertTrue(readiness.isShellReady)
        XCTAssertTrue(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isIndexReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }
}
