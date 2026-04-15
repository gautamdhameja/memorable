import Foundation
import StoreKit

enum FreeTier {
    static let maxPhotos = 500
}

@MainActor
class ProManager: ObservableObject {
    static let shared = ProManager()

    static let productId = "com.blockdeep.memorable.pro.v2"

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

    /// Called when Pro is revoked (refund). Set by AppState to trim index.
    var onProRevoked: (() -> Void)?

    private init() {
        transactionListener = listenForTransactions()
        Task { await self.loadProduct() }
        Task { await self.verifyEntitlement() }
    }

    // MARK: - Product

    func loadProduct() async {
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            var products = try await Product.products(for: [Self.productId])
            if products.isEmpty {
                // StoreKit occasionally returns empty on a cold start or a
                // transient network blip. Give it one more chance before
                // surfacing a broken upgrade UI to the user (or reviewer).
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                products = (try? await Product.products(for: [Self.productId])) ?? []
            }
            product = products.first
            #if DEBUG
            logger.info("[ProManager] Loaded \(products.count) products, match: \(products.first?.displayName ?? "nil")")
            #endif
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
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
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        isRestoring = true
        restoreMessage = nil
        purchaseError = nil

        var found = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == Self.productId {
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
        #if !DEBUG
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == Self.productId,
               transaction.revocationDate == nil {
                entitled = true
                break
            }
        }

        if entitled != isPro {
            isPro = entitled
            if !entitled {
                logger.error("Pro entitlement revoked (refund or family sharing removed)")
                onProRevoked?()
            }
        }
        #endif
    }

    // MARK: - Private

    private func unlock() {
        isPro = true
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
        // Strong [self] capture is safe and correct here: ProManager is a
        // singleton with an infinite Transaction.updates loop, and is
        // @MainActor-isolated (implicitly Sendable in Swift 6). Explicit
        // capture silences strict-concurrency diagnostics about mutable
        // self crossing a @Sendable detached-task boundary.
        Task.detached { [self] in
            let productId = await Self.productId
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    if transaction.productID == productId {
                        if transaction.revocationDate != nil {
                            await MainActor.run {
                                self.isPro = false
                                self.onProRevoked?()
                            }
                        } else {
                            await MainActor.run { self.unlock() }
                        }
                        await transaction.finish()
                    }
                case .unverified:
                    break
                }
            }
        }
    }

    enum PurchaseError: Error {
        case unverified
    }
}
