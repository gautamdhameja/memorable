import Foundation
import StoreKit

enum FreeTier {
    static let maxIndexedMedia = 500

    static func indexLimit(isPro: Bool) -> Int {
        isPro ? ProTier.maxIndexedMedia : maxIndexedMedia
    }

    static func canIndexMore(indexedMediaCount: Int, isPro: Bool) -> Bool {
        indexedMediaCount < indexLimit(isPro: isPro)
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

/// Keeps the resident semantic index within a predictable memory envelope on
/// supported devices. Videos can contribute up to five frame embeddings each.
enum ProTier {
    static let maxIndexedMedia = SearchIndexLimits.maximumMediaItems
}

@MainActor
class ProManager: ObservableObject {
    typealias ProductLoader = @MainActor ([String]) async throws -> [Product]
    typealias RetryDelay = @MainActor () async throws -> Void

    static let shared = ProManager()

    static let productId = "com.blockdeep.memorable.pro.v2"
    static let legacyProductId = "com.blockdeep.memorable.pro"
    private static let entitlementProductIds: Set<String> = [productId, legacyProductId]

    static func isEntitlementProduct(_ productId: String) -> Bool {
        entitlementProductIds.contains(productId)
    }

    #if DEBUG
    @Published var isPro: Bool = true
    #else
    @Published var isPro: Bool = false
    #endif
    @Published var product: Product?
    @Published var purchaseError: String?
    @Published var isRestoring: Bool = false
    @Published var restoreMessage: String?
    @Published var isLoadingProduct: Bool = false

    private var transactionListener: Task<Void, Never>?
    private let productLoader: ProductLoader
    private let retryDelay: RetryDelay

    /// Reconciles local Pro-only state whenever StoreKit verifies that the
    /// current account does not have an entitlement. The operation must be
    /// idempotent because it also runs on cold launch and after recovery.
    var onFreeTierReconciliationNeeded: (@MainActor () async -> Void)?

    private init() {
        productLoader = { try await Product.products(for: $0) }
        retryDelay = { try await Task.sleep(nanoseconds: 2_000_000_000) }
    }

    /// Internal seam for deterministic lifecycle tests. Production always uses
    /// StoreKit through `shared`.
    init(
        productLoader: @escaping ProductLoader,
        retryDelay: @escaping RetryDelay = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    ) {
        self.productLoader = productLoader
        self.retryDelay = retryDelay
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
                unlock()
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
                unlock()
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
        startListeningForTransactionsIfNeeded()
        #if !DEBUG
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                logger.error("Ignored an unverified current entitlement")
                continue
            }
            if Self.isEntitlementProduct(transaction.productID),
               transaction.revocationDate == nil {
                entitled = true
                break
            }
        }

        await reconcileVerifiedEntitlement(entitled)
        #endif
    }

    /// Applies a verified entitlement result. This is internal so lifecycle
    /// behavior can be tested without contacting StoreKit.
    func reconcileVerifiedEntitlement(_ entitled: Bool) async {
        let wasPro = isPro
        isPro = entitled
        guard !entitled else { return }
        if wasPro {
            logger.error("Pro entitlement revoked (refund or family sharing removed)")
        }
        await onFreeTierReconciliationNeeded?()
    }

    // MARK: - Private

    private func unlock() {
        isPro = true
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
                            await MainActor.run { self.unlock() }
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
