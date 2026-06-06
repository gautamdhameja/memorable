import XCTest
import GRDB
@testable import Memorable

final class DatabaseTests: XCTestCase {

    override func tearDown() {
        AppDatabase.isInMemoryFallback = false
        super.tearDown()
    }

    func testSuccessfulInMemoryMigrationDoesNotMarkFallback() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        XCTAssertFalse(AppDatabase.isInMemoryFallback)
        XCTAssertEqual(try database.indexedCount(), 0)
        XCTAssertEqual(try database.videoIndexedCount(), 0)
    }

    func testMigrationFailureUsesInMemoryFallbackState() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { _ in throw StubMigrationError.failed }
        )

        XCTAssertTrue(AppDatabase.isInMemoryFallback)
        XCTAssertNotNil(database.dbQueue)
    }
}

private enum StubMigrationError: Error {
    case failed
}
