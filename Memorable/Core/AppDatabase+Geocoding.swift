import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Location Backfill

    func photosNeedingLocationBackfill(limit: Int = 500) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_photos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
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
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
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

    func geocodingCounts() throws -> GeocodingCounts {
        try dbQueue.read { db in
            let photoCounts = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS indexed,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                THEN 1 ELSE 0 END) AS withGPS,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                     AND (locationCity IS NULL OR locationCity = '')
                                THEN 1 ELSE 0 END) AS remaining
                FROM indexed_photos
            """)
            let videoCounts = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS indexed,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                THEN 1 ELSE 0 END) AS withGPS,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                     AND (locationCity IS NULL OR locationCity = '')
                                THEN 1 ELSE 0 END) AS remaining
                FROM indexed_videos
            """)
            return GeocodingCounts(
                totalWithGPS: (photoCounts?["withGPS"] as Int? ?? 0)
                    + (videoCounts?["withGPS"] as Int? ?? 0),
                remaining: (photoCounts?["remaining"] as Int? ?? 0)
                    + (videoCounts?["remaining"] as Int? ?? 0),
                indexedPhotos: photoCounts?["indexed"] as Int? ?? 0,
                indexedVideos: videoCounts?["indexed"] as Int? ?? 0
            )
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
                arguments: [
                    PersistedMetadataTextPolicy.bounded(city, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(state, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(country, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(name, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    localIdentifier
                ]
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
                arguments: [
                    PersistedMetadataTextPolicy.bounded(city, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(state, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(country, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(name, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    localIdentifier
                ]
            )
        }
    }

    func updatePhotoLocations(_ updates: [LocationBackfillUpdate]) throws {
        try updateLocations(updates, table: .photos)
    }

    func updateVideoLocations(_ updates: [LocationBackfillUpdate]) throws {
        try updateLocations(updates, table: .videos)
    }

    private enum LocationUpdateTable {
        case photos
        case videos

        var name: String {
            switch self {
            case .photos: "indexed_photos"
            case .videos: "indexed_videos"
            }
        }
    }

    private func updateLocations(
        _ updates: [LocationBackfillUpdate],
        table: LocationUpdateTable
    ) throws {
        guard !updates.isEmpty else { return }
        try dbQueue.write { db in
            for update in updates {
                try Task.checkCancellation()
                try db.execute(
                    sql: """
                        UPDATE \(table.name)
                        SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?
                        WHERE localIdentifier = ?
                    """,
                    arguments: [
                        PersistedMetadataTextPolicy.bounded(update.location.city, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                        PersistedMetadataTextPolicy.bounded(update.location.state, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                        PersistedMetadataTextPolicy.bounded(update.location.country, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                        PersistedMetadataTextPolicy.bounded(update.location.name, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                        update.localIdentifier
                    ]
                )
            }
        }
    }
}
