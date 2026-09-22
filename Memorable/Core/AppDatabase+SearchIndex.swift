import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Search Index Reads


    func allIndexedIdentifiers() throws -> Set<String> {
        try dbQueue.read { db in
            try Self.loadIdentifierSet(
                db,
                sql: """
                    SELECT localIdentifier FROM indexed_photos
                    WHERE sourceId = ?
                    ORDER BY creationDate DESC, id ASC
                    LIMIT ?
                """,
                arguments: [PhotoSourceType.photokit.rawValue],
                limit: SearchIndexLimits.maximumPhotoRows
            )
        }
    }

    func loadIndexedPhotoIdentifierPage(after: String?, limit: Int) throws -> [String] {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.databasePageMediaItems))
        guard boundedLimit > 0 else { return [] }
        return try dbQueue.read { db in
            if let after {
                return try String.fetchAll(
                    db,
                    sql: """
                        SELECT localIdentifier FROM indexed_photos
                        WHERE sourceId = ? AND localIdentifier > ?
                        ORDER BY localIdentifier ASC
                        LIMIT ?
                    """,
                    arguments: [PhotoSourceType.photokit.rawValue, after, boundedLimit]
                )
            }
            return try String.fetchAll(
                db,
                sql: """
                    SELECT localIdentifier FROM indexed_photos
                    WHERE sourceId = ?
                    ORDER BY localIdentifier ASC
                    LIMIT ?
                """,
                arguments: [PhotoSourceType.photokit.rawValue, boundedLimit]
            )
        }
    }

    func loadAllVideoEmbeddings() throws -> MediaIndex {
        try loadVideoEmbeddings(limit: SearchIndexLimits.maximumVideoFrameRows)
    }

    func loadVideoEmbeddings(
        limit: Int,
        mediaLimit: Int = SearchIndexLimits.maximumMediaItems
    ) throws -> MediaIndex {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumVideoFrameRows))
        let boundedMediaLimit = max(0, min(mediaLimit, SearchIndexLimits.maximumMediaItems))
        guard boundedLimit > 0, boundedMediaLimit > 0 else { return MediaIndex(kind: .videoFrame) }
        return try dbQueue.read { db in
            let sql = """
                WITH selected_media AS (
                    SELECT mediaType, id FROM (
                        SELECT 'photo' AS mediaType, id, creationDate FROM indexed_photos
                        UNION ALL
                        SELECT 'video' AS mediaType, id, creationDate FROM indexed_videos
                    )
                    ORDER BY creationDate DESC, id ASC, mediaType ASC
                    LIMIT ?
                )
                SELECT v.id, v.localIdentifier, v.sourceId, v.creationDate, v.latitude, v.longitude,
                       substr(v.locationCity, 1, 256) AS locationCity,
                       substr(v.locationState, 1, 256) AS locationState,
                       substr(v.locationCountry, 1, 256) AS locationCountry,
                       substr(v.locationName, 1, 256) AS locationName,
                       v.pixelWidth, v.pixelHeight,
                       f.framePosition,
                       CASE WHEN length(f.embedding) = ? THEN f.embedding END AS embedding
                FROM indexed_video_frames f
                JOIN indexed_videos v ON f.videoId = v.id
                JOIN selected_media s ON s.mediaType = 'video' AND s.id = v.id
                ORDER BY v.creationDate DESC, v.id ASC, f.framePosition ASC, f.id ASC
            """
            var index = MediaIndex(kind: .videoFrame)
            index.reserveCapacity(boundedLimit)
            let cursor = try Row.fetchCursor(
                db,
                sql: sql + "\nLIMIT ?",
                arguments: [
                    boundedMediaLimit,
                    EmbeddingConfig.bytesPerEmbedding,
                    boundedLimit,
                ]
            )

            var rowNumber = 0
            while let row = try cursor.next() {
                if rowNumber.isMultiple(of: 64) { try Task.checkCancellation() }
                guard let embeddingData: Data = row["embedding"] else {
                    throw SearchEngineError.corruptedIndex
                }
                let indexRow = MediaIndex.Row(
                    id: row["id"],
                    localIdentifier: row["localIdentifier"],
                    sourceId: row["sourceId"],
                    filePath: nil,
                    date: row["creationDate"],
                    latitude: row["latitude"],
                    longitude: row["longitude"],
                    city: row["locationCity"],
                    state: row["locationState"],
                    country: row["locationCountry"],
                    locationName: row["locationName"],
                    pixelWidth: row["pixelWidth"] ?? 0,
                    pixelHeight: row["pixelHeight"] ?? 0,
                    details: .videoFrame(position: row["framePosition"])
                )
                guard let embedding = embeddingData.validatedFloat16Embedding() else {
                    throw SearchEngineError.corruptedIndex
                }
                try index.append(indexRow, embedding: embedding)
                rowNumber += 1
            }

            return index
        }
    }

    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers {
        try loadIndexedMediaIdentifiers(limit: SearchIndexLimits.maximumMediaItems)
    }

    func loadIndexedMediaIdentifierPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> IndexedMediaIdentifierPage {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.databasePageMediaItems))
        guard boundedLimit > 0 else {
            return IndexedMediaIdentifierPage(photos: [], videos: [], nextCursor: nil)
        }
        return try dbQueue.read { db in
            let fetchLimit = boundedLimit + 1
            let photoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .photo,
                includesLocalIdentifier: true,
                sourceID: PhotoSourceType.photokit.rawValue,
                after: cursor,
                limit: fetchLimit
            )
            let videoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .video,
                includesLocalIdentifier: true,
                sourceID: PhotoSourceType.photokit.rawValue,
                after: cursor,
                limit: fetchLimit
            )
            let descriptors = try Self.mergeMediaPageDescriptors(
                photoDescriptors,
                videoDescriptors,
                limit: fetchLimit
            )
            let hasMore = descriptors.count > boundedLimit
            let selected = Array(descriptors.prefix(boundedLimit))
            let nextCursor = hasMore ? selected.last.map {
                SearchMediaPageCursor(
                    creationDate: $0.creationDate,
                    id: $0.id,
                    mediaType: $0.mediaType
                )
            } : nil
            return IndexedMediaIdentifierPage(
                photos: selected.filter { $0.mediaType == .photo }.compactMap(\.localIdentifier),
                videos: selected.filter { $0.mediaType == .video }.compactMap(\.localIdentifier),
                nextCursor: nextCursor
            )
        }
    }

    func loadIndexedMediaIdentifiers(limit: Int) throws -> IndexedMediaIdentifiers {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumMediaItems))
        guard boundedLimit > 0 else {
            return IndexedMediaIdentifiers(photos: [], videos: [])
        }
        return try dbQueue.read { db in
            var photos = Set<String>(minimumCapacity: boundedLimit)
            var videos = Set<String>(minimumCapacity: boundedLimit)
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT mediaType, localIdentifier FROM (
                        SELECT 'photo' AS mediaType, localIdentifier, creationDate, id
                        FROM indexed_photos
                        WHERE sourceId = ?
                        UNION ALL
                        SELECT 'video' AS mediaType, localIdentifier, creationDate, id
                        FROM indexed_videos
                        WHERE sourceId = ?
                    )
                    ORDER BY creationDate DESC, id ASC, mediaType ASC
                    LIMIT ?
                """,
                arguments: [
                    PhotoSourceType.photokit.rawValue,
                    PhotoSourceType.photokit.rawValue,
                    boundedLimit,
                ]
            )
            var rowNumber = 0
            while let row = try cursor.next() {
                if rowNumber.isMultiple(of: 256) { try Task.checkCancellation() }
                let identifier: String = row["localIdentifier"]
                let mediaType: String = row["mediaType"]
                if mediaType == "photo" {
                    photos.insert(identifier)
                } else {
                    videos.insert(identifier)
                }
                rowNumber += 1
            }
            return IndexedMediaIdentifiers(photos: photos, videos: videos)
        }
    }

    private static func loadIdentifierSet(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = [],
        limit: Int
    ) throws -> Set<String> {
        guard limit > 0 else { return [] }
        var identifiers = Set<String>(minimumCapacity: limit)
        var resolvedArguments = arguments
        resolvedArguments += [limit]
        let cursor = try String.fetchCursor(db, sql: sql, arguments: resolvedArguments)
        var row = 0
        while let identifier = try cursor.next() {
            if row.isMultiple(of: 256) { try Task.checkCancellation() }
            identifiers.insert(identifier)
            row += 1
        }
        return identifiers
    }

    func loadAllEmbeddings() throws -> MediaIndex {
        try loadPhotoEmbeddings(limit: SearchIndexLimits.maximumPhotoRows)
    }

    func loadSearchMediaPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> SearchMediaPage {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumResidentMediaItems))
        guard boundedLimit > 0 else {
            return SearchMediaPage(
                photos: MediaIndex(kind: .photo),
                videos: MediaIndex(kind: .videoFrame),
                mediaCount: 0,
                totalPhotoCount: cursor == nil ? try indexedCount() : 0,
                totalVideoCount: cursor == nil ? try videoIndexedCount() : 0,
                nextCursor: nil
            )
        }

        return try dbQueue.read { db in
            // Persisted totals initialize the resident snapshot. Continuation
            // pages do not consume them, so avoid two full COUNT queries on
            // every bounded page scan.
            let totalPhotoCount = cursor == nil ? try IndexedPhoto.fetchCount(db) : 0
            let totalVideoCount = cursor == nil ? try IndexedVideo.fetchCount(db) : 0

            let fetchLimit = boundedLimit + 1
            let photoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .photo,
                includesLocalIdentifier: false,
                sourceID: nil,
                after: cursor,
                limit: fetchLimit
            )
            let videoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .video,
                includesLocalIdentifier: false,
                sourceID: nil,
                after: cursor,
                limit: fetchLimit
            )
            let descriptors = try Self.mergeMediaPageDescriptors(
                photoDescriptors,
                videoDescriptors,
                limit: fetchLimit
            )

            let hasMore = descriptors.count > boundedLimit
            let selected = Array(descriptors.prefix(boundedLimit))
            let photoIDs = selected.filter { $0.mediaType == .photo }.map(\.id)
            let videoIDs = selected.filter { $0.mediaType == .video }.map(\.id)
            let photos = try Self.loadPhotoRows(in: db, ids: photoIDs)
            let videos = try Self.loadVideoRows(in: db, ids: videoIDs)
            let nextCursor = hasMore ? selected.last.map {
                SearchMediaPageCursor(
                    creationDate: $0.creationDate,
                    id: $0.id,
                    mediaType: $0.mediaType
                )
            } : nil
            return SearchMediaPage(
                photos: photos,
                videos: videos,
                mediaCount: selected.count,
                totalPhotoCount: totalPhotoCount,
                totalVideoCount: totalVideoCount,
                nextCursor: nextCursor
            )
        }
    }

    static func mediaPageDescriptorQuery(
        mediaType: SearchMediaPageKind,
        includesLocalIdentifier: Bool,
        sourceID: String?,
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) -> MediaPageDescriptorQuery {
        let table: String
        switch mediaType {
        case .photo:
            table = "indexed_photos"
        case .video:
            table = "indexed_videos"
        }
        let columns = includesLocalIdentifier
            ? "id, localIdentifier, creationDate"
            : "id, creationDate"
        var sql = "SELECT \(columns) FROM \(table)"
        var predicates: [String] = []
        var arguments = StatementArguments()
        if let sourceID {
            predicates.append("sourceId = ?")
            arguments += [sourceID]
        }
        if let cursor {
            let idOperator = mediaType.rawValue > cursor.mediaType.rawValue ? ">=" : ">"
            if let creationDate = cursor.creationDate {
                predicates.append(
                    "(creationDate < ? OR creationDate IS NULL OR (creationDate = ? AND id \(idOperator) ?))"
                )
                arguments += [creationDate, creationDate, cursor.id]
            } else {
                predicates.append("creationDate IS NULL AND id \(idOperator) ?")
                arguments += [cursor.id]
            }
        }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }
        sql += " ORDER BY creationDate DESC, id ASC LIMIT ?"
        arguments += [limit]
        return MediaPageDescriptorQuery(sql: sql, arguments: arguments)
    }

    private struct MediaPageDescriptor {
        let mediaType: SearchMediaPageKind
        let id: String
        let localIdentifier: String?
        let creationDate: Date?
    }

    private static func loadMediaPageDescriptors(
        in db: Database,
        mediaType: SearchMediaPageKind,
        includesLocalIdentifier: Bool,
        sourceID: String?,
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> [MediaPageDescriptor] {
        let query = mediaPageDescriptorQuery(
            mediaType: mediaType,
            includesLocalIdentifier: includesLocalIdentifier,
            sourceID: sourceID,
            after: cursor,
            limit: limit
        )
        var descriptors: [MediaPageDescriptor] = []
        descriptors.reserveCapacity(limit)
        let rows = try Row.fetchCursor(db, sql: query.sql, arguments: query.arguments)
        while let row = try rows.next() {
            try SearchCancellation.check(descriptors.count)
            descriptors.append(MediaPageDescriptor(
                mediaType: mediaType,
                id: row["id"],
                localIdentifier: includesLocalIdentifier ? row["localIdentifier"] : nil,
                creationDate: row["creationDate"]
            ))
        }
        return descriptors
    }

    private static func mergeMediaPageDescriptors(
        _ photos: [MediaPageDescriptor],
        _ videos: [MediaPageDescriptor],
        limit: Int
    ) throws -> [MediaPageDescriptor] {
        var result: [MediaPageDescriptor] = []
        result.reserveCapacity(limit)
        var photoIndex = 0
        var videoIndex = 0
        while result.count < limit,
              photoIndex < photos.count || videoIndex < videos.count {
            try SearchCancellation.check(result.count)
            if photoIndex >= photos.count {
                result.append(videos[videoIndex])
                videoIndex += 1
            } else if videoIndex >= videos.count
                        || mediaPageDescriptorPrecedes(photos[photoIndex], videos[videoIndex]) {
                result.append(photos[photoIndex])
                photoIndex += 1
            } else {
                result.append(videos[videoIndex])
                videoIndex += 1
            }
        }
        return result
    }

    private static func mediaPageDescriptorPrecedes(
        _ lhs: MediaPageDescriptor,
        _ rhs: MediaPageDescriptor
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.mediaType.rawValue < rhs.mediaType.rawValue
        }
    }

    func loadPhotoEmbedding(id: String) throws -> MediaIndex? {
        try dbQueue.read { db in
            let index = try Self.loadPhotoRows(in: db, ids: [id])
            return index.count == 0 ? nil : index
        }
    }

    private static func loadPhotoRows(in db: Database, ids: [String]) throws -> MediaIndex {
        guard !ids.isEmpty else { return MediaIndex(kind: .photo) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var arguments = StatementArguments([EmbeddingConfig.bytesPerEmbedding])
        arguments += StatementArguments(ids)
        var index = MediaIndex(kind: .photo)
        index.reserveCapacity(ids.count)
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, localIdentifier, sourceId, filePath, creationDate,
                       latitude, longitude,
                       substr(locationCity, 1, 256) AS locationCity,
                       substr(locationState, 1, 256) AS locationState,
                       substr(locationCountry, 1, 256) AS locationCountry,
                       substr(locationName, 1, 256) AS locationName,
                       substr(ocrText, 1, 4096) AS ocrText,
                       substr(sceneLabels, 1, 1024) AS sceneLabels,
                       pixelWidth, pixelHeight,
                       CASE WHEN length(embedding) = ? THEN embedding END AS embedding
                FROM indexed_photos
                WHERE id IN (\(placeholders))
                ORDER BY creationDate DESC, id ASC
            """,
            arguments: arguments
        )
        var rowNumber = 0
        while let row = try cursor.next() {
            try SearchCancellation.check(rowNumber)
            guard let data: Data = row["embedding"],
                  let embedding = data.validatedFloat16Embedding() else {
                throw SearchEngineError.corruptedIndex
            }
            try index.append(
                MediaIndex.Row(
                    id: row["id"], localIdentifier: row["localIdentifier"],
                    sourceId: row["sourceId"], filePath: row["filePath"],
                    date: row["creationDate"], latitude: row["latitude"],
                    longitude: row["longitude"], city: row["locationCity"],
                    state: row["locationState"], country: row["locationCountry"],
                    locationName: row["locationName"],
                    pixelWidth: row["pixelWidth"] ?? 0,
                    pixelHeight: row["pixelHeight"] ?? 0,
                    details: .photo(ocrText: row["ocrText"], sceneLabels: row["sceneLabels"])
                ),
                embedding: embedding
            )
            rowNumber += 1
        }
        return index
    }

    private static func loadVideoRows(in db: Database, ids: [String]) throws -> MediaIndex {
        guard !ids.isEmpty else { return MediaIndex(kind: .videoFrame) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let invalidVideoID = try String.fetchOne(
            db,
            sql: """
                SELECT v.id
                FROM indexed_videos v
                LEFT JOIN indexed_video_frames f ON f.videoId = v.id
                WHERE v.id IN (\(placeholders))
                GROUP BY v.id
                HAVING COUNT(f.id) < 1 OR COUNT(f.id) > ?
                LIMIT 1
            """,
            arguments: StatementArguments(ids)
                + [SearchIndexLimits.maximumVideoFramesPerMedia]
        )
        guard invalidVideoID == nil else {
            throw SearchEngineError.corruptedIndex
        }
        var arguments = StatementArguments([EmbeddingConfig.bytesPerEmbedding])
        arguments += StatementArguments(ids)
        var index = MediaIndex(kind: .videoFrame)
        index.reserveCapacity(ids.count * SearchIndexLimits.maximumVideoFramesPerMedia)
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT v.id, v.localIdentifier, v.sourceId, v.creationDate,
                       v.latitude, v.longitude,
                       substr(v.locationCity, 1, 256) AS locationCity,
                       substr(v.locationState, 1, 256) AS locationState,
                       substr(v.locationCountry, 1, 256) AS locationCountry,
                       substr(v.locationName, 1, 256) AS locationName,
                       v.pixelWidth, v.pixelHeight,
                       f.framePosition,
                       CASE WHEN length(f.embedding) = ? THEN f.embedding END AS embedding
                FROM indexed_video_frames f
                JOIN indexed_videos v ON f.videoId = v.id
                WHERE v.id IN (\(placeholders))
                ORDER BY v.creationDate DESC, v.id ASC, f.framePosition ASC, f.id ASC
            """,
            arguments: arguments
        )
        var rowNumber = 0
        while let row = try cursor.next() {
            try SearchCancellation.check(rowNumber)
            guard let data: Data = row["embedding"],
                  let embedding = data.validatedFloat16Embedding() else {
                throw SearchEngineError.corruptedIndex
            }
            try index.append(
                MediaIndex.Row(
                    id: row["id"], localIdentifier: row["localIdentifier"],
                    sourceId: row["sourceId"], filePath: nil,
                    date: row["creationDate"], latitude: row["latitude"],
                    longitude: row["longitude"], city: row["locationCity"],
                    state: row["locationState"], country: row["locationCountry"],
                    locationName: row["locationName"],
                    pixelWidth: row["pixelWidth"] ?? 0,
                    pixelHeight: row["pixelHeight"] ?? 0,
                    details: .videoFrame(position: row["framePosition"])
                ),
                embedding: embedding
            )
            rowNumber += 1
        }
        return index
    }

    func loadPhotoEmbeddings(
        limit: Int,
        mediaLimit: Int = SearchIndexLimits.maximumMediaItems
    ) throws -> MediaIndex {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumPhotoRows))
        let boundedMediaLimit = max(0, min(mediaLimit, SearchIndexLimits.maximumMediaItems))
        guard boundedLimit > 0, boundedMediaLimit > 0 else { return MediaIndex(kind: .photo) }
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif
        let result = try dbQueue.read { db in
            var index = MediaIndex(kind: .photo)
            index.reserveCapacity(boundedLimit)

            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    WITH selected_media AS (
                        SELECT mediaType, id FROM (
                            SELECT 'photo' AS mediaType, id, creationDate FROM indexed_photos
                            UNION ALL
                            SELECT 'video' AS mediaType, id, creationDate FROM indexed_videos
                        )
                        ORDER BY creationDate DESC, id ASC, mediaType ASC
                        LIMIT ?
                    )
                    SELECT p.id, p.localIdentifier, p.sourceId, p.filePath, p.creationDate,
                           p.latitude, p.longitude,
                           substr(p.locationCity, 1, 256) AS locationCity,
                           substr(p.locationState, 1, 256) AS locationState,
                           substr(p.locationCountry, 1, 256) AS locationCountry,
                           substr(p.locationName, 1, 256) AS locationName,
                           substr(p.ocrText, 1, 4096) AS ocrText,
                           substr(p.sceneLabels, 1, 1024) AS sceneLabels,
                           p.pixelWidth, p.pixelHeight,
                           CASE WHEN length(p.embedding) = ? THEN p.embedding END AS embedding
                    FROM indexed_photos p
                    JOIN selected_media s ON s.mediaType = 'photo' AND s.id = p.id
                    ORDER BY p.creationDate DESC, p.id ASC
                    LIMIT ?
                """,
                arguments: [boundedMediaLimit, EmbeddingConfig.bytesPerEmbedding, boundedLimit]
            )

            var rowNumber = 0
            while let photo = try cursor.next() {
                if rowNumber.isMultiple(of: 64) { try Task.checkCancellation() }
                guard let embeddingData: Data = photo["embedding"] else {
                    throw SearchEngineError.corruptedIndex
                }
                let row = MediaIndex.Row(
                    id: photo["id"],
                    localIdentifier: photo["localIdentifier"],
                    sourceId: photo["sourceId"],
                    filePath: photo["filePath"],
                    date: photo["creationDate"],
                    latitude: photo["latitude"],
                    longitude: photo["longitude"],
                    city: photo["locationCity"],
                    state: photo["locationState"],
                    country: photo["locationCountry"],
                    locationName: photo["locationName"],
                    pixelWidth: photo["pixelWidth"] ?? 0,
                    pixelHeight: photo["pixelHeight"] ?? 0,
                    details: .photo(
                        ocrText: photo["ocrText"],
                        sceneLabels: photo["sceneLabels"]
                    )
                )
                guard let embedding = embeddingData.validatedFloat16Embedding() else {
                    throw SearchEngineError.corruptedIndex
                }
                try index.append(row, embedding: embedding)
                rowNumber += 1
            }

            return index
        }

        #if DEBUG
        logger.info("[Database] Loaded \(result.ids.count) photo embeddings in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart))s")
        #endif

        return result
    }

    func loadEmbeddingsForDuplicateScan(limit: Int) throws -> MediaIndex {
        let boundedLimit = max(0, min(limit, IndexingConfig.maxDuplicateScanPhotos))
        guard boundedLimit > 0 else { return MediaIndex(kind: .photo) }

        return try dbQueue.read { db in
            var index = MediaIndex(kind: .photo)
            index.reserveCapacity(boundedLimit)
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, localIdentifier, sourceId, filePath, creationDate,
                           latitude, longitude,
                           substr(locationCity, 1, 256) AS locationCity,
                           substr(locationState, 1, 256) AS locationState,
                           substr(locationCountry, 1, 256) AS locationCountry,
                           substr(locationName, 1, 256) AS locationName,
                           substr(ocrText, 1, 4096) AS ocrText,
                           substr(sceneLabels, 1, 1024) AS sceneLabels,
                           pixelWidth, pixelHeight,
                           CASE WHEN length(embedding) = ? THEN embedding END AS embedding
                    FROM indexed_photos
                    WHERE sourceId = ?
                    ORDER BY creationDate DESC, id ASC
                    LIMIT ?
                    """,
                arguments: [
                    EmbeddingConfig.bytesPerEmbedding,
                    PhotoSourceType.photokit.rawValue,
                    boundedLimit,
                ]
            )

            while let photo = try cursor.next() {
                try Task.checkCancellation()
                guard let embeddingData: Data = photo["embedding"] else {
                    throw SearchEngineError.corruptedIndex
                }
                guard let embedding = embeddingData.validatedFloat16Embedding() else {
                    throw SearchEngineError.corruptedIndex
                }
                try index.append(
                    MediaIndex.Row(
                        id: photo["id"],
                        localIdentifier: photo["localIdentifier"],
                        sourceId: photo["sourceId"],
                        filePath: photo["filePath"],
                        date: photo["creationDate"],
                        latitude: photo["latitude"],
                        longitude: photo["longitude"],
                        city: photo["locationCity"],
                        state: photo["locationState"],
                        country: photo["locationCountry"],
                        locationName: photo["locationName"],
                        pixelWidth: photo["pixelWidth"] ?? 0,
                        pixelHeight: photo["pixelHeight"] ?? 0,
                        details: .photo(
                            ocrText: photo["ocrText"],
                            sceneLabels: photo["sceneLabels"]
                        )
                    ),
                    embedding: embedding
                )
            }
            return index
        }
    }
}
