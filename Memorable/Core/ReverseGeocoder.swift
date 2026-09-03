import CoreLocation
import MapKit

enum LocationCoordinatePolicy {
    static func isValid(latitude: Double, longitude: Double) -> Bool {
        CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(
            latitude: latitude,
            longitude: longitude
        ))
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

enum LocationCoordinateBucket {
    private static let cellsPerDegree = 100.0

    static func key(latitude: Double, longitude: Double) -> String {
        let latitudeCell = Int(floor((latitude + 90) * cellsPerDegree))
        let longitudeCell = Int(floor((longitude + 180) * cellsPerDegree))
        return "v1:\(latitudeCell):\(longitudeCell)"
    }
}

@MainActor
protocol LocationGeocoding: AnyObject, Sendable {
    func resolve(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> LocationStrings?
    func cancel()
}

@MainActor
private final class AppleLocationGeocoder: LocationGeocoding {
    private let geocoder = CLGeocoder()
    private var mapKitRequest: AnyObject?

    func resolve(
        _ location: CLLocation,
        preferredLocale: Locale
    ) async throws -> LocationStrings? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                return nil
            }
            request.preferredLocale = preferredLocale
            mapKitRequest = request
            defer { mapKitRequest = nil }
            guard let item = try await request.mapItems.first else { return nil }
            let representations = item.addressRepresentations
            let city = representations?.cityName
                ?? item.name
                ?? representations?.regionName
                ?? "Unknown"
            return LocationStrings(
                city: city,
                state: nil,
                country: representations?.regionName,
                name: item.name ?? representations?.cityName
            )
        }

        let placemarks = try await geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: preferredLocale
        )
        guard let placemark = placemarks.first else { return nil }
        return LocationStrings(
            city: placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
                ?? placemark.country
                ?? "Unknown",
            state: placemark.administrativeArea,
            country: placemark.country,
            name: placemark.subLocality ?? placemark.locality
        )
    }

    func cancel() {
        geocoder.cancelGeocode()
        if #available(iOS 26.0, *) {
            (mapKitRequest as? MKReverseGeocodingRequest)?.cancel()
        }
        mapKitRequest = nil
    }
}

actor ReverseGeocoder {
    enum Outcome: Sendable {
        case resolved(LocationStrings)
        case noResult
        case transientFailure
        case cancelled
    }

    private struct RequestTimedOut: Error {}
    private struct ProviderBusy: Error {}

    private let geocoder: any LocationGeocoding
    private let throttleNanoseconds: UInt64
    private let requestTimeoutNanoseconds: UInt64
    private let providerRequestGate = LocationGeocoderRequestGate()

    // Cache keyed by coordinates grouped into ~1km grid cells.
    // Photos taken at the same venue will share a cache entry.
    nonisolated static let cacheEntryLimit = 2_048
    private var cache: [String: LocationStrings] = [:]
    private var cacheSlots: [String] = []
    private var nextCacheSlot = 0

    // A conservative delay avoids flooding Apple's geocoding services.
    private static let throttleNanoseconds: UInt64 = 2_000_000_000

    @MainActor
    init(
        geocoder: any LocationGeocoding = AppleLocationGeocoder(),
        throttleNanoseconds: UInt64 = ReverseGeocoder.throttleNanoseconds,
        requestTimeoutNanoseconds: UInt64 = UInt64(TimeoutConfig.reverseGeocoding * 1_000_000_000)
    ) {
        self.geocoder = geocoder
        self.throttleNanoseconds = throttleNanoseconds
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> Outcome {
        guard LocationCoordinatePolicy.isValid(
            latitude: latitude,
            longitude: longitude
        ) else {
            logger.error("[ReverseGeocoder] Rejected invalid coordinates")
            return .noResult
        }
        let key = LocationCoordinateBucket.key(latitude: latitude, longitude: longitude)
        if let cached = cache[key] {
            return .resolved(cached)
        }

        // Throttle only actual API calls, not cache hits. Cancellation must
        // stop before coordinates are submitted to the Apple service.
        do {
            try await Task.sleep(nanoseconds: throttleNanoseconds)
        } catch is CancellationError {
            return .cancelled
        } catch {
            logger.error("[ReverseGeocoder] Throttle failed: \(error.safeDiagnosticCode)")
            return .transientFailure
        }
        guard !Task.isCancelled else { return .cancelled }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let result = try await resolveWithTimeout(location)
            try Task.checkCancellation()
            guard let result else { return .noResult }
            insertIntoCache(result, forKey: key)
            return .resolved(result)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Self.isNoResultError(error) {
                return .noResult
            }
            logger.error("[ReverseGeocoder] Failed: \(error.safeDiagnosticCode)")
            return .transientFailure
        }
    }

    private static func isNoResultError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.Code.geocodeFoundNoResult.rawValue {
            return true
        }
        return nsError.domain == MKErrorDomain
            && nsError.code == Int(MKError.Code.placemarkNotFound.rawValue)
    }

    private func resolveWithTimeout(_ location: CLLocation) async throws -> LocationStrings? {
        guard providerRequestGate.begin() else { throw ProviderBusy() }
        let gate = providerRequestGate
        let race = ReverseGeocodeRequestRace()
        let timeout = requestTimeoutNanoseconds
        Task { @MainActor [geocoder, gate, race] in
            defer { gate.end() }
            guard race.isPending else { return }
            do {
                let result = try await geocoder.resolve(
                    location,
                    preferredLocale: Locale(identifier: "en_US")
                )
                race.finish(.success(result))
            } catch {
                race.finish(.failure(error))
            }
        }
        let timeoutTask = Task { [geocoder, race] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            if race.finish(.failure(RequestTimedOut())) {
                await geocoder.cancel()
            }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await race.wait()
        } onCancel: { [geocoder, race, timeoutTask] in
            if race.finish(.failure(CancellationError())) {
                timeoutTask.cancel()
                Task { @MainActor in geocoder.cancel() }
            }
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

private final class LocationGeocoderRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false

    func begin() -> Bool {
        lock.withLock {
            guard !isBusy else { return false }
            isBusy = true
            return true
        }
    }

    func end() {
        lock.withLock { isBusy = false }
    }
}

private final class ReverseGeocodeRequestRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LocationStrings?, Error>?
    private var continuation: CheckedContinuation<LocationStrings?, Error>?

    var isPending: Bool {
        lock.withLock { result == nil }
    }

    func wait() async throws -> LocationStrings? {
        try await withCheckedThrowingContinuation { continuation in
            let completedResult = lock.withLock { () -> Result<LocationStrings?, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completedResult {
                continuation.resume(with: completedResult)
            }
        }
    }

    @discardableResult
    func finish(_ result: Result<LocationStrings?, Error>) -> Bool {
        let completion = lock.withLock {
            () -> (won: Bool, continuation: CheckedContinuation<LocationStrings?, Error>?) in
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return (true, continuation)
        }
        completion.continuation?.resume(with: result)
        return completion.won
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

enum GeocodingProgressPhase: Equatable, Sendable {
    case queued
    case running
    case waitingToResume
    case paused
}

struct GeocodingProgressState: Equatable, Sendable {
    let completed: Int
    let total: Int
    let phase: GeocodingProgressPhase

    init(completed: Int, total: Int, phase: GeocodingProgressPhase) {
        self.total = max(0, total)
        self.completed = min(max(0, completed), self.total)
        self.phase = phase
    }

    init?(counts: GeocodingCounts, phase: GeocodingProgressPhase) {
        guard counts.remaining > 0 else { return nil }
        self.init(
            completed: counts.totalWithGPS - counts.remaining,
            total: counts.totalWithGPS,
            phase: phase
        )
    }
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
    typealias ProgressHandler = @MainActor @Sendable (GeocodingProgressSnapshot) -> Void
    typealias LocationUpdateHandler = @Sendable ([LocationBackfillUpdate]) -> Void

    private enum MediaSource: String {
        case photos
        case videos
    }

    private struct SourceResult {
        let completed: Int
        let wasCancelled: Bool
        let failedBuckets: Set<String>
        let noResultBuckets: Set<String>
        let stoppedAfterTransientFailures: Bool
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

    func run(
        progress: @escaping ProgressHandler,
        locationsUpdated: @escaping LocationUpdateHandler = { _ in }
    ) async -> GeocodingRunResult {
        let counts: GeocodingCounts
        do {
            try Task.checkCancellation()
            counts = try database.geocodingCounts()
        } catch is CancellationError {
            return GeocodingRunResult(completed: 0, total: 0, wasCancelled: true)
        } catch {
            logger.error("[Geocoder] Failed to load geocoding counts: \(error.safeDiagnosticCode)")
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
            failedBuckets: [],
            noResultBuckets: [],
            progress: progress,
            locationsUpdated: locationsUpdated
        )
        if photos.wasCancelled {
            return GeocodingRunResult(completed: photos.completed, total: total, wasCancelled: true)
        }
        if photos.stoppedAfterTransientFailures {
            return GeocodingRunResult(completed: photos.completed, total: total, wasCancelled: false)
        }

        let videos = await runSource(
            .videos,
            progressBase: alreadyCompleted + photos.completed,
            total: total,
            failedBuckets: photos.failedBuckets,
            noResultBuckets: photos.noResultBuckets,
            progress: progress,
            locationsUpdated: locationsUpdated
        )
        let completed = photos.completed + videos.completed
        if videos.wasCancelled {
            return GeocodingRunResult(completed: completed, total: total, wasCancelled: true)
        }

        // Publish authoritative terminal progress before returning to the main
        // actor. Under heavy indexing load, the caller's continuation may be
        // delayed even though the worker and its database writes are finished.
        do {
            let finalCounts = try database.geocodingCounts()
            if remaining > 0 {
                await progress(GeocodingProgressSnapshot(
                    completed: finalCounts.totalWithGPS - finalCounts.remaining,
                    total: finalCounts.totalWithGPS
                ))
            }
        } catch {
            logger.error("[Geocoder] Failed to load final geocoding counts: \(error.safeDiagnosticCode)")
        }

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
        failedBuckets initialFailedBuckets: Set<String>,
        noResultBuckets initialNoResultBuckets: Set<String>,
        progress: @escaping ProgressHandler,
        locationsUpdated: @escaping LocationUpdateHandler
    ) async -> SourceResult {
        var completed = 0
        var lastProgressPublication = Date()
        var failedBuckets = initialFailedBuckets
        var noResultBuckets = initialNoResultBuckets
        var cursor: String?
        var consecutiveTransientFailures = 0

        while !Task.isCancelled {
            let candidates: [(localIdentifier: String, lat: Double, lon: Double)]
            do {
                switch source {
                case .photos:
                    candidates = try database.photosNeedingLocationBackfill(
                        after: cursor,
                        limit: fetchBatchSize
                    )
                case .videos:
                    candidates = try database.videosNeedingLocationBackfill(
                        after: cursor,
                        limit: fetchBatchSize
                    )
                }
            } catch {
                logger.error("[Geocoder] Failed to fetch \(source.rawValue) batch: \(error.safeDiagnosticCode)")
                break
            }
            guard !candidates.isEmpty else { break }
            cursor = candidates.last?.localIdentifier

            var pendingUpdates: [LocationBackfillUpdate] = []
            pendingUpdates.reserveCapacity(writeBatchSize)
            let groupedCandidates = Dictionary(grouping: candidates) {
                LocationCoordinateBucket.key(latitude: $0.lat, longitude: $0.lon)
            }
            let cachedLocations: [String: LocationStrings]
            do {
                cachedLocations = try database.reverseGeocodeLocations(
                    bucketKeys: groupedCandidates.keys.sorted()
                )
            } catch {
                logger.error("[Geocoder] Failed to read persistent cache batch: \(error.safeDiagnosticCode)")
                cachedLocations = [:]
            }
            bucketLoop: for bucketKey in groupedCandidates.keys.sorted() {
                if Task.isCancelled {
                    return SourceResult(
                        completed: completed,
                        wasCancelled: true,
                        failedBuckets: failedBuckets,
                        noResultBuckets: noResultBuckets,
                        stoppedAfterTransientFailures: false
                    )
                }
                guard let bucket = groupedCandidates[bucketKey], let representative = bucket.first else {
                    continue
                }
                if noResultBuckets.contains(bucketKey) {
                    if !persistNoResult(bucket, source: source), Task.isCancelled {
                        return SourceResult(
                            completed: completed,
                            wasCancelled: true,
                            failedBuckets: failedBuckets,
                            noResultBuckets: noResultBuckets,
                            stoppedAfterTransientFailures: false
                        )
                    }
                    continue
                }
                if failedBuckets.contains(bucketKey) { continue }

                let cachedLocation = cachedLocations[bucketKey]
                let outcome: ReverseGeocoder.Outcome
                if let cachedLocation {
                    outcome = .resolved(cachedLocation)
                } else {
                    outcome = await reverseGeocoder.reverseGeocode(
                        latitude: representative.lat,
                        longitude: representative.lon
                    )
                }

                let resolvedLocation: LocationStrings
                switch outcome {
                case .resolved(let location):
                    resolvedLocation = location
                    consecutiveTransientFailures = 0
                case .noResult:
                    consecutiveTransientFailures = 0
                    noResultBuckets.insert(bucketKey)
                    if !persistNoResult(bucket, source: source), Task.isCancelled {
                        return SourceResult(
                            completed: completed,
                            wasCancelled: true,
                            failedBuckets: failedBuckets,
                            noResultBuckets: noResultBuckets,
                            stoppedAfterTransientFailures: false
                        )
                    }
                    continue
                case .transientFailure:
                    consecutiveTransientFailures += 1
                    failedBuckets.insert(bucketKey)
                    if consecutiveTransientFailures >= 3 {
                        break bucketLoop
                    }
                    continue
                case .cancelled:
                    return SourceResult(
                        completed: completed,
                        wasCancelled: true,
                        failedBuckets: failedBuckets,
                        noResultBuckets: noResultBuckets,
                        stoppedAfterTransientFailures: false
                    )
                }

                if Task.isCancelled {
                        return SourceResult(
                            completed: completed,
                            wasCancelled: true,
                            failedBuckets: failedBuckets,
                            noResultBuckets: noResultBuckets,
                            stoppedAfterTransientFailures: false
                        )
                }

                if cachedLocation == nil {
                    do {
                        try database.saveReverseGeocodeLocation(
                            resolvedLocation,
                            bucketKey: bucketKey
                        )
                    } catch {
                        logger.error("[Geocoder] Failed to persist location cache: \(error.safeDiagnosticCode)")
                    }
                }
                pendingUpdates.append(contentsOf: bucket.map {
                    LocationBackfillUpdate(
                        localIdentifier: $0.localIdentifier,
                        location: resolvedLocation
                    )
                })

                while pendingUpdates.count >= writeBatchSize {
                    let batch = Array(pendingUpdates.prefix(writeBatchSize))
                    pendingUpdates.removeFirst(writeBatchSize)
                    guard flush(
                        batch,
                        source: source,
                        completed: &completed,
                        locationsUpdated: locationsUpdated
                    ) else {
                        return SourceResult(
                            completed: completed,
                            wasCancelled: Task.isCancelled,
                            failedBuckets: failedBuckets,
                            noResultBuckets: noResultBuckets,
                            stoppedAfterTransientFailures: false
                        )
                    }
                    await publishProgressIfNeeded(
                        completed: progressBase + completed,
                        total: total,
                        lastPublication: &lastProgressPublication,
                        progress: progress
                    )
                }
            }

            if !pendingUpdates.isEmpty {
                guard flush(
                    pendingUpdates,
                    source: source,
                    completed: &completed,
                    locationsUpdated: locationsUpdated
                ) else {
                    return SourceResult(
                        completed: completed,
                        wasCancelled: Task.isCancelled,
                        failedBuckets: failedBuckets,
                        noResultBuckets: noResultBuckets,
                        stoppedAfterTransientFailures: false
                    )
                }
                await publishProgressIfNeeded(
                    completed: progressBase + completed,
                    total: total,
                    lastPublication: &lastProgressPublication,
                    progress: progress
                )
            }
            if consecutiveTransientFailures >= 3 {
                logger.error("[Geocoder] Pausing after repeated transient service failures")
                return SourceResult(
                    completed: completed,
                    wasCancelled: false,
                    failedBuckets: failedBuckets,
                    noResultBuckets: noResultBuckets,
                    stoppedAfterTransientFailures: true
                )
            }
        }

        return SourceResult(
            completed: completed,
            wasCancelled: Task.isCancelled,
            failedBuckets: failedBuckets,
            noResultBuckets: noResultBuckets,
            stoppedAfterTransientFailures: false
        )
    }

    private func persistNoResult(
        _ candidates: [(localIdentifier: String, lat: Double, lon: Double)],
        source: MediaSource
    ) -> Bool {
        let retryAfter = Date(
            timeIntervalSinceNow: ReverseGeocodeCachePolicy.noResultRetryDelaySeconds
        )
        do {
            try Task.checkCancellation()
            switch source {
            case .photos:
                try database.deferPhotoLocationBackfill(
                    localIdentifiers: candidates.map(\.localIdentifier),
                    until: retryAfter
                )
            case .videos:
                try database.deferVideoLocationBackfill(
                    localIdentifiers: candidates.map(\.localIdentifier),
                    until: retryAfter
                )
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.error("[Geocoder] Failed to persist no-result retry state: \(error.safeDiagnosticCode)")
            return false
        }
    }

    private func flush(
        _ updates: [LocationBackfillUpdate],
        source: MediaSource,
        completed: inout Int,
        locationsUpdated: LocationUpdateHandler
    ) -> Bool {
        guard !updates.isEmpty else { return true }
        do {
            try Task.checkCancellation()
            switch source {
            case .photos:
                try database.updatePhotoLocations(updates)
            case .videos:
                try database.updateVideoLocations(updates)
            }
            completed += updates.count
            locationsUpdated(updates)
            return true
        } catch is CancellationError {
            return false
        } catch {
            // A failed write is safe to retry. The persistent coordinate cache
            // keeps the next run from repeating the network request.
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
