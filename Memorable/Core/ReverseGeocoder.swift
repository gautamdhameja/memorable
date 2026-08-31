import CoreLocation

enum LocationCoordinatePolicy {
    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite
            && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    static func isValidOrAbsent(latitude: Double?, longitude: Double?) -> Bool {
        switch (latitude, longitude) {
        case (nil, nil):
            return true
        case let (latitude?, longitude?):
            return isValid(latitude: latitude, longitude: longitude)
        default:
            return false
        }
    }
}

struct LocationStrings: Sendable {
    let city: String?       // locality
    let state: String?      // administrativeArea
    let country: String?    // country
    let name: String?       // subLocality, or locality if no subLocality
}

@MainActor
protocol LocationGeocoding: AnyObject, Sendable {
    func reverseGeocode(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> [CLPlacemark]
    func cancel()
}

@MainActor
private final class AppleLocationGeocoder: LocationGeocoding, @unchecked Sendable {
    private let geocoder = CLGeocoder()

    func reverseGeocode(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> [CLPlacemark] {
        try await geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: preferredLocale
        )
    }

    func cancel() {
        geocoder.cancelGeocode()
    }
}

actor ReverseGeocoder {
    private let geocoder: any LocationGeocoding
    private let throttleNanoseconds: UInt64

    // Cache keyed by coordinates rounded to ~1km grid (2 decimal places).
    // Photos taken at the same venue will share a cache entry.
    nonisolated static let cacheEntryLimit = 2_048
    private var cache: [String: LocationStrings] = [:]
    private var cacheSlots: [String] = []
    private var nextCacheSlot = 0

    // Apple rate-limits CLGeocoder to 50 requests per 60 seconds.
    // 2s between API calls stays safely under that limit with margin for jitter.
    private static let throttleNanoseconds: UInt64 = 2_000_000_000

    @MainActor
    init(
        geocoder: any LocationGeocoding = AppleLocationGeocoder(),
        throttleNanoseconds: UInt64 = ReverseGeocoder.throttleNanoseconds
    ) {
        self.geocoder = geocoder
        self.throttleNanoseconds = throttleNanoseconds
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> LocationStrings? {
        guard LocationCoordinatePolicy.isValid(
            latitude: latitude,
            longitude: longitude
        ) else {
            logger.error("[ReverseGeocoder] Rejected invalid coordinates")
            return nil
        }
        let key = "\(round(latitude * 100) / 100),\(round(longitude * 100) / 100)"
        if let cached = cache[key] {
            return cached
        }

        // Throttle only actual API calls, not cache hits. Cancellation must
        // stop before coordinates are submitted to the Apple service.
        do {
            try await Task.sleep(nanoseconds: throttleNanoseconds)
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("[ReverseGeocoder] Throttle failed: \(error.safeDiagnosticCode)")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await withTaskCancellationHandler {
                try await geocoder.reverseGeocode(
                    location,
                    preferredLocale: Locale(identifier: "en_US")
                )
            } onCancel: { [geocoder] in
                Task { @MainActor in geocoder.cancel() }
            }
            try Task.checkCancellation()
            guard let pm = placemarks.first else { return nil }
            // Always provide a non-nil city so the backfill query
            // doesn't re-process this coordinate. Fall back through hierarchy.
            let city = pm.locality
                ?? pm.subAdministrativeArea
                ?? pm.administrativeArea
                ?? pm.country
                ?? "Unknown"
            let result = LocationStrings(
                city: city,
                state: pm.administrativeArea,
                country: pm.country,
                name: pm.subLocality ?? pm.locality
            )
            insertIntoCache(result, forKey: key)
            return result
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("[ReverseGeocoder] Failed: \(error.safeDiagnosticCode)")
            return nil
        }
    }

    private func insertIntoCache(_ value: LocationStrings, forKey key: String) {
        if cache[key] != nil {
            cache[key] = value
            return
        }
        if cacheSlots.count < Self.cacheEntryLimit {
            cacheSlots.append(key)
        } else {
            let evictedKey = cacheSlots[nextCacheSlot]
            cache.removeValue(forKey: evictedKey)
            cacheSlots[nextCacheSlot] = key
            nextCacheSlot = (nextCacheSlot + 1) % Self.cacheEntryLimit
        }
        cache[key] = value
    }
}

struct LocationBackfillUpdate: Sendable {
    let localIdentifier: String
    let location: LocationStrings
}

struct GeocodingProgressSnapshot: Equatable, Sendable {
    let completed: Int
    let total: Int
}

struct GeocodingRunResult: Equatable, Sendable {
    let completed: Int
    let total: Int
    let wasCancelled: Bool

    var changedLocations: Bool { completed > 0 }
}

/// Owns the complete database/geocoder loop away from the main actor. Only the
/// throttled progress callback crosses back to UI isolation.
actor GeocodingWorker {
    typealias ProgressHandler = @MainActor @Sendable (GeocodingProgressSnapshot?) -> Void

    private enum MediaSource: String {
        case photos
        case videos
    }

    private struct SourceResult {
        let completed: Int
        let wasCancelled: Bool
    }

    private let database: DatabaseProtocol
    private let reverseGeocoder: ReverseGeocoder
    private let fetchBatchSize: Int
    private let writeBatchSize: Int

    init(
        database: DatabaseProtocol,
        reverseGeocoder: ReverseGeocoder,
        fetchBatchSize: Int = 500,
        writeBatchSize: Int = 32
    ) {
        self.database = database
        self.reverseGeocoder = reverseGeocoder
        self.fetchBatchSize = max(1, fetchBatchSize)
        self.writeBatchSize = max(1, writeBatchSize)
    }

    func run(progress: @escaping ProgressHandler) async -> GeocodingRunResult {
        let counts: GeocodingCounts
        do {
            try Task.checkCancellation()
            counts = try database.geocodingCounts()
        } catch is CancellationError {
            await progress(nil)
            return GeocodingRunResult(completed: 0, total: 0, wasCancelled: true)
        } catch {
            logger.error("[Geocoder] Failed to load geocoding counts: \(error.safeDiagnosticCode)")
            await progress(nil)
            return GeocodingRunResult(completed: 0, total: 0, wasCancelled: false)
        }

        let total = counts.totalWithGPS
        let remaining = counts.remaining
        let alreadyCompleted = max(0, total - remaining)
        if remaining > 0 {
            await progress(GeocodingProgressSnapshot(completed: alreadyCompleted, total: total))
        }

        #if DEBUG
        logger.info("[Geocoder] Starting off-main: \(remaining) / \(total) remaining")
        #endif

        let photos = await runSource(
            .photos,
            progressBase: alreadyCompleted,
            total: total,
            progress: progress
        )
        if photos.wasCancelled {
            await progress(nil)
            return GeocodingRunResult(completed: photos.completed, total: total, wasCancelled: true)
        }

        let videos = await runSource(
            .videos,
            progressBase: alreadyCompleted + photos.completed,
            total: total,
            progress: progress
        )
        let completed = photos.completed + videos.completed
        await progress(nil)

        #if DEBUG
        logger.info("[Geocoder] Completed off-main: \(completed) media items")
        #endif
        return GeocodingRunResult(
            completed: completed,
            total: total,
            wasCancelled: videos.wasCancelled
        )
    }

    private func runSource(
        _ source: MediaSource,
        progressBase: Int,
        total: Int,
        progress: @escaping ProgressHandler
    ) async -> SourceResult {
        var completed = 0
        var lastProgressPublication = Date()
        var failedIdentifiers = Set<String>()

        while !Task.isCancelled {
            let candidates: [(localIdentifier: String, lat: Double, lon: Double)]
            do {
                switch source {
                case .photos:
                    candidates = try database.photosNeedingLocationBackfill(limit: fetchBatchSize)
                case .videos:
                    candidates = try database.videosNeedingLocationBackfill(limit: fetchBatchSize)
                }
            } catch {
                logger.error("[Geocoder] Failed to fetch \(source.rawValue) batch: \(error.safeDiagnosticCode)")
                break
            }
            guard !candidates.isEmpty else { break }

            let actionable = candidates.filter {
                !failedIdentifiers.contains($0.localIdentifier)
            }
            guard !actionable.isEmpty else { break }

            var pendingUpdates: [LocationBackfillUpdate] = []
            pendingUpdates.reserveCapacity(writeBatchSize)
            for candidate in actionable {
                if Task.isCancelled {
                    return SourceResult(completed: completed, wasCancelled: true)
                }
                guard let location = await reverseGeocoder.reverseGeocode(
                    latitude: candidate.lat,
                    longitude: candidate.lon
                ) else {
                    if Task.isCancelled {
                        return SourceResult(completed: completed, wasCancelled: true)
                    }
                    failedIdentifiers.insert(candidate.localIdentifier)
                    continue
                }
                pendingUpdates.append(LocationBackfillUpdate(
                    localIdentifier: candidate.localIdentifier,
                    location: location
                ))

                if pendingUpdates.count >= writeBatchSize {
                    guard flush(
                        &pendingUpdates,
                        source: source,
                        completed: &completed,
                        failedIdentifiers: &failedIdentifiers
                    ) else { continue }
                    await publishProgressIfNeeded(
                        completed: progressBase + completed,
                        total: total,
                        lastPublication: &lastProgressPublication,
                        progress: progress
                    )
                }
            }

            if !pendingUpdates.isEmpty {
                _ = flush(
                    &pendingUpdates,
                    source: source,
                    completed: &completed,
                    failedIdentifiers: &failedIdentifiers
                )
                await publishProgressIfNeeded(
                    completed: progressBase + completed,
                    total: total,
                    lastPublication: &lastProgressPublication,
                    progress: progress
                )
            }
        }

        return SourceResult(completed: completed, wasCancelled: Task.isCancelled)
    }

    private func flush(
        _ updates: inout [LocationBackfillUpdate],
        source: MediaSource,
        completed: inout Int,
        failedIdentifiers: inout Set<String>
    ) -> Bool {
        guard !updates.isEmpty else { return true }
        let batch = updates
        updates.removeAll(keepingCapacity: true)
        do {
            try Task.checkCancellation()
            switch source {
            case .photos:
                try database.updatePhotoLocations(batch)
            case .videos:
                try database.updateVideoLocations(batch)
            }
            completed += batch.count
            return true
        } catch is CancellationError {
            return false
        } catch {
            failedIdentifiers.formUnion(batch.map(\.localIdentifier))
            logger.error("[Geocoder] Failed to write \(source.rawValue) batch: \(error.safeDiagnosticCode)")
            return false
        }
    }

    private func publishProgressIfNeeded(
        completed: Int,
        total: Int,
        lastPublication: inout Date,
        progress: @escaping ProgressHandler
    ) async {
        let now = Date()
        guard GeocodingProgressPublicationPolicy.shouldPublish(
            elapsed: now.timeIntervalSince(lastPublication)
        ) else { return }
        await progress(GeocodingProgressSnapshot(completed: completed, total: total))
        lastPublication = now
    }
}
