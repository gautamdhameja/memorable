import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Index Maintenance

    /// Removes derived media index data while preserving user-selected folder
    /// sources and their security-scoped bookmarks for the subsequent rebuild.
    func resetIndexedMedia() throws {
        try dbQueue.write { db in
            try Self.markIndexRebuildRequired(in: db)
            _ = try IndexedPhoto.deleteAll(db)
            _ = try db.execute(sql: "DELETE FROM indexed_video_frames")
            _ = try IndexedVideo.deleteAll(db)
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = 0, lastIndexedAt = NULL"
            )
        }
    }

    func deletePhoto(localIdentifier: String) throws {
        try dbQueue.write { db in
            _ = try IndexedPhoto.filter(Column("localIdentifier") == localIdentifier).deleteAll(db)
        }
    }

    func photosNeedingEnrichment(limit: Int = IndexingConfig.enrichmentBatchSize) throws -> [PhotoEnrichmentCandidate] {
        try dbQueue.read { db in
            let retryBefore = Date().addingTimeInterval(-IndexingConfig.enrichmentRetryDelaySeconds)
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, pixelWidth, pixelHeight, sourceId, filePath FROM indexed_photos
                WHERE enrichmentComplete = 0
                  AND (enrichmentAttemptedAt IS NULL OR enrichmentAttemptedAt <= ?)
                ORDER BY creationDate DESC
                LIMIT ?
            """, arguments: [retryBefore, limit])
            return rows.map {
                PhotoEnrichmentCandidate(
                    localIdentifier: $0["localIdentifier"] as String,
                    pixelWidth: $0["pixelWidth"] as Int,
                    pixelHeight: $0["pixelHeight"] as Int,
                    sourceId: $0["sourceId"] as String,
                    filePath: $0["filePath"] as String?
                )
            }
        }
    }

    func photosNeedingEnrichmentCount() throws -> Int {
        try dbQueue.read { db in
            let retryBefore = Date().addingTimeInterval(-IndexingConfig.enrichmentRetryDelaySeconds)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_photos
                WHERE enrichmentComplete = 0
                  AND (enrichmentAttemptedAt IS NULL OR enrichmentAttemptedAt <= ?)
            """, arguments: [retryBefore]) ?? 0
        }
    }

    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws {
        guard !updates.isEmpty else { return }
        try dbQueue.write { db in
            for update in updates {
                switch update.outcome {
                case .completed:
                    try db.execute(
                        sql: """
                            UPDATE indexed_photos
                            SET ocrText = ?, sharpnessScore = ?, sceneLabels = ?,
                                isDocumentImage = ?,
                                enrichmentComplete = 1, enrichmentAttemptedAt = NULL
                            WHERE localIdentifier = ?
                        """,
                        arguments: [
                            PersistedMetadataTextPolicy.bounded(
                                update.ocrText,
                                maximumCharacters: PersistedMetadataTextPolicy.maximumOCRCharacters
                            ),
                            update.sharpnessScore,
                            PersistedMetadataTextPolicy.bounded(
                                update.sceneLabels,
                                maximumCharacters: PersistedMetadataTextPolicy.maximumSceneLabelCharacters
                            ),
                            update.isDocumentImage,
                            update.localIdentifier
                        ]
                    )
                case .loadFailed(let attemptedAt):
                    try db.execute(
                        sql: """
                            UPDATE indexed_photos
                            SET enrichmentAttemptedAt = ?
                            WHERE localIdentifier = ? AND enrichmentComplete = 0
                        """,
                        arguments: [attemptedAt, update.localIdentifier]
                    )
                }
            }
        }
    }

    // MARK: - Sources

    func insertSource(_ source: PhotoSource) throws {
        try requireIndexingWrites()
        try dbQueue.write { db in
            var source = source
            if source.type == PhotoSourceType.folder.rawValue {
                if let path = source.path {
                    source.path = PhotoSourcePolicy.canonicalPath(
                        URL(fileURLWithPath: path)
                    )
                }
                if let path = source.path {
                    let registeredPaths = try String.fetchAll(
                        db,
                        sql: "SELECT path FROM photo_sources WHERE type = ? AND path IS NOT NULL",
                        arguments: [PhotoSourceType.folder.rawValue]
                    )
                    guard !registeredPaths.contains(path) else {
                        throw PhotoSourceRegistrationError.duplicateFolder
                    }
                    guard !registeredPaths.contains(where: {
                        PhotoSourcePolicy.pathsOverlap($0, path)
                    }) else {
                        throw PhotoSourceRegistrationError.overlappingFolder
                    }
                }
                let folderCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM photo_sources WHERE type = ?",
                    arguments: [PhotoSourceType.folder.rawValue]
                ) ?? 0
                guard folderCount < PhotoSourcePolicy.maximumFolderSources else {
                    throw PhotoSourceRegistrationError.sourceLimitReached
                }
            }
            try source.insert(db)
        }
    }

    func listSources() throws -> [PhotoSource] {
        try dbQueue.read { db in
            try PhotoSource.filter(Column("type") == PhotoSourceType.folder.rawValue)
                .order(Column("addedAt").desc)
                .fetchAll(db)
        }
    }

    func deleteSource(_ id: String) throws {
        var deletionToken: FolderBookmarkStore.DeletionToken?
        try deleteSource(
            id,
            stageBookmark: {
                deletionToken = try FolderBookmarkStore.stageDeletion(for: id)
            },
            finalizeBookmark: {
                try FolderBookmarkStore.finalizeStagedDeletion(deletionToken)
            },
            restoreBookmark: {
                try FolderBookmarkStore.restoreStagedDeletion(deletionToken)
            }
        )
    }

    func deleteSource(
        _ id: String,
        stageBookmark: () throws -> Void,
        finalizeBookmark: () throws -> Void,
        restoreBookmark: () throws -> Void
    ) throws {
        do {
            try stageBookmark()
        } catch {
            logger.error("Failed to stage a folder bookmark for deletion: \(error.safeDiagnosticCode)")
            throw FolderSourceDeletionError.bookmarkCleanupFailed
        }

        do {
            try dbQueue.write { db in
                _ = try IndexedPhoto.filter(Column("sourceId") == id).deleteAll(db)
                _ = try PhotoSource.filter(Column("id") == id).deleteAll(db)
            }
        } catch {
            do {
                try restoreBookmark()
            } catch {
                logger.error("Failed to restore a staged folder bookmark after database deletion failed: \(error.safeDiagnosticCode)")
                throw FolderSourceDeletionError.bookmarkRestorationFailed
            }
            logger.error("Folder source database deletion rolled back: \(error.safeDiagnosticCode)")
            throw error
        }

        do {
            try finalizeBookmark()
        } catch {
            // The source is committed as deleted. A leftover staged file has no
            // live access path and can be removed by a later local cleanup.
            logger.error("Failed to finalize a staged folder bookmark deletion: \(error.safeDiagnosticCode)")
        }
    }

    @discardableResult
    func reconcileFolderSource(
        _ id: String,
        scannedFilePaths: Set<String>,
        scanWasComplete: Bool
    ) throws -> Int {
        try requireIndexingWrites()
        return try dbQueue.write { db in
            try Task.checkCancellation()
            if scanWasComplete {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, filePath FROM indexed_photos WHERE sourceId = ?",
                    arguments: [id]
                )
                let staleIDs = rows.compactMap { row -> String? in
                    let filePath: String? = row["filePath"]
                    guard let filePath, scannedFilePaths.contains(filePath) else {
                        return row["id"]
                    }
                    return nil
                }
                for chunk in staleIDs.chunked(into: 900) {
                    try Task.checkCancellation()
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM indexed_photos WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
            }
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM indexed_photos WHERE sourceId = ?",
                arguments: [id]
            ) ?? 0
            let lastIndexedAt: Date? = scanWasComplete ? Date() : nil
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = ?, lastIndexedAt = ? WHERE id = ?",
                arguments: [count, lastIndexedAt, id]
            )
            try Task.checkCancellation()
            return count
        }
    }

    // MARK: - Videos

    func isVideoIndexed(localIdentifier: String) throws -> Bool {
        try dbQueue.read { db in
            try IndexedVideo.filter(Column("localIdentifier") == localIdentifier).fetchCount(db) > 0
        }
    }

    func existingVideoIdentifiers(in localIdentifiers: [String]) throws -> Set<String> {
        try existingStrings(
            localIdentifiers,
            table: "indexed_videos",
            column: "localIdentifier"
        )
    }

    func videoIndexedCount() throws -> Int {
        try dbQueue.read { db in try IndexedVideo.fetchCount(db) }
    }

    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {
        guard !localIdentifiers.isEmpty else { return }
        let chunks = Array(localIdentifiers).chunked(into: 900)
        try dbQueue.write { db in
            for chunk in chunks {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(chunk)
                try db.execute(
                    sql: "DELETE FROM indexed_photos WHERE localIdentifier IN (\(placeholders))",
                    arguments: args
                )
            }
        }
    }

    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws {
        guard !localIdentifiers.isEmpty else { return }
        let chunks = Array(localIdentifiers).chunked(into: 900)
        try dbQueue.write { db in
            for chunk in chunks {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(chunk)
                try db.execute(
                    sql: "DELETE FROM indexed_video_frames WHERE videoId IN (SELECT id FROM indexed_videos WHERE localIdentifier IN (\(placeholders)))",
                    arguments: args
                )
                try db.execute(
                    sql: "DELETE FROM indexed_videos WHERE localIdentifier IN (\(placeholders))",
                    arguments: args
                )
            }
        }
    }

    @discardableResult
    func insertVideo(
        _ video: IndexedVideo,
        _ frames: [IndexedVideoFrame],
        completingRequiredRebuild: Bool
    ) throws -> Bool {
        let video = try Self.sanitizedVideo(video, frames: frames)
        try requireIndexingWrites()
        return try dbQueue.write { db in
            var completesRequiredRebuild = false
            if completingRequiredRebuild {
                completesRequiredRebuild = try Self.shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
                    in: db
                )
            }
            try video.insert(db)
            for frame in frames { try frame.insert(db) }
            if completesRequiredRebuild {
                try Self.clearIndexRebuildRequired(in: db)
            }
            return completesRequiredRebuild
        }
    }

    func replaceVideo(_ replacement: IndexedVideo, frames: [IndexedVideoFrame]) throws {
        try requireIndexingWrites()
        var video = try Self.sanitizedVideo(replacement, frames: frames)
        video.locationCity = nil
        video.locationState = nil
        video.locationCountry = nil
        video.locationName = nil
        try dbQueue.write { db in
            try Task.checkCancellation()
            guard let current = try IndexedVideo.fetchOne(db, key: video.id),
                  current.localIdentifier == video.localIdentifier,
                  current.sourceId == video.sourceId else {
                throw DatabaseCapabilityError.unavailable
            }
            try video.update(db)
            try db.execute(sql: "UPDATE indexed_videos SET locationRetryAfter = NULL WHERE id = ?",
                           arguments: [video.id])
            try db.execute(sql: "DELETE FROM indexed_video_frames WHERE videoId = ?",
                           arguments: [video.id])
            for frame in frames { try frame.insert(db) }
            try Task.checkCancellation()
        }
    }

    private static func sanitizedVideo(
        _ video: IndexedVideo, frames: [IndexedVideoFrame]
    ) throws -> IndexedVideo {
        guard (1...SearchIndexLimits.maximumVideoFramesPerMedia).contains(frames.count),
              frames.allSatisfy({
            $0.videoId == video.id
                && $0.framePosition.isFinite
                && (0...1).contains($0.framePosition)
                && $0.embedding.validatedFloat16Embedding() != nil
        }) else {
            throw SearchEngineError.corruptedIndex
        }
        var video = video
        video.frameCount = frames.count
        if !LocationCoordinatePolicy.isValidOrAbsent(
            latitude: video.latitude,
            longitude: video.longitude
        ) {
            video.latitude = nil
            video.longitude = nil
        }
        video.locationCity = PersistedMetadataTextPolicy.bounded(
            video.locationCity,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        video.locationState = PersistedMetadataTextPolicy.bounded(
            video.locationState,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        video.locationCountry = PersistedMetadataTextPolicy.bounded(
            video.locationCountry,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        video.locationName = PersistedMetadataTextPolicy.bounded(
            video.locationName,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        return video
    }

    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult {
        try reconcileFreeTier(limit, whilePermitted: { true })
    }

    func reconcileFreeTier(
        _ limit: Int,
        whilePermitted: @escaping @Sendable () -> Bool
    ) throws -> FreeTierReconciliationResult {
        try dbQueue.write { db in
            guard whilePermitted() else { throw CancellationError() }
            // Folder access is a Pro feature. Remove every non-PhotoKit row,
            // including rows whose source record is missing or malformed. Keep
            // source registrations and bookmarks so a later Pro entitlement
            // can resume without requiring the user to select folders again.
            try db.execute(
                sql: "DELETE FROM indexed_photos WHERE sourceId != ?",
                arguments: [PhotoSourceType.photokit.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM indexed_video_frames WHERE videoId IN (SELECT id FROM indexed_videos WHERE sourceId != ?)",
                arguments: [PhotoSourceType.photokit.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM indexed_videos WHERE sourceId != ?",
                arguments: [PhotoSourceType.photokit.rawValue]
            )
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = 0, lastIndexedAt = NULL WHERE type = ? OR id != ?",
                arguments: [PhotoSourceType.folder.rawValue, PhotoSourceType.photokit.rawValue]
            )

            let didTrim = try Self.trimMedia(in: db, to: limit)
            let retainedCount = try IndexedPhoto.fetchCount(db) + IndexedVideo.fetchCount(db)
            guard whilePermitted() else { throw CancellationError() }
            return FreeTierReconciliationResult(
                retainedMediaCount: retainedCount,
                didTrimMedia: didTrim
            )
        }
    }

    private static func trimMedia(in db: Database, to limit: Int) throws -> Bool {
            let safeLimit = max(0, limit)
            let photoCount = try IndexedPhoto.fetchCount(db)
            let videoCount = try IndexedVideo.fetchCount(db)
            let totalCount = photoCount + videoCount

            guard totalCount > safeLimit else { return false }

            // Proportional allocation: each type keeps its share of the limit
            let photoLimit: Int
            let videoLimit: Int
            if photoCount == 0 {
                photoLimit = 0
                videoLimit = safeLimit
            } else if videoCount == 0 {
                photoLimit = safeLimit
                videoLimit = 0
            } else {
                photoLimit = max(Int(Double(photoCount) / Double(totalCount) * Double(safeLimit)), 1)
                videoLimit = max(safeLimit - photoLimit, 1)
            }

            // Trim photos
            if photoCount > photoLimit {
                try db.execute(sql: """
                    DELETE FROM indexed_photos WHERE id NOT IN (
                        SELECT id FROM indexed_photos ORDER BY indexedAt DESC LIMIT ?
                    )
                """, arguments: [photoLimit])
            }

            // Trim videos (delete frames first due to foreign key)
            if videoCount > videoLimit {
                try db.execute(sql: """
                    DELETE FROM indexed_video_frames WHERE videoId IN (
                        SELECT id FROM indexed_videos WHERE id NOT IN (
                            SELECT id FROM indexed_videos ORDER BY indexedAt DESC LIMIT ?
                        )
                    )
                """, arguments: [videoLimit])
                try db.execute(sql: """
                    DELETE FROM indexed_videos WHERE id NOT IN (
                        SELECT id FROM indexed_videos ORDER BY indexedAt DESC LIMIT ?
                    )
                """, arguments: [videoLimit])
            }
            return true
    }
}
