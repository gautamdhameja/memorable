import Foundation
import StoreKit

enum FreeTier {
    static let maxPhotos = 200
}

@MainActor
class ProManager: ObservableObject {
    static let shared = ProManager()

    static let productId = "com.blockdeep.memorable.pro"

    #if DEBUG
    @Published var isPro: Bool = true
    #else
    @Published var isPro: Bool = false
    #endif
    @Published var product: Product?
    @Published var purchaseError: String?
    @Published var isRestoring: Bool = false
    @Published var restoreMessage: String?

    private var transactionListener: Task<Void, Never>?

    private init() {
        transactionListener = listenForTransactions()
        Task { await loadProduct() }
        Task { await verifyEntitlement() }
    }

    // MARK: - Product

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productId])
            product = products.first
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    func purchase() async {
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
                logger.warning("Pro entitlement revoked (refund or family sharing removed)")
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
        Task.detached {
            let productId = await Self.productId
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    if transaction.productID == productId {
                        if transaction.revocationDate != nil {
                            await MainActor.run { self.isPro = false }
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
