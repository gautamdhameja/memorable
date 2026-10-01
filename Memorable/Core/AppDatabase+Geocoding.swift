import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Location Backfill

    func photosNeedingLocationBackfill(
        after localIdentifier: String? = nil,
        limit: Int = 500
    ) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        let now = Date()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_photos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
                AND (locationCity IS NULL OR locationCity = '')
                AND (locationRetryAfter IS NULL OR locationRetryAfter <= ?)
                AND (? IS NULL OR localIdentifier > ?)
                ORDER BY localIdentifier
                LIMIT ?
            """, arguments: [now, localIdentifier, localIdentifier, limit])
            return rows.map { (
                $0["localIdentifier"] as String,
                $0["latitude"] as Double,
                $0["longitude"] as Double
            ) }
        }
    }

    func videosNeedingLocationBackfill(
        after localIdentifier: String? = nil,
        limit: Int = 500
    ) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        let now = Date()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_videos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
                AND (locationCity IS NULL OR locationCity = '')
                AND (locationRetryAfter IS NULL OR locationRetryAfter <= ?)
                AND (? IS NULL OR localIdentifier > ?)
                ORDER BY localIdentifier
                LIMIT ?
            """, arguments: [now, localIdentifier, localIdentifier, limit])
            return rows.map { (
                $0["localIdentifier"] as String,
                $0["latitude"] as Double,
                $0["longitude"] as Double
            ) }
        }
    }

    func geocodingCounts() throws -> GeocodingCounts {
        let now = Date()
        return try dbQueue.read { db in
            let photoCounts = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS indexed,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                THEN 1 ELSE 0 END) AS withGPS,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                     AND (locationCity IS NULL OR locationCity = '')
                                     AND (locationRetryAfter IS NULL OR locationRetryAfter <= :now)
                                THEN 1 ELSE 0 END) AS remaining
                FROM indexed_photos
            """, arguments: ["now": now])
            let videoCounts = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS indexed,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                THEN 1 ELSE 0 END) AS withGPS,
                       SUM(CASE WHEN latitude BETWEEN -90 AND 90
                                     AND longitude BETWEEN -180 AND 180
                                     AND (locationCity IS NULL OR locationCity = '')
                                     AND (locationRetryAfter IS NULL OR locationRetryAfter <= :now)
                                THEN 1 ELSE 0 END) AS remaining
                FROM indexed_videos
            """, arguments: ["now": now])
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

    func reverseGeocodeLocation(bucketKey: String) throws -> LocationStrings? {
        let cutoff = Date(timeIntervalSinceNow: -ReverseGeocodeCachePolicy.maximumAgeSeconds)
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT city, state, country, name
                    FROM reverse_geocode_cache
                    WHERE bucketKey = ? AND resolvedAt >= ?
                """,
                arguments: [bucketKey, cutoff]
            ) else { return nil }
            return LocationStrings(
                city: row["city"],
                state: row["state"],
                country: row["country"],
                name: row["name"]
            )
        }
    }

    func reverseGeocodeLocations(bucketKeys: [String]) throws -> [String: LocationStrings] {
        guard !bucketKeys.isEmpty else { return [:] }
        let cutoff = Date(timeIntervalSinceNow: -ReverseGeocodeCachePolicy.maximumAgeSeconds)
        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: bucketKeys.count).joined(separator: ",")
            var arguments = StatementArguments(bucketKeys)
            arguments += [cutoff]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT bucketKey, city, state, country, name
                    FROM reverse_geocode_cache
                    WHERE bucketKey IN (\(placeholders)) AND resolvedAt >= ?
                """,
                arguments: arguments
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let bucketKey: String = row["bucketKey"]
                return (
                    bucketKey,
                    LocationStrings(
                        city: row["city"],
                        state: row["state"],
                        country: row["country"],
                        name: row["name"]
                    )
                )
            })
        }
    }

    func saveReverseGeocodeLocation(_ location: LocationStrings, bucketKey: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reverse_geocode_cache (
                        bucketKey, city, state, country, name, resolvedAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(bucketKey) DO UPDATE SET
                        city = excluded.city,
                        state = excluded.state,
                        country = excluded.country,
                        name = excluded.name,
                        resolvedAt = excluded.resolvedAt
                """,
                arguments: [
                    bucketKey,
                    PersistedMetadataTextPolicy.bounded(location.city, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(location.state, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(location.country, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(location.name, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    Date()
                ]
            )
        }
    }

    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?,
                                    country: String?, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_photos
                    SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?,
                        locationRetryAfter = NULL
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
                    SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?,
                        locationRetryAfter = NULL
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

    func deferPhotoLocationBackfill(localIdentifiers: [String], until: Date) throws {
        try deferLocationBackfill(localIdentifiers: localIdentifiers, until: until, table: .photos)
    }

    func deferVideoLocationBackfill(localIdentifiers: [String], until: Date) throws {
        try deferLocationBackfill(localIdentifiers: localIdentifiers, until: until, table: .videos)
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
                        SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?,
                            locationRetryAfter = NULL
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


    private func deferLocationBackfill(
        localIdentifiers: [String],
        until: Date,
        table: LocationUpdateTable
    ) throws {
        guard !localIdentifiers.isEmpty else { return }
        try dbQueue.write { db in
            for localIdentifier in localIdentifiers {
                try Task.checkCancellation()
                try db.execute(
                    sql: "UPDATE \(table.name) SET locationRetryAfter = ? WHERE localIdentifier = ?",
                    arguments: [until, localIdentifier]
                )
            }
        }
    }
}
