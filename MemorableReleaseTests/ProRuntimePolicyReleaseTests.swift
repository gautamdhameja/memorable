import XCTest
@testable import Memorable

final class ProRuntimePolicyReleaseTests: XCTestCase {
    func testProductionEntitlementLifecycleIsEnabled() {
        #if DEBUG
        XCTFail("Release policy test must not compile with DEBUG")
        #else
        XCTAssertEqual(
            ProRuntimePolicy.current,
            ProRuntimePolicy(
                initiallyPro: false,
                performsEntitlementVerification: true,
                listensForTransactionUpdates: true
            )
        )
        #endif
    }
}
