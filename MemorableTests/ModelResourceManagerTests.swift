import XCTest
@testable import Memorable

final class ModelResourceManagerTests: XCTestCase {

    func testBundledStrategyIsRecorded() {
        let manager = ModelResourceManager(bundle: .main)

        XCTAssertEqual(manager.activeStrategy, .bundled)
    }

    func testMissingBundledResourceReportsRecoverableUnavailableState() {
        let manager = ModelResourceManager(bundle: Bundle(for: Self.self))

        let availability = manager.availability(for: .textEncoder)

        if case .unavailable(let message) = availability {
            XCTAssertTrue(message.contains("SigLIP2_TextEncoder"))
        } else {
            XCTFail("Expected missing test-bundle model to be unavailable")
        }
    }

    func testMissingBundledResourceThrowsResourceError() {
        let manager = ModelResourceManager(bundle: Bundle(for: Self.self))

        XCTAssertThrowsError(try manager.url(for: .imageEncoder)) { error in
            XCTAssertEqual(error as? ModelResourceError, .unavailable(.imageEncoder))
        }
    }
}
