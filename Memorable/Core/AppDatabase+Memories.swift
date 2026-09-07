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
        var yearGroups: [Int: [IndexedPhotoReference]] = [:]
        for candidate in try distinctOnThisDayPhotos() {
            yearGroups[candidate.year, default: []].append(candidate.photo)
        }

        return yearGroups
            .sorted { $0.key > $1.key }
            .map { (year: $0.key, photos: $0.value) }
    }

    func onThisDaySummary() throws -> OnThisDaySummary? {
        var heroPhoto: IndexedPhotoReference?
        var mostRecentYear = Int.min
        var years = Set<Int>()
        var photoCount = 0

        for candidate in try distinctOnThisDayPhotos() {
            if heroPhoto == nil {
                heroPhoto = candidate.photo
            }
            mostRecentYear = max(mostRecentYear, candidate.year)
            years.insert(candidate.year)
            photoCount += 1
        }

        guard let heroPhoto else { return nil }
        return OnThisDaySummary(
            heroPhoto: heroPhoto,
            mostRecentYear: mostRecentYear,
            yearCount: years.count,
            photoCount: photoCount
        )
    }

    private struct OnThisDayCandidate {
        let year: Int
        let photo: IndexedPhotoReference
        let embedding: Data
    }

    private func distinctOnThisDayPhotos() throws -> [(year: Int, photo: IndexedPhotoReference)] {
        let candidates = try dbQueue.read { db in
            try Self.fetchOnThisDayCandidates(in: db)
        }
        var results: [(year: Int, photo: IndexedPhotoReference)] = []
        var acceptedCountsByYear: [Int: Int] = [:]
        var duplicateFilters: [Int: MemoryDuplicateFilter] = [:]

        for candidate in candidates {
            if Task.isCancelled { throw CancellationError() }
            if acceptedCountsByYear[candidate.year] == nil,
               acceptedCountsByYear.count >= MemoryConfig.maximumOnThisDayYears {
                break
            }
            guard acceptedCountsByYear[candidate.year, default: 0]
                    < MemoryConfig.maximumOnThisDayPhotosPerYear else { continue }

            var duplicateFilter = duplicateFilters[candidate.year] ?? MemoryDuplicateFilter()
            guard duplicateFilter.accepts(candidate.embedding) else { continue }
            duplicateFilters[candidate.year] = duplicateFilter
            acceptedCountsByYear[candidate.year, default: 0] += 1
            results.append((year: candidate.year, photo: candidate.photo))
        }
        return results
    }

    private static func fetchOnThisDayCandidates(in db: Database) throws -> [OnThisDayCandidate] {
        let calendar = Calendar.current
        let today = Date()
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, localIdentifier, creationDate, sourceId, filePath,
                       pixelWidth, pixelHeight, embedding
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
            """,
            arguments: [
                SearchIndexLimits.maximumPhotoRows,
                calendar.component(.month, from: today),
                calendar.component(.day, from: today),
                calendar.component(.year, from: today),
                MemoryConfig.maximumOnThisDayYears
                    * MemoryConfig.maximumOnThisDayPhotosPerYear,
            ]
        )
        var candidates: [OnThisDayCandidate] = []
        candidates.reserveCapacity(
            MemoryConfig.maximumOnThisDayYears * MemoryConfig.maximumOnThisDayPhotosPerYear
        )

        while let row = try cursor.next() {
            if Task.isCancelled { throw CancellationError() }
            guard let date: Date = row["creationDate"] else { continue }
            let year = calendar.component(.year, from: date)
            candidates.append(OnThisDayCandidate(
                year: year,
                photo: IndexedPhotoReference(
                    id: row["id"],
                    localIdentifier: row["localIdentifier"],
                    creationDate: date,
                    sourceId: row["sourceId"],
                    filePath: row["filePath"],
                    pixelWidth: row["pixelWidth"],
                    pixelHeight: row["pixelHeight"]
                ),
                embedding: row["embedding"]
            ))
        }
        return candidates
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
            // Keep only the bounded recent-history window.
            try db.execute(sql: """
                DELETE FROM search_history WHERE id NOT IN (
                    SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT ?
                )
            """, arguments: [SearchHistoryPolicy.maximumCount])
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
            try String.fetchAll(
                db,
                sql: "SELECT query FROM search_history ORDER BY searchedAt DESC LIMIT ?",
                arguments: [SearchHistoryPolicy.maximumCount]
            )
        }
    }

    func loadSearchHistoryPreviews(limit: Int) throws -> [RecentSearchPreview] {
        let boundedLimit = max(0, min(limit, SearchHistoryPolicy.maximumCount))
        guard boundedLimit > 0 else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT query, searchedAt, previewResultID, previewScore, previewLocalIdentifier,
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
                    resultCount: resultCount ?? 0,
                    searchedAt: row["searchedAt"]
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
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT ?",
                arguments: [SearchHistoryPolicy.maximumCount]
            )
            guard rows.indices.contains(index) else { return }
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
