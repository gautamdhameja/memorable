import CoreLocation

struct LocationStrings {
    let city: String?       // locality
    let state: String?      // administrativeArea
    let country: String?    // country
    let name: String?       // subLocality, or locality if no subLocality
}

class ReverseGeocoder {
    private let geocoder = CLGeocoder()

    // Cache keyed by coordinates rounded to ~1km grid (2 decimal places).
    // Photos taken at the same venue will share a cache entry.
    private var cache: [String: LocationStrings] = [:]

    // Apple rate-limits CLGeocoder to 50 requests per 60 seconds.
    // 2s between API calls stays safely under that limit with margin for jitter.
    private static let throttleNanoseconds: UInt64 = 2_000_000_000

    func reverseGeocode(latitude: Double, longitude: Double) async -> LocationStrings? {
        let key = "\(round(latitude * 100) / 100),\(round(longitude * 100) / 100)"
        if let cached = cache[key] {
            return cached
        }

        // Throttle only actual API calls, not cache hits
        try? await Task.sleep(nanoseconds: Self.throttleNanoseconds)

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
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
            cache[key] = result
            return result
        } catch {
            #if DEBUG
            logger.error("[ReverseGeocoder] Failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}
