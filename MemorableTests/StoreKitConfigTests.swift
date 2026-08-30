import XCTest
@testable import Memorable

@MainActor
final class StoreKitConfigTests: XCTestCase {

    func testStoreKitConfigContainsConfiguredProProduct() throws {
        let config = try loadStoreKitConfig()
        let products = config.products.filter { $0.productID == ProManager.productId }

        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products[0].internalID, ProManager.productId)
        XCTAssertEqual(products[0].type, "NonConsumable")
        XCTAssertTrue(products[0].familyShareable)
        let descriptions = products[0].localizations.map(\.description)
        XCTAssertFalse(descriptions.contains { $0.contains("8,000") })
        XCTAssertTrue(descriptions.contains {
            $0.localizedCaseInsensitiveContains("locally available")
                && $0.localizedCaseInsensitiveContains("photos and videos")
        })
    }

    func testCurrentAndLegacyProductIdentifiersGrantProEntitlement() {
        XCTAssertTrue(ProManager.isEntitlementProduct(ProManager.productId))
        XCTAssertTrue(ProManager.isEntitlementProduct("com.blockdeep.memorable.pro"))
        XCTAssertFalse(ProManager.isEntitlementProduct("com.blockdeep.memorable.unrelated"))
    }

    private func loadStoreKitConfig() throws -> StoreKitConfig {
        let testURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testURL.deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Memorable/Store/MemorableProducts.storekit")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StoreKitConfig.self, from: data)
    }
}

private struct StoreKitConfig: Decodable {
    let products: [StoreKitProduct]
}

private struct StoreKitProduct: Decodable {
    let internalID: String
    let productID: String
    let type: String
    let familyShareable: Bool
    let localizations: [StoreKitLocalization]
}

private struct StoreKitLocalization: Decodable {
    let description: String
}
