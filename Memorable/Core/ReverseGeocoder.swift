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

struct LocationStrings {
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

@MainActor
class ReverseGeocoder {
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
