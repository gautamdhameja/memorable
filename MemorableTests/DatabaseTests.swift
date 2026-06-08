import XCTest
import GRDB
@testable import Memorable

final class DatabaseTests: XCTestCase {

    override func tearDown() {
        AppDatabase.isInMemoryFallback = false
        UserDefaults.standard.removeObject(forKey: IndexingConfig.needsFastFormatPhotoRebuildKey)
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

    func testDeletePhotoRemovesOnlyMatchingIdentifier() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        try database.insertPhoto(makePhoto(localIdentifier: "delete-me"))
        try database.insertPhoto(makePhoto(localIdentifier: "keep-me"))

        try database.deletePhoto(localIdentifier: "delete-me")

        XCTAssertFalse(try database.isIndexed(localIdentifier: "delete-me"))
        XCTAssertTrue(try database.isIndexed(localIdentifier: "keep-me"))
        XCTAssertEqual(try database.indexedCount(), 1)
    }

    func testDeleteSourceRemovesPersistedBookmark() throws {
        let database = AppDatabase(
            openQueue: { try DatabaseQueue() },
            migrate: { try AppDatabase.migrator.migrate($0) }
        )
        let sourceId = "folder-source-delete"
        UserDefaults.standard.set(Data([1, 2, 3]), forKey: AppKeys.folderBookmark(sourceId: sourceId))
        try database.insertSource(PhotoSource(
            id: sourceId,
            type: PhotoSourceType.folder.rawValue,
            path: "/tmp/folder",
            name: "Folder",
            addedAt: Date(timeIntervalSince1970: 100),
            lastIndexedAt: nil,
            photoCount: 0
        ))

        try database.deleteSource(sourceId)

        XCTAssertNil(UserDefaults.standard.data(forKey: AppKeys.folderBookmark(sourceId: sourceId)))
    }

    func testFolderLocalIdentifierUsesSourceAndRelativePath() {
        let folderA = URL(fileURLWithPath: "/tmp/a")
        let folderB = URL(fileURLWithPath: "/tmp/b")
        let first = FolderScanner.localIdentifier(
            for: URL(fileURLWithPath: "/tmp/a/nested/IMG_0001.JPG"),
            within: folderA,
            sourceId: "source-a"
        )
        let second = FolderScanner.localIdentifier(
            for: URL(fileURLWithPath: "/tmp/b/nested/IMG_0001.JPG"),
            within: folderB,
            sourceId: "source-b"
        )
        let sibling = FolderScanner.localIdentifier(
            for: URL(fileURLWithPath: "/tmp/a/other/IMG_0001.JPG"),
            within: folderA,
            sourceId: "source-a"
        )

        XCTAssertEqual(first, "folder:source-a:nested/IMG_0001.JPG")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, sibling)
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
