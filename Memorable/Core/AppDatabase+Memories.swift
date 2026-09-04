import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Memories

    func fetchRandomPhoto(sharp: Bool) throws -> SlideshowPhoto? {
        try dbQueue.read { db in
            var photo: SlideshowPhoto?
            if sharp {
                photo = try Self.fetchRandomSlideshowPhoto(
                    db,
                    sharpOnly: true
                )
            }
            if photo == nil {
                photo = try Self.fetchRandomSlideshowPhoto(db, sharpOnly: false)
            }
            return photo
        }
    }

    private static func fetchRandomSlideshowPhoto(
        _ db: Database,
        sharpOnly: Bool
    ) throws -> SlideshowPhoto? {
        let sharpClause = sharpOnly ? "AND sharpnessScore > 50" : ""
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, localIdentifier, creationDate, sourceId, filePath,
                       enrichmentComplete,
                       CASE WHEN length(embedding) = ? THEN embedding END AS embedding
                FROM indexed_photos
                WHERE rowid IN (
                    SELECT rowid FROM indexed_photos
                    ORDER BY rowid DESC
                    LIMIT ?
                )
                  AND isScreenshot = 0
                  AND isDocumentImage = 0
                \(sharpClause)
                ORDER BY RANDOM()
                LIMIT 1
            """,
            arguments: [
                EmbeddingConfig.bytesPerEmbedding,
                SearchIndexLimits.maximumPhotoRows,
            ]
        ) else {
            return nil
        }
        guard let embedding: Data = row["embedding"] else {
            throw SearchEngineError.corruptedIndex
        }
        return SlideshowPhoto(
            id: row["id"],
            localIdentifier: row["localIdentifier"],
            creationDate: row["creationDate"],
            embedding: embedding,
            sourceId: row["sourceId"],
            filePath: row["filePath"],
            requiresContentValidation: !(row["enrichmentComplete"] as Bool)
        )
    }

    func distinctMemoryPhotoIDs(in ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var embeddingsByID: [String: Data] = [:]
        try dbQueue.read { db in
            for chunk in ids.chunked(into: 900) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, embedding
                        FROM indexed_photos
                        WHERE id IN (\(placeholders))
                          AND isScreenshot = 0
                          AND isDocumentImage = 0
                    """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    embeddingsByID[row["id"] as String] = row["embedding"] as Data
                }
            }
        }

        var duplicateFilter = MemoryDuplicateFilter()
        var retained: Set<String> = []
        for id in ids {
            guard let embedding = embeddingsByID[id], duplicateFilter.accepts(embedding) else {
                continue
            }
            retained.insert(id)
        }
        return retained
    }

    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])] {
        let calendar = Calendar.current
        let today = Date()
        let currentMonth = calendar.component(.month, from: today)
        let currentDay = calendar.component(.day, from: today)
        let currentYear = calendar.component(.year, from: today)

        return try dbQueue.read { db in
            let sql = """
                SELECT id, localIdentifier, creationDate, sourceId, filePath, embedding
                FROM indexed_photos
                WHERE rowid IN (
                    SELECT rowid FROM indexed_photos
                    ORDER BY rowid DESC
                    LIMIT ?
                )
                  AND creationDate IS NOT NULL
                  AND isScreenshot = 0
                  AND isDocumentImage = 0
                  AND cast(strftime('%m', creationDate, 'localtime') as integer) = ?
                  AND abs(cast(strftime('%d', creationDate, 'localtime') as integer) - ?) <= 1
                  AND cast(strftime('%Y', creationDate, 'localtime') as integer) < ?
                ORDER BY creationDate DESC
                LIMIT ?
            """
            let cursor = try Row.fetchCursor(
                db,
                sql: sql,
                arguments: [
                    SearchIndexLimits.maximumPhotoRows,
                    currentMonth,
                    currentDay,
                    currentYear,
                    MemoryConfig.maximumOnThisDayYears
                        * MemoryConfig.maximumOnThisDayPhotosPerYear,
                ]
            )
            var yearGroups: [Int: [IndexedPhotoReference]] = [:]
            var duplicateFilters: [Int: MemoryDuplicateFilter] = [:]
            while let row = try cursor.next() {
                guard let date: Date = row["creationDate"] else { continue }
                let year = calendar.component(.year, from: date)
                if yearGroups[year] == nil,
                   yearGroups.count >= MemoryConfig.maximumOnThisDayYears {
                    break
                }
                guard yearGroups[year, default: []].count
                        < MemoryConfig.maximumOnThisDayPhotosPerYear else { continue }
                let embedding: Data = row["embedding"]
                var duplicateFilter = duplicateFilters[year] ?? MemoryDuplicateFilter()
                guard duplicateFilter.accepts(embedding) else { continue }
                duplicateFilters[year] = duplicateFilter
                yearGroups[year, default: []].append(IndexedPhotoReference(
                    id: row["id"],
                    localIdentifier: row["localIdentifier"],
                    creationDate: date,
                    sourceId: row["sourceId"],
                    filePath: row["filePath"]
                ))
            }

            return yearGroups
                .sorted { $0.key > $1.key }
                .map { (year: $0.key, photos: $0.value) }
        }
    }

    // MARK: - Search History

    func addSearchHistory(_ query: String) throws {
        try addSearchHistory(query, preview: nil)
    }

    func addSearchHistory(_ query: String, preview: RecentSearchPreview?) throws {
        let boundedQuery = QueryInputPolicy.bounded(query)
        guard !boundedQuery.isEmpty else { return }
        try dbQueue.write { db in
            // Remove existing duplicate (case-insensitive)
            try db.execute(sql: "DELETE FROM search_history WHERE LOWER(query) = LOWER(?)", arguments: [boundedQuery])
            try db.execute(
                sql: """
                    INSERT INTO search_history (
                        query, searchedAt, previewResultID, previewScore, previewLocalIdentifier,
                        previewCreationDate, previewIsVideo, previewBestFramePosition,
                        previewSourceId, previewFilePath, previewResultCount
                    ) VALUES (
                        :query, :searchedAt, :previewResultID, :previewScore, :previewLocalIdentifier,
                        :previewCreationDate, :previewIsVideo, :previewBestFramePosition,
                        :previewSourceId, :previewFilePath, :previewResultCount
                    )
                    """,
                arguments: [
                    "query": boundedQuery,
                    "searchedAt": Date(),
                    "previewResultID": preview?.result.id,
                    "previewScore": preview?.result.score,
                    "previewLocalIdentifier": preview?.result.localIdentifier,
                    "previewCreationDate": preview?.result.creationDate,
                    "previewIsVideo": preview?.result.isVideo,
                    "previewBestFramePosition": preview?.result.bestFramePosition,
                    "previewSourceId": preview?.result.sourceId,
                    "previewFilePath": preview?.result.filePath,
                    "previewResultCount": preview?.resultCount,
                ]
            )
            // Keep only the most recent 20
            try db.execute(sql: """
                DELETE FROM search_history WHERE id NOT IN (
                    SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT 20
                )
            """)
        }
    }

    func backfillSearchHistoryPreviews(_ previews: [RecentSearchPreview]) throws {
        guard !previews.isEmpty else { return }
        try dbQueue.write { db in
            for preview in previews {
                try db.execute(
                    sql: """
                        UPDATE search_history
                        SET previewResultID = :previewResultID,
                            previewScore = :previewScore,
                            previewLocalIdentifier = :previewLocalIdentifier,
                            previewCreationDate = :previewCreationDate,
                            previewIsVideo = :previewIsVideo,
                            previewBestFramePosition = :previewBestFramePosition,
                            previewSourceId = :previewSourceId,
                            previewFilePath = :previewFilePath,
                            previewResultCount = :previewResultCount
                        WHERE LOWER(query) = LOWER(:query)
                          AND (previewResultID IS NULL OR previewLocalIdentifier IS NULL)
                        """,
                    arguments: [
                        "query": preview.query,
                        "previewResultID": preview.result.id,
                        "previewScore": preview.result.score,
                        "previewLocalIdentifier": preview.result.localIdentifier,
                        "previewCreationDate": preview.result.creationDate,
                        "previewIsVideo": preview.result.isVideo,
                        "previewBestFramePosition": preview.result.bestFramePosition,
                        "previewSourceId": preview.result.sourceId,
                        "previewFilePath": preview.result.filePath,
                        "previewResultCount": preview.resultCount,
                    ]
                )
            }
        }
    }

    func loadSearchHistory() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT query FROM search_history ORDER BY searchedAt DESC LIMIT 20")
        }
    }

    func loadSearchHistoryPreviews(limit: Int) throws -> [RecentSearchPreview] {
        let boundedLimit = max(0, min(limit, 20))
        guard boundedLimit > 0 else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT query, previewResultID, previewScore, previewLocalIdentifier,
                           previewCreationDate, previewIsVideo, previewBestFramePosition,
                           previewSourceId, previewFilePath, previewResultCount
                    FROM search_history
                    ORDER BY searchedAt DESC
                    LIMIT ?
                    """,
                arguments: [boundedLimit]
            ).compactMap { row in
                let resultID: String? = row["previewResultID"]
                let localIdentifier: String? = row["previewLocalIdentifier"]
                guard let resultID, let localIdentifier else { return nil }
                let query: String = row["query"]
                let sourceId: String? = row["previewSourceId"]
                let result = SearchResult(
                    id: resultID,
                    score: row["previewScore"] ?? 1,
                    localIdentifier: localIdentifier,
                    creationDate: row["previewCreationDate"],
                    isVideo: row["previewIsVideo"] ?? false,
                    bestFramePosition: row["previewBestFramePosition"],
                    sourceId: sourceId ?? PhotoSourceType.photokit.rawValue,
                    filePath: row["previewFilePath"]
                )
                let resultCount: Int? = row["previewResultCount"]
                return RecentSearchPreview(
                    query: query,
                    result: result,
                    resultCount: resultCount ?? 0
                )
            }
        }
    }

    func clearSearchHistory() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM search_history")
        }
    }

    func removeSearchHistory(at index: Int) throws {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT 20")
            guard index < rows.count else { return }
            let id: Int64 = rows[index]["id"]
            try db.execute(sql: "DELETE FROM search_history WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Smart Albums

    func loadSmartAlbums() throws -> [SmartAlbum] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, name, query, createdAt FROM smart_albums ORDER BY createdAt DESC LIMIT ?",
                arguments: [SmartAlbumPolicy.maximumAlbums]
            ).map { row in
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
        let boundedAlbum = SmartAlbum(
            id: album.id,
            name: SmartAlbumPolicy.boundedName(album.name),
            query: QueryInputPolicy.bounded(album.query),
            createdAt: album.createdAt
        )
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO smart_albums (id, name, query, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [boundedAlbum.id, boundedAlbum.name, boundedAlbum.query, boundedAlbum.createdAt]
            )
            try db.execute(sql: """
                DELETE FROM smart_albums WHERE id NOT IN (
                    SELECT id FROM smart_albums ORDER BY createdAt DESC LIMIT ?
                )
            """, arguments: [SmartAlbumPolicy.maximumAlbums])
        }
    }

    func deleteSmartAlbum(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM smart_albums WHERE id = ?", arguments: [id])
        }
    }
}
