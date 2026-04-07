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
    var embeddings: [Float16]
}

typealias VideoEmbeddingIndex = (videoIds: [String], localIdentifiers: [String], dates: [Date?], latitudes: [Double?], longitudes: [Double?], framePositions: [Double], embeddings: [Float16])

// MARK: - Database Protocol

protocol DatabaseProtocol {
    // Photos
    func insertPhoto(_ photo: IndexedPhoto) throws
    func insertPhotos(_ photos: [IndexedPhoto]) throws
    func isIndexed(localIdentifier: String) throws -> Bool
    func allIndexedIdentifiers() throws -> Set<String>
    func allIndexedFilePaths() throws -> Set<String>
    func indexedCount() throws -> Int
    func loadAllEmbeddings() throws -> EmbeddingIndex
    func deleteAll() throws
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws
    func fetchRandomPhoto(sharp: Bool) throws -> IndexedPhoto?

    // Videos
    func insertVideo(_ video: IndexedVideo) throws
    func insertVideoFrames(_ frames: [IndexedVideoFrame]) throws
    func isVideoIndexed(localIdentifier: String) throws -> Bool
    func videoIndexedCount() throws -> Int
    func allIndexedVideoIdentifiers() throws -> Set<String>
    func loadAllVideoEmbeddings() throws -> VideoEmbeddingIndex
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws
    func trimToLimit(_ limit: Int) throws

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
    let dbQueue: DatabaseQueue

    private init() {
        dbQueue = Self.openDatabase()
        do {
            try migrator.migrate(dbQueue)
            #if DEBUG
            logger.info("[Database] Migrations completed successfully")
            #endif
        } catch {
            logger.error("Database migration failed: \(error.localizedDescription)")
        }
    }

    private static func openDatabase() -> DatabaseQueue {
        do {
            let fileManager = FileManager.default
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                logger.error("Application Support directory not found, using in-memory fallback")
                Self.isInMemoryFallback = true
                // Intentional force-try: in-memory DatabaseQueue allocation virtually never fails
                return try! DatabaseQueue()
            }
            let dbDir = appSupport.appendingPathComponent("Memorable", isDirectory: true)
            try fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbPath = dbDir.appendingPathComponent("photos.sqlite").path

            let config = Configuration()
            let queue = try DatabaseQueue(path: dbPath, configuration: config)

            if fileManager.fileExists(atPath: dbPath) {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: dbPath
                )
            }

            return queue
        } catch {
            logger.error("Database init failed, using in-memory fallback: \(error.localizedDescription)")
            Self.isInMemoryFallback = true
            // Intentional force-try: in-memory DatabaseQueue allocation virtually never fails
            return try! DatabaseQueue()
        }
    }

    private var migrator: DatabaseMigrator {
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
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "photo_sources") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("path", .text)
                t.column("name", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastIndexedAt", .datetime)
                t.column("photoCount", .integer).notNull().defaults(to: 0)
            }
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "sourceId", .text).defaults(to: "photokit")
                t.add(column: "filePath", .text)
            }
        }

        migrator.registerMigration("v3_ocr") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "ocrText", .text)
            }
        }

        migrator.registerMigration("v4_video") { db in
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
            }

            try db.create(table: "indexed_video_frames") { t in
                t.column("id", .text).primaryKey()
                t.column("videoId", .text).notNull().references("indexed_videos", onDelete: .cascade)
                t.column("framePosition", .double).notNull()
                t.column("embedding", .blob).notNull()
                t.column("indexedAt", .datetime).notNull()
            }

            try db.create(index: "idx_video_frames_videoId", on: "indexed_video_frames", columns: ["videoId"])
        }

        // LEGACY: Face detection was removed. These migrations must remain for users
        // who had the old schema — the tables exist but are empty and unused.
        migrator.registerMigration("v5_faces") { db in
            try db.create(table: "face_clusters") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text)
                t.column("representativeFaceData", .blob)
                t.column("photoCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "detected_faces") { t in
                t.column("id", .text).primaryKey()
                t.column("photoLocalIdentifier", .text).notNull()
                t.column("faceEmbedding", .blob).notNull()
                t.column("boundingBoxJSON", .text).notNull()
                t.column("clusterId", .text).references("face_clusters", onDelete: .setNull)
                t.column("indexedAt", .datetime).notNull()
            }

            try db.create(index: "idx_faces_photo", on: "detected_faces", columns: ["photoLocalIdentifier"])
            try db.create(index: "idx_faces_cluster", on: "detected_faces", columns: ["clusterId"])
        }

        // LEGACY: Cleared face data when embedding format changed. Tables remain empty.
        migrator.registerMigration("v6_clip_faces") { db in
            try db.execute(sql: "DELETE FROM detected_faces")
            try db.execute(sql: "DELETE FROM face_clusters")
        }

        migrator.registerMigration("v7_sharpness") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "sharpnessScore", .double)
            }
        }

        migrator.registerMigration("v8_search_history") { db in
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
        }

        return migrator
    }

    // MARK: - Photos

    func insertPhoto(_ photo: IndexedPhoto) throws {
        try dbQueue.write { db in
            try photo.insert(db)
        }
    }

    func insertPhotos(_ photos: [IndexedPhoto]) throws {
        try dbQueue.write { db in
            for photo in photos {
                try photo.insert(db)
            }
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

                photo.embedding.withUnsafeBytes { rawBuffer in
                    let ptr = rawBuffer.bindMemory(to: Float16.self)
                    allEmbeddings.append(contentsOf: UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
                }
            }

            return EmbeddingIndex(
                ids: allIds, localIdentifiers: allLocalIds, dates: allDates,
                latitudes: allLats, longitudes: allLons, ocrTexts: allOcrTexts,
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

    func insertVideo(_ video: IndexedVideo) throws {
        try dbQueue.write { db in try video.insert(db) }
    }

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
                SELECT v.id, v.localIdentifier, v.creationDate, v.latitude, v.longitude, f.framePosition, f.embedding
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

                embeddingData.withUnsafeBytes { rawBuffer in
                    let ptr = rawBuffer.bindMemory(to: Float16.self)
                    allEmbeddings.append(contentsOf: UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
                }
            }

            return (allVideoIds, allLocalIds, allDates, allLats, allLons, allPositions, allEmbeddings)
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

    func insertVideoFrames(_ frames: [IndexedVideoFrame]) throws {
        try dbQueue.write { db in
            for frame in frames { try frame.insert(db) }
        }
    }

    func trimToLimit(_ limit: Int) throws {
        try dbQueue.write { db in
            // Keep the most recently indexed photos, delete the rest
            let photoCount = try IndexedPhoto.fetchCount(db)
            if photoCount > limit {
                try db.execute(sql: """
                    DELETE FROM indexed_photos WHERE id NOT IN (
                        SELECT id FROM indexed_photos ORDER BY indexedAt DESC LIMIT ?
                    )
                """, arguments: [limit])
            }

            // Delete all videos beyond the limit (videos count toward the total)
            let remainingPhotos = try IndexedPhoto.fetchCount(db)
            let videoLimit = max(limit - remainingPhotos, 0)
            let videoCount = try IndexedVideo.fetchCount(db)
            if videoCount > videoLimit {
                // Delete excess video frames first, then videos
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
                if yearGroups[year] == nil { yearGroups[year] = [] }
                yearGroups[year]?.append(row["localIdentifier"])
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
