import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Photos

    func insertPhoto(_ photo: IndexedPhoto) throws {
        try requireIndexingWrites()
        try dbQueue.write { db in
            try Self.sanitizedForPersistence(photo).insert(db)
        }
    }

    @discardableResult
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool {
        guard !photos.isEmpty else { return false }
        try requireIndexingWrites()
        return try dbQueue.write { db in
            var completesRequiredRebuild = false
            if completingRequiredRebuild {
                completesRequiredRebuild = try Self.shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
                    in: db
                )
            }
            for photo in photos {
                try Self.sanitizedForPersistence(photo).insert(db, onConflict: .ignore)
            }
            if completesRequiredRebuild {
                try Self.clearIndexRebuildRequired(in: db)
            }
            return completesRequiredRebuild
        }
    }

    private static func sanitizedForPersistence(_ photo: IndexedPhoto) throws -> IndexedPhoto {
        var photo = photo
        guard photo.embedding.validatedFloat16Embedding() != nil else {
            throw SearchEngineError.invalidEmbedding
        }
        if !LocationCoordinatePolicy.isValidOrAbsent(
            latitude: photo.latitude,
            longitude: photo.longitude
        ) {
            photo.latitude = nil
            photo.longitude = nil
        }
        photo.ocrText = PersistedMetadataTextPolicy.bounded(
            photo.ocrText,
            maximumCharacters: PersistedMetadataTextPolicy.maximumOCRCharacters
        )
        photo.sceneLabels = PersistedMetadataTextPolicy.bounded(
            photo.sceneLabels,
            maximumCharacters: PersistedMetadataTextPolicy.maximumSceneLabelCharacters
        )
        photo.locationCity = PersistedMetadataTextPolicy.bounded(
            photo.locationCity,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        photo.locationState = PersistedMetadataTextPolicy.bounded(
            photo.locationState,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        photo.locationCountry = PersistedMetadataTextPolicy.bounded(
            photo.locationCountry,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        photo.locationName = PersistedMetadataTextPolicy.bounded(
            photo.locationName,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        return photo
    }

    func isIndexed(localIdentifier: String) throws -> Bool {
        try dbQueue.read { db in
            try IndexedPhoto.filter(Column("localIdentifier") == localIdentifier).fetchCount(db) > 0
        }
    }

    func existingPhotoIdentifiers(in localIdentifiers: [String]) throws -> Set<String> {
        try existingStrings(
            localIdentifiers,
            table: "indexed_photos",
            column: "localIdentifier"
        )
    }

    func markPhotoScreenshots(localIdentifiers: Set<String>) throws {
        guard !localIdentifiers.isEmpty else { return }
        try dbQueue.write { db in
            for chunk in Array(localIdentifiers).chunked(into: 900) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: """
                        UPDATE indexed_photos
                        SET isScreenshot = 1
                        WHERE localIdentifier IN (\(placeholders))
                    """,
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    func existingFilePaths(in filePaths: [String], sourceId: String) throws -> Set<String> {
        guard !filePaths.isEmpty else { return [] }
        var matches: Set<String> = []
        try dbQueue.read { db in
            for chunk in filePaths.chunked(into: 899) {
                try Task.checkCancellation()
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try String.fetchAll(
                    db,
                    sql: """
                        SELECT filePath FROM indexed_photos
                        WHERE sourceId = ? AND filePath IN (\(placeholders))
                    """,
                    arguments: StatementArguments([sourceId] + chunk)
                )
                matches.formUnion(rows)
            }
        }
        return matches
    }

    func existingStrings(
        _ values: [String],
        table: String,
        column: String
    ) throws -> Set<String> {
        guard !values.isEmpty else { return [] }
        var matches: Set<String> = []
        try dbQueue.read { db in
            for chunk in values.chunked(into: 900) {
                try Task.checkCancellation()
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                matches.formUnion(rows)
            }
        }
        return matches
    }

    func indexedCount() throws -> Int {
        try dbQueue.read { db in
            try IndexedPhoto.fetchCount(db)
        }
    }

    func hasIndexedPhotos() throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM indexed_photos LIMIT 1)"
            ) ?? false
        }
    }

    func indexedMediaCounts() throws -> IndexedMediaCounts {
        try dbQueue.read { db in
            IndexedMediaCounts(
                photos: try IndexedPhoto.fetchCount(db),
                videos: try IndexedVideo.fetchCount(db)
            )
        }
    }

    func photoLibraryIndexedMediaCounts() throws -> IndexedMediaCounts {
        try dbQueue.read { db in
            IndexedMediaCounts(
                photos: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM indexed_photos WHERE sourceId = ?",
                    arguments: [PhotoSourceType.photokit.rawValue]
                ) ?? 0,
                videos: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM indexed_videos WHERE sourceId = ?",
                    arguments: [PhotoSourceType.photokit.rawValue]
                ) ?? 0
            )
        }
    }
}
