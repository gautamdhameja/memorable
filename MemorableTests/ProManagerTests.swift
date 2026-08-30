import StoreKit
import XCTest
import os
@testable import Memorable

@MainActor
final class ProManagerTests: XCTestCase {
    func testRuntimePolicyMatchesBuildConfiguration() {
        #if DEBUG
        XCTAssertEqual(
            ProRuntimePolicy.current,
            ProRuntimePolicy(
                initiallyPro: true,
                performsEntitlementVerification: false,
                listensForTransactionUpdates: false
            )
        )
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

    func testInjectedEntitledVerificationPublishesProWithoutLiveListener() async {
        var verificationCount = 0
        let manager = ProManager(
            productLoader: { _ in [] },
            entitlementVerifier: {
                verificationCount += 1
                return .entitled
            }
        )
        manager.isPro = false

        await manager.verifyEntitlement()

        XCTAssertEqual(verificationCount, 1)
        XCTAssertTrue(manager.isPro)
        #if DEBUG
        XCTAssertFalse(manager.isTransactionListenerRunning)
        #endif
    }

    func testInjectedMissingEntitlementRevokesAndReconciles() async {
        let manager = ProManager(
            productLoader: { _ in [] },
            entitlementVerifier: { .notEntitled }
        )
        manager.isPro = true
        var reconciliationCount = 0
        manager.onFreeTierReconciliationNeeded = {
            reconciliationCount += 1
        }

        await manager.verifyEntitlement()

        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(reconciliationCount, 1)
        #if DEBUG
        XCTAssertFalse(manager.isTransactionListenerRunning)
        #endif
    }

    func testInjectedIndeterminateVerificationPreservesEntitlement() async {
        let manager = ProManager(
            productLoader: { _ in [] },
            entitlementVerifier: { .indeterminate }
        )
        manager.isPro = true

        await manager.verifyEntitlement()

        XCTAssertTrue(manager.isPro)
        #if DEBUG
        XCTAssertFalse(manager.isTransactionListenerRunning)
        #endif
    }

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

    func testIndeterminateEntitlementPreservesProStateWithoutReconciliation() async {
        let manager = ProManager(productLoader: { _ in [] })
        manager.isPro = true
        var reconciliationCount = 0
        manager.onFreeTierReconciliationNeeded = {
            reconciliationCount += 1
        }

        let generation = await manager.beginEntitlementVerification()
        await manager.reconcileEntitlementVerification(
            .indeterminate,
            generation: generation
        )

        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(reconciliationCount, 0)
    }

    func testStaleNegativeVerificationCannotOverrideNewerEntitlement() async {
        let manager = ProManager(productLoader: { _ in [] })
        manager.isPro = false
        var reconciliationCount = 0
        manager.onFreeTierReconciliationNeeded = {
            reconciliationCount += 1
        }

        let staleGeneration = await manager.beginEntitlementVerification()
        await manager.reconcileVerifiedEntitlement(true)
        await manager.reconcileEntitlementVerification(
            .notEntitled,
            generation: staleGeneration
        )

        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(reconciliationCount, 0)
    }

    func testNewerEntitlementCancelsInFlightFreeTierReconciliation() async {
        let manager = ProManager(productLoader: { _ in [] })
        manager.isPro = true
        let reconciliationStarted = expectation(description: "Free-tier reconciliation started")
        let reconciliationCancelled = expectation(description: "Free-tier reconciliation cancelled")
        manager.onFreeTierReconciliationNeeded = {
            reconciliationStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch is CancellationError {
                reconciliationCancelled.fulfill()
            } catch {
                XCTFail("Unexpected reconciliation error: \(error)")
            }
        }

        let staleReconciliation = Task {
            await manager.reconcileVerifiedEntitlement(false)
        }
        await fulfillment(of: [reconciliationStarted], timeout: 1)

        await manager.reconcileVerifiedEntitlement(true)
        await staleReconciliation.value
        await fulfillment(of: [reconciliationCancelled], timeout: 1)

        XCTAssertTrue(manager.isPro)
    }

    func testEntitlementInvalidationSuspendsWithoutBlockingMainActor() async throws {
        let permit = EntitlementReconciliationPermit()
        let releaseLease = DispatchSemaphore(value: 0)
        let leaseStartedExpectation = expectation(description: "Reconciliation lease started")
        let invalidationStarted = expectation(description: "Invalidation started")
        let mainActorProgressed = expectation(description: "Main actor remained responsive")
        var invalidationFinished = false

        let reconciliation = Task.detached {
            try permit.withValidLease {
                leaseStartedExpectation.fulfill()
                releaseLease.wait()
            }
        }
        await fulfillment(of: [leaseStartedExpectation], timeout: 2)

        let invalidation = Task { @MainActor in
            invalidationStarted.fulfill()
            await permit.invalidateAndWait()
            invalidationFinished = true
        }
        await fulfillment(of: [invalidationStarted], timeout: 2)
        Task { @MainActor in
            mainActorProgressed.fulfill()
        }
        await fulfillment(of: [mainActorProgressed], timeout: 2)

        XCTAssertFalse(invalidationFinished)
        XCTAssertFalse(permit.isValid)
        XCTAssertThrowsError(try permit.withValidLease {}) { error in
            XCTAssertTrue(error is CancellationError)
        }

        releaseLease.signal()
        try await reconciliation.value
        await invalidation.value

        XCTAssertTrue(invalidationFinished)
        XCTAssertFalse(permit.isValid)
    }

    func testRestorationWaitsForStaleNegativeLeaseBeforePublishing() async throws {
        let manager = ProManager(productLoader: { _ in [] })
        manager.isPro = true
        let leaseStarted = expectation(description: "Free-tier database lease started")
        let releaseLease = DispatchSemaphore(value: 0)
        let capturedPermit = OSAllocatedUnfairLock<EntitlementReconciliationPermit?>(
            initialState: nil
        )
        manager.onFreeTierReconciliationNeeded = {
            guard let permit = EntitlementReconciliationContext.permit else {
                XCTFail("Expected the reconciliation permit")
                return
            }
            capturedPermit.withLock { $0 = permit }
            do {
                try await Task.detached {
                    try permit.withValidLease {
                        leaseStarted.fulfill()
                        releaseLease.wait()
                    }
                }.value
            } catch is CancellationError {
                // A newer verified entitlement cancels the outer reconciliation,
                // but the acquired database lease is still allowed to finish.
            } catch {
                XCTFail("Unexpected reconciliation error: \(error)")
            }
        }

        let staleNegative = Task {
            await manager.reconcileVerifiedEntitlement(false)
        }
        await fulfillment(of: [leaseStarted], timeout: 2)
        XCTAssertFalse(manager.isPro)

        let firstRestorationStarted = expectation(description: "First restoration started")
        let secondRestorationStarted = expectation(description: "Second restoration started")
        var firstRestorationFinished = false
        var secondRestorationFinished = false
        let firstRestoration = Task {
            firstRestorationStarted.fulfill()
            await manager.reconcileVerifiedEntitlement(true)
            firstRestorationFinished = true
        }
        let secondRestoration = Task {
            secondRestorationStarted.fulfill()
            await manager.reconcileVerifiedEntitlement(true)
            secondRestorationFinished = true
        }
        await fulfillment(
            of: [firstRestorationStarted, secondRestorationStarted],
            timeout: 2
        )
        let invalidated = expectation(description: "Active lease invalidated")
        Task.detached {
            while capturedPermit.withLock({ $0?.isValid ?? true }) {
                await Task.yield()
            }
            invalidated.fulfill()
        }
        await fulfillment(of: [invalidated], timeout: 2)

        let mainActorProgressed = expectation(description: "Main actor progressed during restoration")
        Task { @MainActor in
            mainActorProgressed.fulfill()
        }
        await fulfillment(of: [mainActorProgressed], timeout: 2)
        XCTAssertFalse(manager.isPro, "Restoration must not publish before the stale lease completes")
        XCTAssertFalse(firstRestorationFinished)
        XCTAssertFalse(secondRestorationFinished)

        releaseLease.signal()
        await staleNegative.value
        await firstRestoration.value
        await secondRestoration.value

        XCTAssertTrue(manager.isPro, "The stale negative reconciliation must not win after restoration")
    }

    func testBelowCapReconciliationDoesNotReportLimitReached() {
        let result = FreeTierReconciliationResult(
            retainedMediaCount: 12,
            didTrimMedia: false
        )

        XCTAssertFalse(FreeTierStatePolicy.hitIndexLimit(
            previouslyHit: true,
            reconciliation: result
        ))
    }
}
