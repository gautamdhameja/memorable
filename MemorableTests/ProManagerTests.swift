import StoreKit
import XCTest
@testable import Memorable

@MainActor
final class ProManagerTests: XCTestCase {
    func testProductLoadingIsDeferredAndConcurrentRequestsAreCoalesced() async {
        var loadCount = 0
        var delayCount = 0
        let manager = ProManager(
            productLoader: { _ in
                loadCount += 1
                try await Task.sleep(nanoseconds: 25_000_000)
                return []
            },
            retryDelay: {
                delayCount += 1
            }
        )

        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(delayCount, 0)

        async let first: Void = manager.loadProduct()
        async let second: Void = manager.loadProduct()
        _ = await (first, second)

        XCTAssertEqual(loadCount, 2, "One request performs the initial load and one retry")
        XCTAssertEqual(delayCount, 1)
        XCTAssertFalse(manager.isLoadingProduct)
    }

    func testColdLaunchWithoutEntitlementReconcilesAlreadyFreeState() async {
        let manager = ProManager(productLoader: { _ in [] })
        manager.isPro = false
        var reconciliationCount = 0
        manager.onFreeTierReconciliationNeeded = {
            reconciliationCount += 1
        }

        await manager.reconcileVerifiedEntitlement(false)

        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(reconciliationCount, 1)
    }

    func testFreeStateIsReconciledAfterCallbackIsReattached() async {
        let manager = ProManager(productLoader: { _ in [] })
        manager.isPro = true
        manager.onFreeTierReconciliationNeeded = nil

        await manager.reconcileVerifiedEntitlement(false)

        var reconciliationCount = 0
        manager.onFreeTierReconciliationNeeded = {
            reconciliationCount += 1
        }
        await manager.reconcileVerifiedEntitlement(false)

        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(reconciliationCount, 1)
    }

    func testBelowCapReconciliationDoesNotReportLimitReached() {
        let result = FreeTierReconciliationResult(
            retainedMediaCount: 12,
            didTrimMedia: false,
            removedFolderSourceIDs: []
        )

        XCTAssertFalse(FreeTierStatePolicy.hitIndexLimit(
            previouslyHit: true,
            reconciliation: result
        ))
    }
}
