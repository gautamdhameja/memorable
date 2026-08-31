import Foundation
import StoreKit
import os

final class EntitlementReconciliationPermit: @unchecked Sendable {
    private struct State {
        var isValid = true
        var activeLeaseCount = 0
        var invalidationWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isValid: Bool {
        state.withLock { $0.isValid }
    }

    func invalidate() {
        state.withLock { $0.isValid = false }
    }

    /// Invalidates immediately, then suspends until every lease that had
    /// already started has completed. No thread is blocked while waiting.
    func invalidateAndWait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                state.isValid = false
                guard state.activeLeaseCount > 0 else { return true }
                state.invalidationWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    /// Runs one reconciliation as an ordered lease. The state lock is held only
    /// while acquiring and releasing the lease, never while the operation runs.
    /// Invalidation either prevents acquisition or asynchronously waits until
    /// the operation has committed.
    func withValidLease<T: Sendable>(
        _ operation: @Sendable () throws -> T
    ) throws -> T {
        let acquired = state.withLock { state in
            guard state.isValid else { return false }
            state.activeLeaseCount += 1
            return true
        }
        guard acquired else { throw CancellationError() }
        defer { releaseLease() }
        return try operation()
    }

    private func releaseLease() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            assert(state.activeLeaseCount > 0)
            guard state.activeLeaseCount > 0 else { return [] }
            state.activeLeaseCount -= 1
            guard state.activeLeaseCount == 0 else { return [] }
            defer { state.invalidationWaiters.removeAll(keepingCapacity: false) }
            return state.invalidationWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

enum EntitlementReconciliationContext {
    @TaskLocal static var permit: EntitlementReconciliationPermit?
}

enum FreeTier {
    static let maxIndexedMedia = 500

    static func canIndexMore(indexedMediaCount: Int, isPro: Bool) -> Bool {
        isPro || indexedMediaCount < maxIndexedMedia
    }
}

enum FreeTierStatePolicy {
    static func hitIndexLimit(
        previouslyHit: Bool,
        reconciliation: FreeTierReconciliationResult
    ) -> Bool {
        reconciliation.didTrimMedia || (
            previouslyHit && reconciliation.retainedMediaCount >= FreeTier.maxIndexedMedia
        )
    }
}

enum EntitlementVerificationResult {
    case entitled
    case notEntitled
    case indeterminate
}

struct ProRuntimePolicy: Equatable {
    let initiallyPro: Bool
    let performsEntitlementVerification: Bool
    let listensForTransactionUpdates: Bool

    #if DEBUG
    static let current = ProRuntimePolicy(
        initiallyPro: true,
        performsEntitlementVerification: false,
        listensForTransactionUpdates: false
    )
    #else
    static let current = ProRuntimePolicy(
        initiallyPro: false,
        performsEntitlementVerification: true,
        listensForTransactionUpdates: true
    )
    #endif
}

enum FolderResultAccessPolicy {
    static func allows(sourceId: String, isPro: Bool) -> Bool {
        sourceId == PhotoSourceType.photokit.rawValue || isPro
    }
}

enum FilteredResultSelectionPolicy {
    static func index(
        preserving currentResultID: String?,
        previousIndex: Int,
        remainingResultIDs: [String]
    ) -> Int {
        guard !remainingResultIDs.isEmpty else { return 0 }
        if let currentResultID,
           let retainedIndex = remainingResultIDs.firstIndex(of: currentResultID) {
            return retainedIndex
        }
        return min(max(0, previousIndex), remainingResultIDs.count - 1)
    }
}

@MainActor
class ProManager: ObservableObject {
    typealias ProductLoader = @MainActor ([String]) async throws -> [Product]
    typealias RetryDelay = @MainActor () async throws -> Void
    typealias EntitlementVerifier = @MainActor () async -> EntitlementVerificationResult

    static let shared = ProManager()

    static let productId = "com.blockdeep.memorable.pro.v2"
    static let legacyProductId = "com.blockdeep.memorable.pro"
    private static let entitlementProductIds: Set<String> = [productId, legacyProductId]
    private static let lastKnownEntitlementKey = "lastKnownVerifiedProEntitlement"

    static func isEntitlementProduct(_ productId: String) -> Bool {
        entitlementProductIds.contains(productId)
    }

    @Published var isPro: Bool
    @Published var product: Product?
    @Published var purchaseError: String?
    @Published var isRestoring: Bool = false
    @Published var restoreMessage: String?
    @Published var isLoadingProduct: Bool = false

    private var transactionListener: Task<Void, Never>?
    private var freeTierReconciliationTask: Task<Void, Never>?
    private var activeFreeTierReconciliationID: UUID?
    private var activeFreeTierReconciliationPermit: EntitlementReconciliationPermit?
    private var entitlementGeneration: UInt64 = 0
    private let productLoader: ProductLoader
    private let retryDelay: RetryDelay
    private let entitlementVerifier: EntitlementVerifier
    private let persistEntitlement: @MainActor (Bool) -> Void
    private let performsEntitlementVerification: Bool
    private let listensForTransactionUpdates: Bool

    #if DEBUG
    var isTransactionListenerRunning: Bool {
        transactionListener != nil
    }
    #endif

    /// Reconciles local Pro-only state whenever StoreKit verifies that the
    /// current account does not have an entitlement. The operation must be
    /// idempotent because it also runs on cold launch and after recovery.
    var onFreeTierReconciliationNeeded: (@MainActor () async -> Void)?

    private init() {
        let runtimePolicy = ProRuntimePolicy.current
        isPro = runtimePolicy.initiallyPro || UserDefaults.standard.bool(
            forKey: Self.lastKnownEntitlementKey
        )
        productLoader = { try await Product.products(for: $0) }
        retryDelay = { try await Task.sleep(nanoseconds: 2_000_000_000) }
        entitlementVerifier = { await Self.readCurrentEntitlement() }
        persistEntitlement = { entitled in
            UserDefaults.standard.set(entitled, forKey: Self.lastKnownEntitlementKey)
        }
        performsEntitlementVerification = runtimePolicy.performsEntitlementVerification
        listensForTransactionUpdates = runtimePolicy.listensForTransactionUpdates
    }

    /// Internal seam for deterministic lifecycle tests. Production always uses
    /// StoreKit through `shared`.
    init(
        productLoader: @escaping ProductLoader,
        retryDelay: @escaping RetryDelay = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        },
        entitlementVerifier: @escaping EntitlementVerifier = { .indeterminate },
        persistedEntitlement: Bool = false,
        persistEntitlement: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        isPro = persistedEntitlement
        self.productLoader = productLoader
        self.retryDelay = retryDelay
        self.entitlementVerifier = entitlementVerifier
        self.persistEntitlement = persistEntitlement
        performsEntitlementVerification = true
        listensForTransactionUpdates = false
    }

    // MARK: - Product

    func loadProduct() async {
        guard !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            var products = try await productLoader([Self.productId])
            if products.isEmpty {
                // StoreKit occasionally returns empty on a cold start or a
                // transient network blip. Give it one more chance before
                // surfacing a broken upgrade UI to the user (or reviewer).
                try await retryDelay()
                products = try await productLoader([Self.productId])
            }
            product = products.first
            #if DEBUG
            logger.info("[ProManager] Loaded \(products.count) products, match: \(products.first?.displayName ?? "nil")")
            #endif
        } catch {
            logger.error("Failed to load products: \(error.safeDiagnosticCode)")
        }
    }

    // MARK: - Purchase

    func purchase() async {
        if product == nil {
            // Product may have failed to load at launch (e.g. no network, or
            // StoreKit cold-start glitch). Retry once before failing.
            await loadProduct()
        }
        guard let product else {
            purchaseError = "Product not available. Try again later."
            return
        }
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await publishVerifiedEntitlement()
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            logger.error("Purchase failed: \(error.safeDiagnosticCode)")
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        isRestoring = true
        restoreMessage = nil
        purchaseError = nil

        do {
            try await AppStore.sync()
        } catch {
            logger.error("Restore failed: \(error.safeDiagnosticCode)")
            isRestoring = false
            purchaseError = "Restore failed: \(error.localizedDescription)"
            return
        }

        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                logger.error("Ignored an unverified restored entitlement")
                continue
            }
            if Self.isEntitlementProduct(transaction.productID) {
                await publishVerifiedEntitlement()
                found = true
                break
            }
        }

        isRestoring = false
        if found {
            restoreMessage = "Pro unlocked successfully!"
        } else {
            restoreMessage = "No previous purchase found."
        }
    }

    // MARK: - Entitlement Verification (handles refunds)

    /// Called on every launch to verify the user still has the entitlement.
    /// If they got a refund, isPro is revoked.
    func verifyEntitlement() async {
        if listensForTransactionUpdates {
            startListeningForTransactionsIfNeeded()
        }
        guard performsEntitlementVerification else { return }
        let generation = await beginEntitlementVerification()
        let verificationResult = await entitlementVerifier()

        await reconcileEntitlementVerification(
            verificationResult,
            generation: generation
        )
    }

    /// Reads StoreKit's current entitlement sequence without mutating local
    /// state. An unverified item makes the result indeterminate unless a valid
    /// current Memorable entitlement is also present.
    private static func readCurrentEntitlement() async -> EntitlementVerificationResult {
        var verificationResult = EntitlementVerificationResult.notEntitled
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                logger.error("Ignored an unverified current entitlement")
                verificationResult = .indeterminate
                continue
            }
            if Self.isEntitlementProduct(transaction.productID),
               transaction.revocationDate == nil {
                verificationResult = .entitled
                break
            }
        }
        return verificationResult
    }

    /// Applies a verified entitlement result. This is internal so lifecycle
    /// behavior can be tested without contacting StoreKit.
    func reconcileVerifiedEntitlement(_ entitled: Bool) async {
        let generation = await beginEntitlementVerification()
        await reconcileEntitlementVerification(
            entitled ? .entitled : .notEntitled,
            generation: generation
        )
    }

    /// Starts a new StoreKit observation. Any older observation or destructive
    /// reconciliation is stale as soon as a newer check begins.
    @discardableResult
    func beginEntitlementVerification() async -> UInt64 {
        entitlementGeneration &+= 1
        let generation = entitlementGeneration
        await invalidateFreeTierReconciliation()
        return generation
    }

    private func invalidateFreeTierReconciliation() async {
        let reconciliationID = activeFreeTierReconciliationID
        let permit = activeFreeTierReconciliationPermit
        let task = freeTierReconciliationTask
        permit?.invalidate()
        task?.cancel()
        await permit?.invalidateAndWait()

        guard activeFreeTierReconciliationID == reconciliationID,
              activeFreeTierReconciliationPermit === permit else { return }
        freeTierReconciliationTask = nil
        activeFreeTierReconciliationID = nil
        activeFreeTierReconciliationPermit = nil
    }

    /// Applies only the result of the most recent StoreKit observation.
    /// Indeterminate observations preserve local entitlement state because an
    /// unverifiable receipt is not evidence that the purchase is absent.
    func reconcileEntitlementVerification(
        _ result: EntitlementVerificationResult,
        generation: UInt64
    ) async {
        guard generation == entitlementGeneration else { return }

        switch result {
        case .entitled:
            publishEntitlementState(true)
            return
        case .indeterminate:
            logger.error("StoreKit entitlement status is indeterminate; preserving local Pro state")
            return
        case .notEntitled:
            break
        }

        let wasPro = isPro
        publishEntitlementState(false)
        if wasPro {
            logger.error("Pro entitlement revoked (refund or family sharing removed)")
        }

        guard let reconciliation = onFreeTierReconciliationNeeded else { return }
        let reconciliationID = UUID()
        let permit = EntitlementReconciliationPermit()
        let task = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  generation == self.entitlementGeneration,
                  permit.isValid else { return }
            await EntitlementReconciliationContext.$permit.withValue(permit) {
                await reconciliation()
            }
        }
        freeTierReconciliationTask = task
        activeFreeTierReconciliationID = reconciliationID
        activeFreeTierReconciliationPermit = permit
        await task.value
        if activeFreeTierReconciliationID == reconciliationID {
            permit.invalidate()
            freeTierReconciliationTask = nil
            activeFreeTierReconciliationID = nil
            activeFreeTierReconciliationPermit = nil
        }
    }

    // MARK: - Private

    private func publishVerifiedEntitlement() async {
        let generation = await beginEntitlementVerification()
        guard generation == entitlementGeneration else { return }
        publishEntitlementState(true)
    }

    private func publishEntitlementState(_ entitled: Bool) {
        persistEntitlement(entitled)
        isPro = entitled
    }

    private func startListeningForTransactionsIfNeeded() {
        guard transactionListener == nil else { return }
        transactionListener = listenForTransactions()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseError.unverified
        case .verified(let value):
            return value
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            let entitlementProductIds = await Self.entitlementProductIds
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    if entitlementProductIds.contains(transaction.productID) {
                        if transaction.revocationDate != nil {
                            await self.verifyEntitlement()
                        } else {
                            await self.reconcileVerifiedEntitlement(true)
                        }
                        await transaction.finish()
                    }
                case .unverified:
                    logger.error("Ignored an unverified StoreKit transaction update")
                }
            }
        }
    }

    enum PurchaseError: Error {
        case unverified
    }
}
