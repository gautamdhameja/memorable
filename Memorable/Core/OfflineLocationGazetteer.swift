import Foundation
import GRDB

/// Resolves unambiguous place names to conservative on-device coordinate
/// regions. This lets GPS-bearing media participate in location search before
/// Apple's reverse-geocoding enrichment has completed.
final class OfflineLocationGazetteer: @unchecked Sendable {
    typealias Matcher = @Sendable (_ latitude: Double?, _ longitude: Double?) -> Bool
    private typealias Ring = [[Double]]
    private typealias Polygon = [Ring]
    private typealias MultiPolygon = [Polygon]
    private static let supportedFormatVersion = "2"

    private enum Kind: String, Sendable {
        case city = "c"
        case admin = "a"
        case country = "o"
    }

    private struct Record: Sendable {
        let name: String
        let kind: Kind
        let country: String
        let admin: String?
        let code: String?
        let latitude: Double?
        let longitude: Double?
        let isCapital: Bool
        let prominence: Int
        let south: Double?
        let west: Double?
        let north: Double?
        let east: Double?
        let geometryJSON: String?
    }

    static let shared = OfflineLocationGazetteer()
    static let cityRadiusKilometers = 60.0
    private static let clusteredCityLimitKilometers = 100.0

    // DatabaseQueue serializes access to this immutable, read-only bundled
    // database. The reference never changes after initialization, which makes
    // cross-task reads safe despite GRDB not declaring this wrapper Sendable.
    private let database: DatabaseQueue?

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "location_gazetteer", withExtension: "sqlite") else {
            logger.error("Bundled location gazetteer is missing")
            database = nil
            return
        }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let candidate = try DatabaseQueue(path: url.path, configuration: configuration)
            let formatVersion = try candidate.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM metadata WHERE key = 'formatVersion'"
                )
            }
            guard formatVersion == Self.supportedFormatVersion else {
                logger.error("Bundled location gazetteer has an unsupported format")
                database = nil
                return
            }
            database = candidate
        } catch {
            logger.error("Failed to open location gazetteer: \(error.safeDiagnosticCode)")
            database = nil
        }
    }

    func makeMatcher(
        query: String,
        locality: String?,
        adminArea: String?,
        country: String?
    ) -> Matcher? {
        let normalizedQuery = LocationMatcher.normalized(query)
        let queryName = canonicalName(for: normalizedQuery) ?? normalizedQuery
        guard !queryName.isEmpty else { return nil }

        let localityName = locality.map(LocationMatcher.normalized)
        let adminName = adminArea.map(LocationMatcher.normalized)
        let countryName = country.map(LocationMatcher.normalized).map {
            canonicalName(for: $0) ?? $0
        }
        var names = Set([queryName])
        if let localityName, !localityName.isEmpty { names.insert(localityName) }
        if let adminName, !adminName.isEmpty { names.insert(adminName) }

        let records: [Record]
        do {
            records = try loadRecords(names: names, code: adminName ?? queryName)
        } catch {
            logger.error("Location gazetteer lookup failed: \(error.safeDiagnosticCode)")
            return nil
        }

        if let localityName, !localityName.isEmpty {
            return cityMatcher(for: records.filter {
                $0.kind == .city
                    && $0.name == localityName
                    && matchesCanonicalContext($0, admin: adminName, country: countryName)
            })
        }

        if let adminName, !adminName.isEmpty {
            let matches = records.filter {
                $0.kind == .admin
                    && ($0.name == adminName || $0.code == adminName || $0.name == queryName)
                    && matchesCanonicalContext($0, admin: nil, country: countryName)
            }
            return regionMatcher(for: matches)
        }

        if let countryName, !countryName.isEmpty {
            return regionMatcher(for: records.filter {
                $0.kind == .country && $0.name == countryName
            })
        }

        let countries = records.filter { $0.kind == .country && $0.name == queryName }
        let admins = records.filter { $0.kind == .admin && $0.name == queryName }

        // A bare name can intentionally denote both a country and a known
        // administrative region. Include both conservative geometries so
        // unresolved GPS rows behave like already reverse-geocoded rows.
        if !countries.isEmpty, !admins.isEmpty {
            let scopedAdmins: [Record]
            if let alias = AdministrativeRegionAliases.alias(for: queryName) {
                scopedAdmins = admins.filter {
                    $0.code == alias.code && alias.countries.contains($0.country)
                }
            } else {
                scopedAdmins = admins
            }
            return unionRegionMatcher(for: countries + scopedAdmins)
        }

        // Keep unresolved-GPS matching aligned with LocationMatcher: known
        // region names such as Washington and Victoria mean the administrative
        // region, not a same-named city in another country.
        if let alias = AdministrativeRegionAliases.alias(for: queryName) {
            let matches = records.filter {
                $0.kind == .admin
                    && $0.code == alias.code
                    && alias.countries.contains($0.country)
            }
            if let matcher = regionMatcher(for: matches) { return matcher }
        }

        let cities = records.filter { $0.kind == .city && $0.name == queryName }
        if !cities.isEmpty {
            return cityMatcher(for: cities)
        }

        if !countries.isEmpty { return regionMatcher(for: countries) }
        if !admins.isEmpty { return regionMatcher(for: admins) }

        if let alias = AdministrativeRegionAliases.alias(forCode: queryName) {
            let matches = records.filter {
                $0.kind == .admin
                    && $0.code == alias.code
                    && alias.countries.contains($0.country)
            }
            return regionMatcher(for: matches)
        }
        return nil
    }

    private func loadRecords(names: Set<String>, code: String) throws -> [Record] {
        guard let database else { return [] }
        let sortedNames = names.sorted()
        let placeholders = Array(repeating: "?", count: sortedNames.count).joined(separator: ",")
        let arguments = StatementArguments(sortedNames + [code])
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT name, kind, country, admin, code, latitude, longitude,
                           isCapital, prominence, south, west, north, east, geometry
                    FROM locations
                    WHERE name IN (\(placeholders)) OR code = ?
                """,
                arguments: arguments
            )
            return rows.compactMap { row in
                guard let kind = Kind(rawValue: row["kind"]) else { return nil }
                return Record(
                    name: row["name"],
                    kind: kind,
                    country: row["country"],
                    admin: row["admin"],
                    code: row["code"],
                    latitude: row["latitude"],
                    longitude: row["longitude"],
                    isCapital: row["isCapital"],
                    prominence: row["prominence"],
                    south: row["south"],
                    west: row["west"],
                    north: row["north"],
                    east: row["east"],
                    geometryJSON: row["geometry"]
                )
            }
        }
    }

    private func cityMatcher(for candidates: [Record]) -> Matcher? {
        let resolved: [Record]
        if candidates.count == 1 {
            resolved = candidates
        } else {
            let capitals = candidates.filter(\.isCapital)
            if capitals.count == 1 {
                resolved = capitals
            } else if let dominant = dominantCity(in: candidates) {
                resolved = [dominant]
            } else if let first = candidates.first,
                      candidates.dropFirst().allSatisfy({ distanceKilometers(from: first, to: $0) <= Self.clusteredCityLimitKilometers }) {
                resolved = candidates
            } else {
                return nil
            }
        }
        guard !resolved.isEmpty else { return nil }
        let centers = resolved.compactMap { record -> (Double, Double)? in
            guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
            return (latitude, longitude)
        }
        guard !centers.isEmpty else { return nil }
        return { latitude, longitude in
            guard let latitude, let longitude,
                  LocationCoordinatePolicy.isValid(latitude: latitude, longitude: longitude) else {
                return false
            }
            return centers.contains { center in
                Self.haversineKilometers(
                    latitude1: latitude,
                    longitude1: longitude,
                    latitude2: center.0,
                    longitude2: center.1
                ) <= Self.cityRadiusKilometers
            }
        }
    }

    private func dominantCity(in candidates: [Record]) -> Record? {
        let ranked = candidates
            .filter { $0.prominence > 0 }
            .sorted { $0.prominence > $1.prominence }
        guard let first = ranked.first, first.prominence >= 100_000 else { return nil }
        let runnerUp = ranked.dropFirst().first?.prominence ?? 0
        return first.prominence >= max(100_000, runnerUp * 5) ? first : nil
    }

    private func canonicalName(for alias: String) -> String? {
        guard !alias.isEmpty, let database else { return nil }
        do {
            return try database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT target FROM aliases WHERE alias = ?",
                    arguments: [alias]
                )
            }
        } catch {
            logger.error("Location gazetteer alias lookup failed: \(error.safeDiagnosticCode)")
            return nil
        }
    }

    private func regionMatcher(for candidates: [Record]) -> Matcher? {
        guard candidates.count == 1, let record = candidates.first,
              let south = record.south, let west = record.west,
              let north = record.north, let east = record.east,
              let geometryJSON = record.geometryJSON else {
            return nil
        }
        let polygons: MultiPolygon
        do {
            polygons = try JSONDecoder().decode(
                  MultiPolygon.self,
                  from: Data(geometryJSON.utf8)
            )
        } catch {
            logger.error("Location gazetteer geometry decode failed: \(error.safeDiagnosticCode)")
            return nil
        }
        return { latitude, longitude in
            guard let latitude, let longitude,
                  LocationCoordinatePolicy.isValid(latitude: latitude, longitude: longitude),
                  latitude >= south, latitude <= north else {
                return false
            }
            let isInsideBounds = west <= east
                ? longitude >= west && longitude <= east
                : longitude >= west || longitude <= east
            guard isInsideBounds else { return false }
            return Self.contains(
                latitude: latitude,
                longitude: longitude,
                in: polygons
            )
        }
    }

    private func unionRegionMatcher(for candidates: [Record]) -> Matcher? {
        let matchers = candidates.compactMap { regionMatcher(for: [$0]) }
        guard !matchers.isEmpty, matchers.count == candidates.count else { return nil }
        return { latitude, longitude in
            matchers.contains { $0(latitude, longitude) }
        }
    }

    private static func contains(
        latitude: Double,
        longitude: Double,
        in polygons: MultiPolygon
    ) -> Bool {
        polygons.contains { polygon in
            guard let exterior = polygon.first,
                  pointIsInside(latitude: latitude, longitude: longitude, ring: exterior) else {
                return false
            }
            return !polygon.dropFirst().contains {
                pointIsInside(latitude: latitude, longitude: longitude, ring: $0)
            }
        }
    }

    private static func pointIsInside(
        latitude: Double,
        longitude: Double,
        ring: Ring
    ) -> Bool {
        guard ring.count >= 3 else { return false }
        var isInside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            guard current.count >= 2, previous.count >= 2 else {
                previous = current
                continue
            }
            let currentLongitude = longitudeNearest(current[0], to: longitude)
            let previousLongitude = longitudeNearest(previous[0], to: longitude)
            let crossesLatitude = (current[1] > latitude) != (previous[1] > latitude)
            if crossesLatitude {
                let crossingLongitude = (previousLongitude - currentLongitude)
                    * (latitude - current[1]) / (previous[1] - current[1])
                    + currentLongitude
                if longitude < crossingLongitude {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }

    private static func longitudeNearest(_ value: Double, to reference: Double) -> Double {
        var adjusted = value
        while adjusted - reference > 180 { adjusted -= 360 }
        while adjusted - reference < -180 { adjusted += 360 }
        return adjusted
    }

    private func matchesCanonicalContext(_ record: Record, admin: String?, country: String?) -> Bool {
        if let admin, !admin.isEmpty, record.admin != admin && record.code != admin {
            return false
        }
        if let country, !country.isEmpty, record.country != country {
            return false
        }
        return true
    }

    private func distanceKilometers(from lhs: Record, to rhs: Record) -> Double {
        guard let latitude1 = lhs.latitude, let longitude1 = lhs.longitude,
              let latitude2 = rhs.latitude, let longitude2 = rhs.longitude else {
            return .infinity
        }
        return Self.haversineKilometers(
            latitude1: latitude1,
            longitude1: longitude1,
            latitude2: latitude2,
            longitude2: longitude2
        )
    }

    private static func haversineKilometers(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        let earthRadius = 6_371.0
        let latitudeDelta = (latitude2 - latitude1) * .pi / 180
        let longitudeDelta = (longitude2 - longitude1) * .pi / 180
        let firstLatitude = latitude1 * .pi / 180
        let secondLatitude = latitude2 * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

}
