import Foundation
import GRDB

// MARK: - Embedding Index

struct EmbeddingIndex {
    var ids: [String]
    var localIdentifiers: [String]
    var dates: [Date?]
    var latitudes: [Double?]
    var longitudes: [Double?]
    var ocrTexts: [String?]
    var locationCities: [String?]
    var locationStates: [String?]
    var locationCountries: [String?]
    var locationNames: [String?]
    var sceneLabels: [String?]
    var embeddings: [Float16]
}

typealias VideoEmbeddingIndex = (videoIds: [String], localIdentifiers: [String], dates: [Date?], latitudes: [Double?], longitudes: [Double?], framePositions: [Double], locationCities: [String?], locationStates: [String?], locationCountries: [String?], locationNames: [String?], embeddings: [Float16])

// MARK: - Database Protocol

protocol DatabaseProtocol {
    // Photos
    func insertPhoto(_ photo: IndexedPhoto) throws
    /// Returns true when the write atomically completes a pending required rebuild.
    @discardableResult
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool
    func isIndexed(localIdentifier: String) throws -> Bool
    func allIndexedIdentifiers() throws -> Set<String>
    func allIndexedFilePaths() throws -> Set<String>
    func indexedCount() throws -> Int
    func loadAllEmbeddings() throws -> EmbeddingIndex
    func deleteAll() throws
    func deletePhoto(localIdentifier: String) throws
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws
    func fetchRandomPhoto(sharp: Bool) throws -> IndexedPhoto?
    func photosNeedingEnrichment(limit: Int) throws -> [PhotoEnrichmentCandidate]
    func photosNeedingEnrichmentCount() throws -> Int
    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws
    func indexRebuildRequired() throws -> Bool
    func clearIndexRebuildRequired() throws

    // Videos
    /// Persists video metadata and frames together. Returns true when the write
    /// atomically completes a pending required rebuild.
    @discardableResult
    func insertVideo(
        _ video: IndexedVideo,
        _ frames: [IndexedVideoFrame],
        completingRequiredRebuild: Bool
    ) throws -> Bool
    func isVideoIndexed(localIdentifier: String) throws -> Bool
    func videoIndexedCount() throws -> Int
    func allIndexedVideoIdentifiers() throws -> Set<String>
    func loadAllVideoEmbeddings() throws -> VideoEmbeddingIndex
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws
    func trimToLimit(_ limit: Int) throws

    // Location backfill
    func photosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)]
    func videosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)]
    func photosNeedingLocationBackfillCount() throws -> Int
    func videosNeedingLocationBackfillCount() throws -> Int
    func photosWithGPSCount() throws -> Int
    func videosWithGPSCount() throws -> Int
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws

    // Sources
    func insertSource(_ source: PhotoSource) throws
    func listSources() throws -> [PhotoSource]
    func deleteSource(_ id: String) throws
    func updateSourceStats(_ id: String, photoCount: Int) throws

    // Queries
    func onThisDayPhotos() throws -> [(year: Int, ids: [String])]

    // Search History
    func addSearchHistory(_ query: String) throws
    func loadSearchHistory() throws -> [String]
    func clearSearchHistory() throws
    func removeSearchHistory(at index: Int) throws

    // Smart Albums
    func loadSmartAlbums() throws -> [SmartAlbum]
    func saveSmartAlbum(_ album: SmartAlbum) throws
    func deleteSmartAlbum(id: String) throws
}

// MARK: - AppDatabase

class AppDatabase: DatabaseProtocol {
    static let shared = AppDatabase()
    static var isInMemoryFallback: Bool = false
    private static let orientationMigrationID = "v3-orientation-normalized-embeddings"
    private static let indexRebuildStateKey = "indexRebuildRequired"
    private static let embeddingFormatStateKey = "embeddingFormatVersion"
    private static let currentEmbeddingFormatVersion = "orientation-correct-v1"
    private static let legacyFastFormatRebuildKey = "indexing.needsFastFormatPhotoRebuild"
    let dbQueue: DatabaseQueue

    private init() {
        dbQueue = Self.openMigratedDatabase(
            openQueue: Self.openOnDiskDatabase,
            migrate: { try Self.migrator.migrate($0) }
        )
    }

    init(openQueue: () throws -> DatabaseQueue, migrate: (DatabaseQueue) throws -> Void) {
        dbQueue = Self.openMigratedDatabase(openQueue: openQueue, migrate: migrate)
    }

    private static func openMigratedDatabase(
        openQueue: () throws -> DatabaseQueue,
        migrate: (DatabaseQueue) throws -> Void
    ) -> DatabaseQueue {
        Self.isInMemoryFallback = false
        do {
            let queue = try openQueue()
            let orientationMigrationWasAlreadyApplied = try queue.read { db in
                try Self.migrator.appliedMigrations(db).contains(Self.orientationMigrationID)
            }
            try migrate(queue)
            try finalizeEmbeddingFormatState(
                in: queue,
                orientationMigrationWasAlreadyApplied: orientationMigrationWasAlreadyApplied
            )
            #if DEBUG
            logger.info("[Database] Migrations completed successfully")
            #endif
            return queue
        } catch {
            logger.error("Database init or migration failed, using in-memory fallback: \(error.localizedDescription)")
            return inMemoryFallbackQueue(migrate: migrate)
        }
    }

    private static func openOnDiskDatabase() throws -> DatabaseQueue {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DatabaseInitError.applicationSupportUnavailable
        }

        let dbDir = appSupport.appendingPathComponent("Memorable", isDirectory: true)
        try fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try setCompleteUnlessOpenProtection(at: dbDir)

        let dbURL = dbDir.appendingPathComponent("photos.sqlite")
        let dbPath = dbURL.path

        let config = Configuration()
        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        try protectSQLiteFiles(for: dbURL)

        return queue
    }

    private static func protectSQLiteFiles(for dbURL: URL) throws {
        try setCompleteUnlessOpenProtection(at: dbURL)
        try setCompleteUnlessOpenProtection(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try setCompleteUnlessOpenProtection(at: URL(fileURLWithPath: dbURL.path + "-shm"))
    }

    private static func setCompleteUnlessOpenProtection(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
    }

    private static func inMemoryFallbackQueue(migrate: (DatabaseQueue) throws -> Void) -> DatabaseQueue {
        Self.isInMemoryFallback = true
        do {
            let queue = try DatabaseQueue()
            try migrate(queue)
            return queue
        } catch {
            logger.error("In-memory database migration failed: \(error.localizedDescription)")
            // Intentional force-try: in-memory DatabaseQueue allocation virtually never fails
            return try! DatabaseQueue()
        }
    }

    private static func finalizeEmbeddingFormatState(
        in queue: DatabaseQueue,
        orientationMigrationWasAlreadyApplied: Bool
    ) throws {
        let legacyRebuildRequired = UserDefaults.standard.bool(forKey: legacyFastFormatRebuildKey)
        var didConsumeLegacyFlag = false

        try queue.write { db in
            guard try db.tableExists("indexed_photos") else { return }
            try createAppStateTableIfNeeded(db)

            let storedVersion = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [embeddingFormatStateKey]
            )
            guard storedVersion != currentEmbeddingFormatVersion else { return }

            let existingEmbeddingCount = try embeddingCount(in: db)
            if existingEmbeddingCount > 0
                && (orientationMigrationWasAlreadyApplied || legacyRebuildRequired) {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try setAppState(
                embeddingFormatStateKey,
                value: currentEmbeddingFormatVersion,
                in: db
            )
            didConsumeLegacyFlag = legacyRebuildRequired
        }

        if didConsumeLegacyFlag {
            UserDefaults.standard.removeObject(forKey: legacyFastFormatRebuildKey)
        }
    }

    private static func createAppStateTableIfNeeded(_ db: Database) throws {
        try db.create(table: "app_state", ifNotExists: true) { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
        }
    }

    private static func setAppState(_ key: String, value: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO app_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    private static func embeddingCount(in db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0)
            + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_video_frames") ?? 0)
    }

    private static func shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
        in db: Database
    ) throws -> Bool {
        let rebuildRequired = try String.fetchOne(
            db,
            sql: "SELECT value FROM app_state WHERE key = ?",
            arguments: [indexRebuildStateKey]
        ) == "true"
        guard rebuildRequired else { return false }
        return try embeddingCount(in: db) == 0
    }

    private static func clearIndexRebuildRequired(in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM app_state WHERE key = ?",
            arguments: [indexRebuildStateKey]
        )
    }

    private enum DatabaseInitError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            "Application Support directory not found"
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "indexed_photos") { t in
                t.column("id", .text).primaryKey()
                t.column("localIdentifier", .text).notNull().unique()
                t.column("creationDate", .datetime)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("pixelWidth", .integer).notNull()
                t.column("pixelHeight", .integer).notNull()
                t.column("embedding", .blob).notNull()
                t.column("indexedAt", .datetime).notNull()
                t.column("ocrText", .text)
                t.column("sharpnessScore", .double)
                t.column("sourceId", .text).notNull().defaults(to: "photokit")
                t.column("filePath", .text)
                t.column("locationCity", .text)
                t.column("locationState", .text)
                t.column("locationCountry", .text)
                t.column("locationName", .text)
                t.column("sceneLabels", .text)
            }

            try db.create(table: "photo_sources") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("path", .text)
                t.column("name", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastIndexedAt", .datetime)
                t.column("photoCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "indexed_videos") { t in
                t.column("id", .text).primaryKey()
                t.column("localIdentifier", .text).notNull().unique()
                t.column("creationDate", .datetime)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("duration", .double).notNull()
                t.column("pixelWidth", .integer).notNull()
                t.column("pixelHeight", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("indexedAt", .datetime).notNull()
                t.column("sourceId", .text).notNull().defaults(to: "photokit")
                t.column("locationCity", .text)
                t.column("locationState", .text)
                t.column("locationCountry", .text)
                t.column("locationName", .text)
            }

            try db.create(table: "indexed_video_frames") { t in
                t.column("id", .text).primaryKey()
                t.column("videoId", .text).notNull().references("indexed_videos", onDelete: .cascade)
                t.column("framePosition", .double).notNull()
                t.column("embedding", .blob).notNull()
                t.column("indexedAt", .datetime).notNull()
            }
            try db.create(index: "idx_video_frames_videoId", on: "indexed_video_frames",
                           columns: ["videoId"])

            try db.create(table: "search_history") { t in
                t.column("id", .integer).primaryKey(autoincrement: true)
                t.column("query", .text).notNull()
                t.column("searchedAt", .datetime).notNull()
            }

            try db.create(table: "smart_albums") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("query", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(index: "idx_photos_city", on: "indexed_photos",
                           columns: ["locationCity"])
        }

        // SigLIP2 model replacement: old MobileCLIP embeddings are incompatible.
        // Clear all indexed data so the app re-indexes with the new model.
        migrator.registerMigration("v2-siglip2-model-swap") { db in
            try db.execute(sql: "DELETE FROM indexed_video_frames")
            try db.execute(sql: "DELETE FROM indexed_videos")
            try db.execute(sql: "DELETE FROM indexed_photos")
        }

        // Embedding preprocessing changed to respect UIImage/EXIF orientation.
        // Old embeddings may represent raw sensor pixels rather than the
        // displayed image, so clear indexed media and rebuild homogeneously.
        migrator.registerMigration("v3-orientation-normalized-embeddings") { db in
            let existingMediaCount =
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0)
                + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_videos") ?? 0)
            try createAppStateTableIfNeeded(db)
            if existingMediaCount > 0 {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try db.execute(sql: "DELETE FROM indexed_video_frames")
            try db.execute(sql: "DELETE FROM indexed_videos")
            try db.execute(sql: "DELETE FROM indexed_photos")
        }

        // Existing rows were enriched inline by older indexing code. New rows
        // inserted by the progressive indexing path set this to false and are
        // completed by the deferred enrichment pass.
        migrator.registerMigration("v4-photo-enrichment-state") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "enrichmentComplete", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "idx_photos_enrichment_pending", on: "indexed_photos",
                          columns: ["enrichmentComplete", "creationDate"])
        }

        // V2 briefly indexed first-pass photo embeddings from PhotoKit
        // `.fastFormat` images. That can produce low-quality embedding inputs
        // on device and leave the app with a populated but ineffective search
        // index. Rebuild photo embeddings with the high-quality local loader.
        migrator.registerMigration("v5-rebuild-fastformat-photo-embeddings") { db in
            let existingPhotoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0
            try createAppStateTableIfNeeded(db)
            if existingPhotoCount > 0 {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try db.execute(sql: "DELETE FROM indexed_photos")
        }

        // Keep transient enrichment load failures retryable without allowing
        // one unreadable photo to spin inside a single enrichment pass.
        migrator.registerMigration("v6-photo-enrichment-retry") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "enrichmentAttemptedAt", .datetime)
            }
        }

        migrator.registerMigration("v7-index-rebuild-state") { db in
            try createAppStateTableIfNeeded(db)
        }

        // Older indexing wrote video metadata before its frames. If the app
        // stopped between those writes, the metadata row made later passes
        // skip a video that had no searchable embedding.
        migrator.registerMigration("v8-remove-incomplete-videos") { db in
            try db.execute(
                sql: """
                    DELETE FROM indexed_videos
                    WHERE NOT EXISTS (
                        SELECT 1 FROM indexed_video_frames
                        WHERE indexed_video_frames.videoId = indexed_videos.id
                    )
                """
            )
        }

        return migrator
    }

    // MARK: - Photos

    func insertPhoto(_ photo: IndexedPhoto) throws {
        try dbQueue.write { db in
            try photo.insert(db)
        }
    }

    @discardableResult
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool {
        guard !photos.isEmpty else { return false }
        return try dbQueue.write { db in
            var completesRequiredRebuild = false
            if completingRequiredRebuild {
                completesRequiredRebuild = try Self.shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
                    in: db
                )
            }
            for photo in photos {
                try photo.insert(db, onConflict: .ignore)
            }
            if completesRequiredRebuild {
                try Self.clearIndexRebuildRequired(in: db)
            }
            return completesRequiredRebuild
        }
    }

    func isIndexed(localIdentifier: String) throws -> Bool {
        try dbQueue.read { db in
            try IndexedPhoto.filter(Column("localIdentifier") == localIdentifier).fetchCount(db) > 0
        }
    }

    func allIndexedIdentifiers() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT localIdentifier FROM indexed_photos"))
        }
    }

    func allIndexedFilePaths() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT filePath FROM indexed_photos WHERE filePath IS NOT NULL"))
        }
    }

    func indexedCount() throws -> Int {
        try dbQueue.read { db in
            try IndexedPhoto.fetchCount(db)
        }
    }

    func loadAllEmbeddings() throws -> EmbeddingIndex {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif
        let result = try dbQueue.read { db in
            let photos = try IndexedPhoto.order(Column("creationDate").desc).fetchAll(db)

            var allIds: [String] = []
            var allLocalIds: [String] = []
            var allDates: [Date?] = []
            var allLats: [Double?] = []
            var allLons: [Double?] = []
            var allOcrTexts: [String?] = []
            var allCities: [String?] = []
            var allStates: [String?] = []
            var allCountries: [String?] = []
            var allLocNames: [String?] = []
            var allSceneLabels: [String?] = []
            var allEmbeddings: [Float16] = []
            allEmbeddings.reserveCapacity(photos.count * EmbeddingConfig.dimensions)

            for photo in photos {
                guard photo.embedding.count == EmbeddingConfig.bytesPerEmbedding else { continue }

                allIds.append(photo.id)
                allLocalIds.append(photo.localIdentifier)
                allDates.append(photo.creationDate)
                allLats.append(photo.latitude)
                allLons.append(photo.longitude)
                allOcrTexts.append(photo.ocrText)
                allCities.append(photo.locationCity)
                allStates.append(photo.locationState)
                allCountries.append(photo.locationCountry)
                allLocNames.append(photo.locationName)
                allSceneLabels.append(photo.sceneLabels)

                photo.embedding.withUnsafeBytes { rawBuffer in
                    let ptr = rawBuffer.bindMemory(to: Float16.self)
                    allEmbeddings.append(contentsOf: UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
                }
            }

            return EmbeddingIndex(
                ids: allIds, localIdentifiers: allLocalIds, dates: allDates,
                latitudes: allLats, longitudes: allLons, ocrTexts: allOcrTexts,
                locationCities: allCities, locationStates: allStates,
                locationCountries: allCountries, locationNames: allLocNames,
                sceneLabels: allSceneLabels,
                embeddings: allEmbeddings
            )
        }

        #if DEBUG
        logger.info("[Database] Loaded \(result.ids.count) photo embeddings in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart))s")
        #endif

        return result
    }

    func deleteAll() throws {
        try dbQueue.write { db in
            _ = try IndexedPhoto.deleteAll(db)
            _ = try db.execute(sql: "DELETE FROM indexed_video_frames")
            _ = try IndexedVideo.deleteAll(db)
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
                                enrichmentComplete = 1, enrichmentAttemptedAt = NULL
                            WHERE localIdentifier = ?
                        """,
                        arguments: [
                            update.ocrText,
                            update.sharpnessScore,
                            update.sceneLabels,
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

    func indexRebuildRequired() throws -> Bool {
        try dbQueue.read { db in
            guard try db.tableExists("app_state") else { return false }
            return try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [Self.indexRebuildStateKey]
            ) == "true"
        }
    }

    func clearIndexRebuildRequired() throws {
        try dbQueue.write { db in
            guard try db.tableExists("app_state") else { return }
            try Self.clearIndexRebuildRequired(in: db)
        }
    }

    // MARK: - Sources

    func insertSource(_ source: PhotoSource) throws {
        try dbQueue.write { db in
            try source.insert(db)
        }
    }

    func listSources() throws -> [PhotoSource] {
        try dbQueue.read { db in
            try PhotoSource.order(Column("addedAt").desc).fetchAll(db)
        }
    }

    func deleteSource(_ id: String) throws {
        try dbQueue.write { db in
            _ = try IndexedPhoto.filter(Column("sourceId") == id).deleteAll(db)
            _ = try PhotoSource.filter(Column("id") == id).deleteAll(db)
        }
        UserDefaults.standard.removeObject(forKey: AppKeys.folderBookmark(sourceId: id))
    }

    func updateSourceStats(_ id: String, photoCount: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = ?, lastIndexedAt = ? WHERE id = ?",
                arguments: [photoCount, Date(), id]
            )
        }
    }

    // MARK: - Videos

    func isVideoIndexed(localIdentifier: String) throws -> Bool {
        try dbQueue.read { db in
            try IndexedVideo.filter(Column("localIdentifier") == localIdentifier).fetchCount(db) > 0
        }
    }

    func videoIndexedCount() throws -> Int {
        try dbQueue.read { db in try IndexedVideo.fetchCount(db) }
    }

    func allIndexedVideoIdentifiers() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT localIdentifier FROM indexed_videos"))
        }
    }

    func loadAllVideoEmbeddings() throws -> VideoEmbeddingIndex {
        try dbQueue.read { db in
            let sql = """
                SELECT v.id, v.localIdentifier, v.creationDate, v.latitude, v.longitude,
                       v.locationCity, v.locationState, v.locationCountry, v.locationName,
                       f.framePosition, f.embedding
                FROM indexed_video_frames f
                JOIN indexed_videos v ON f.videoId = v.id
                ORDER BY v.creationDate DESC, f.framePosition ASC
            """
            let rows = try Row.fetchAll(db, sql: sql)

            var allVideoIds: [String] = []
            var allLocalIds: [String] = []
            var allDates: [Date?] = []
            var allLats: [Double?] = []
            var allLons: [Double?] = []
            var allPositions: [Double] = []
            var allCities: [String?] = []
            var allStates: [String?] = []
            var allCountries: [String?] = []
            var allLocNames: [String?] = []
            var allEmbeddings: [Float16] = []

            for row in rows {
                let embeddingData: Data = row["embedding"]
                guard embeddingData.count == EmbeddingConfig.bytesPerEmbedding else { continue }

                allVideoIds.append(row["id"] as String)
                allLocalIds.append(row["localIdentifier"] as String)
                allDates.append(row["creationDate"] as Date?)
                allLats.append(row["latitude"] as Double?)
                allLons.append(row["longitude"] as Double?)
                allPositions.append(row["framePosition"] as Double)
                allCities.append(row["locationCity"] as String?)
                allStates.append(row["locationState"] as String?)
                allCountries.append(row["locationCountry"] as String?)
                allLocNames.append(row["locationName"] as String?)

                embeddingData.withUnsafeBytes { rawBuffer in
                    let ptr = rawBuffer.bindMemory(to: Float16.self)
                    allEmbeddings.append(contentsOf: UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
                }
            }

            return (allVideoIds, allLocalIds, allDates, allLats, allLons, allPositions,
                    allCities, allStates, allCountries, allLocNames, allEmbeddings)
        }
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
        guard !frames.isEmpty else { return false }
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

    func trimToLimit(_ limit: Int) throws {
        try dbQueue.write { db in
            let photoCount = try IndexedPhoto.fetchCount(db)
            let videoCount = try IndexedVideo.fetchCount(db)
            let totalCount = photoCount + videoCount

            guard totalCount > limit else { return }

            // Proportional allocation: each type keeps its share of the limit
            let photoLimit: Int
            let videoLimit: Int
            if photoCount == 0 {
                photoLimit = 0
                videoLimit = limit
            } else if videoCount == 0 {
                photoLimit = limit
                videoLimit = 0
            } else {
                photoLimit = max(Int(Double(photoCount) / Double(totalCount) * Double(limit)), 1)
                videoLimit = max(limit - photoLimit, 1)
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
        }
    }

    func photosNeedingLocationBackfill(limit: Int = 500) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_photos
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                AND (locationCity IS NULL OR locationCity = '')
                LIMIT ?
            """, arguments: [limit])
            return rows.map { (
                $0["localIdentifier"] as String,
                $0["latitude"] as Double,
                $0["longitude"] as Double
            ) }
        }
    }

    func videosNeedingLocationBackfill(limit: Int = 500) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_videos
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                AND (locationCity IS NULL OR locationCity = '')
                LIMIT ?
            """, arguments: [limit])
            return rows.map { (
                $0["localIdentifier"] as String,
                $0["latitude"] as Double,
                $0["longitude"] as Double
            ) }
        }
    }

    func photosNeedingLocationBackfillCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_photos
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                AND (locationCity IS NULL OR locationCity = '')
            """) ?? 0
        }
    }

    func videosNeedingLocationBackfillCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_videos
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                AND (locationCity IS NULL OR locationCity = '')
            """) ?? 0
        }
    }

    func photosWithGPSCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_photos
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
            """) ?? 0
        }
    }

    func videosWithGPSCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_videos
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL
            """) ?? 0
        }
    }

    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?,
                                    country: String?, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_photos
                    SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?
                    WHERE localIdentifier = ?
                """,
                arguments: [city, state, country, name, localIdentifier]
            )
        }
    }

    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?,
                                    country: String?, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_videos
                    SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?
                    WHERE localIdentifier = ?
                """,
                arguments: [city, state, country, name, localIdentifier]
            )
        }
    }

    func fetchRandomPhoto(sharp: Bool) throws -> IndexedPhoto? {
        try dbQueue.read { db in
            var photo: IndexedPhoto?
            if sharp {
                photo = try IndexedPhoto
                    .filter(Column("sharpnessScore") > 50)
                    .order(sql: "RANDOM()")
                    .limit(1)
                    .fetchOne(db)
            }
            if photo == nil {
                photo = try IndexedPhoto
                    .order(sql: "RANDOM()")
                    .limit(1)
                    .fetchOne(db)
            }
            return photo
        }
    }

    func onThisDayPhotos() throws -> [(year: Int, ids: [String])] {
        let calendar = Calendar.current
        let today = Date()
        let currentMonth = calendar.component(.month, from: today)
        let currentDay = calendar.component(.day, from: today)
        let currentYear = calendar.component(.year, from: today)

        return try dbQueue.read { db in
            let sql = """
                SELECT localIdentifier, creationDate
                FROM indexed_photos
                WHERE creationDate IS NOT NULL
                  AND cast(strftime('%m', creationDate) as integer) = ?
                  AND abs(cast(strftime('%d', creationDate) as integer) - ?) <= 1
                  AND cast(strftime('%Y', creationDate) as integer) < ?
                ORDER BY creationDate DESC
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [currentMonth, currentDay, currentYear])

            var yearGroups: [Int: [String]] = [:]
            for row in rows {
                guard let date: Date = row["creationDate"] else { continue }
                let year = calendar.component(.year, from: date)
                yearGroups[year, default: []].append(row["localIdentifier"])
            }

            return yearGroups
                .sorted { $0.key > $1.key }
                .map { (year: $0.key, ids: $0.value) }
        }
    }

    // MARK: - Search History

    func addSearchHistory(_ query: String) throws {
        try dbQueue.write { db in
            // Remove existing duplicate (case-insensitive)
            try db.execute(sql: "DELETE FROM search_history WHERE LOWER(query) = LOWER(?)", arguments: [query])
            try db.execute(
                sql: "INSERT INTO search_history (query, searchedAt) VALUES (?, ?)",
                arguments: [query, Date()]
            )
            // Keep only the most recent 20
            try db.execute(sql: """
                DELETE FROM search_history WHERE id NOT IN (
                    SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT 20
                )
            """)
        }
    }

    func loadSearchHistory() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT query FROM search_history ORDER BY searchedAt DESC")
        }
    }

    func clearSearchHistory() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM search_history")
        }
    }

    func removeSearchHistory(at index: Int) throws {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM search_history ORDER BY searchedAt DESC")
            guard index < rows.count else { return }
            let id: Int64 = rows[index]["id"]
            try db.execute(sql: "DELETE FROM search_history WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Smart Albums

    func loadSmartAlbums() throws -> [SmartAlbum] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, query, createdAt FROM smart_albums ORDER BY createdAt DESC").map { row in
                SmartAlbum(
                    id: row["id"],
                    name: row["name"],
                    query: row["query"],
                    createdAt: row["createdAt"]
                )
            }
        }
    }

    func saveSmartAlbum(_ album: SmartAlbum) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO smart_albums (id, name, query, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [album.id, album.name, album.query, album.createdAt]
            )
        }
    }

    func deleteSmartAlbum(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM smart_albums WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - SwiftUI Environment

import SwiftUI

private struct DatabaseKey: EnvironmentKey {
    static let defaultValue: DatabaseProtocol = AppDatabase.shared
}

extension EnvironmentValues {
    var database: DatabaseProtocol {
        get { self[DatabaseKey.self] }
        set { self[DatabaseKey.self] = newValue }
    }
}
