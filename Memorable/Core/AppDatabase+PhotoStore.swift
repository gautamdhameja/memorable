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

    func indexedPhotoVersions(in localIdentifiers: [String]) throws -> [String: IndexedMediaVersion] {
        try indexedMediaVersions(localIdentifiers, table: "indexed_photos", column: "localIdentifier")
    }

    func indexedVideoVersions(in localIdentifiers: [String]) throws -> [String: IndexedMediaVersion] {
        try indexedMediaVersions(localIdentifiers, table: "indexed_videos", column: "localIdentifier")
    }

    func indexedFolderVersions(in filePaths: [String], sourceId: String) throws -> [String: IndexedMediaVersion] {
        try indexedMediaVersions(filePaths, table: "indexed_photos", column: "filePath", sourceId: sourceId)
    }

    private func indexedMediaVersions(
        _ values: [String], table: String, column: String, sourceId: String? = nil
    ) throws -> [String: IndexedMediaVersion] {
        guard !values.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var versions: [String: IndexedMediaVersion] = [:]
            for chunk in values.chunked(into: 899) {
                try Task.checkCancellation()
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sourceClause = sourceId == nil ? "" : " AND sourceId = ?"
                let arguments = chunk + (sourceId.map { [$0] } ?? [])
                for row in try Row.fetchAll(db, sql: """
                    SELECT id, \(column) AS sourceKey, indexedAt FROM \(table)
                    WHERE \(column) IN (\(placeholders))\(sourceClause)
                    """, arguments: StatementArguments(arguments)) {
                    versions[row["sourceKey"] as String] = IndexedMediaVersion(
                        id: row["id"], indexedAt: row["indexedAt"]
                    )
                }
            }
            return versions
        }
    }

    /// A refresh cannot insert a row removed by another operation. Keep the
    /// stable identity and reset every derived value in the same transaction.
    func replacePhoto(_ replacement: IndexedPhoto) throws {
        try requireIndexingWrites()
        var photo = try Self.sanitizedForPersistence(replacement)
        photo.ocrText = nil
        photo.sharpnessScore = nil
        photo.sceneLabels = nil
        photo.isDocumentImage = false
        photo.enrichmentComplete = false
        photo.locationCity = nil
        photo.locationState = nil
        photo.locationCountry = nil
        photo.locationName = nil
        try dbQueue.write { db in
            try Task.checkCancellation()
            guard let current = try IndexedPhoto.fetchOne(db, key: photo.id),
                  current.localIdentifier == photo.localIdentifier,
                  current.sourceId == photo.sourceId else {
                throw DatabaseCapabilityError.unavailable
            }
            try photo.update(db)
            try db.execute(sql: """
                UPDATE indexed_photos SET enrichmentAttemptedAt = NULL, locationRetryAfter = NULL
                WHERE id = ?
                """, arguments: [photo.id])
            try Task.checkCancellation()
        }
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

    func searchIndexContentRevision() throws -> SearchIndexContentRevision {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM indexed_photos) AS photoCount,
                        (SELECT COUNT(*) FROM indexed_videos) AS videoCount,
                        (SELECT COUNT(*) FROM indexed_video_frames) AS videoFrameCount,
                        (SELECT COALESCE(MAX(rowid), 0) FROM indexed_photos) AS latestPhotoRowID,
                        (SELECT COALESCE(MAX(rowid), 0) FROM indexed_videos) AS latestVideoRowID,
                        (SELECT COALESCE(MAX(rowid), 0) FROM indexed_video_frames) AS latestVideoFrameRowID,
                        (SELECT id FROM indexed_photos ORDER BY rowid DESC LIMIT 1) AS latestPhotoID,
                        (SELECT id FROM indexed_videos ORDER BY rowid DESC LIMIT 1) AS latestVideoID,
                        (SELECT id FROM indexed_video_frames ORDER BY rowid DESC LIMIT 1) AS latestVideoFrameID,
                        (SELECT MAX(indexedAt) FROM indexed_photos) AS latestPhotoIndexedAt,
                        (SELECT MAX(indexedAt) FROM indexed_videos) AS latestVideoIndexedAt,
                        (SELECT MAX(indexedAt) FROM indexed_video_frames) AS latestVideoFrameIndexedAt
                """
            ) else {
                throw DatabaseCapabilityError.unavailable
            }
            return SearchIndexContentRevision(
                photoCount: row["photoCount"],
                videoCount: row["videoCount"],
                videoFrameCount: row["videoFrameCount"],
                latestPhotoRowID: row["latestPhotoRowID"],
                latestVideoRowID: row["latestVideoRowID"],
                latestVideoFrameRowID: row["latestVideoFrameRowID"],
                latestPhotoID: row["latestPhotoID"],
                latestVideoID: row["latestVideoID"],
                latestVideoFrameID: row["latestVideoFrameID"],
                latestPhotoIndexedAt: row["latestPhotoIndexedAt"],
                latestVideoIndexedAt: row["latestVideoIndexedAt"],
                latestVideoFrameIndexedAt: row["latestVideoFrameIndexedAt"]
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
