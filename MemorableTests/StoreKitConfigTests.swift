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
}
