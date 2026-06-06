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

    func testInsertedBasePhotoDefaultsToNeedingEnrichment() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photo-1"))

        let candidates = try database.photosNeedingEnrichment(limit: 10)

        XCTAssertEqual(candidates.map(\.localIdentifier), ["photo-1"])
        XCTAssertEqual(candidates.map(\.sourceId), [PhotoSourceType.photokit.rawValue])
        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 1)
    }

    func testPhotoEnrichmentUpdateMarksRowCompleteEvenWithoutOcr() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "photo-1"))

        try database.updatePhotoEnrichment(PhotoEnrichmentUpdate(
            localIdentifier: "photo-1",
            ocrText: nil,
            sharpnessScore: 72,
            sceneLabels: nil
        ))

        XCTAssertEqual(try database.photosNeedingEnrichmentCount(), 0)
        XCTAssertTrue(try database.photosNeedingEnrichment(limit: 10).isEmpty)
    }

    func testFolderEnrichmentCandidateCarriesSourceIdAndFilePath() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(
            localIdentifier: "folder-image.jpg",
            sourceId: "folder-source-1",
            filePath: "/tmp/folder-image.jpg"
        ))

        let candidate = try XCTUnwrap(database.photosNeedingEnrichment(limit: 10).first)

        XCTAssertEqual(candidate.localIdentifier, "folder-image.jpg")
        XCTAssertEqual(candidate.sourceId, "folder-source-1")
        XCTAssertEqual(candidate.filePath, "/tmp/folder-image.jpg")
    }

    func testPhotoEnrichmentMigrationCreatesPendingLookupIndex() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )

        let indexNames = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(indexed_photos)")
                .map { $0["name"] as String }
        }

        XCTAssertTrue(indexNames.contains("idx_photos_enrichment_pending"))
    }

}

private enum StubMigrationError: Error {
    case failed
}

private func makePhoto(
    localIdentifier: String,
    sourceId: String = PhotoSourceType.photokit.rawValue,
    filePath: String? = nil
) -> IndexedPhoto {
    IndexedPhoto(
        id: UUID().uuidString,
        localIdentifier: localIdentifier,
        creationDate: Date(timeIntervalSince1970: 100),
        latitude: nil,
        longitude: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        embedding: floatVector(first: 1).toFloat16Data(),
        indexedAt: Date(timeIntervalSince1970: 200),
        sourceId: sourceId,
        filePath: filePath
    )
}
