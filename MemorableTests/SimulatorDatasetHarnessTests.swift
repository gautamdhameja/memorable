import CoreLocation
import GRDB
import Photos
import XCTest
@testable import Memorable

#if targetEnvironment(simulator)
@MainActor
final class SimulatorDatasetHarnessTests: XCTestCase {
    private struct Place: Sendable {
        let key: String
        let latitude: Double
        let longitude: Double
        let city: String
        let state: String?
        let country: String
        let name: String
    }

    private struct Assignment: Sendable {
        let date: Date
        let place: Place?
        let source: String
    }

    private struct AssetMutation: @unchecked Sendable {
        let asset: PHAsset
        let assignment: Assignment
    }

    private struct StoredMetadata: Codable {
        let localIdentifier: String
        let creationDate: Date?
        let latitude: Double?
        let longitude: Double?
    }

    private struct StoredSeed: Codable {
        let version: Int
        let generatedAt: Date
        let assignments: [StoredSeedAssignment]
    }

    private struct StoredSeedAssignment: Codable {
        let localIdentifier: String
        let creationDate: Date
        let latitude: Double?
        let longitude: Double?
        let placeKey: String?
        let source: String
    }

    private struct QueryRecord: Codable {
        let query: String
        let policy: String
        let resultCount: Int
        let fallbackCount: Int
        let surfacedCount: Int
        let topFiveIdentifiers: [String]
        let topFiveScores: [Float]
        let dateFilter: String?
        let locationFilter: String?
        let visualQuery: String?
        let restrictions: [String]
        let latencyMilliseconds: Int
        let validationFailures: [String]
    }

    private struct QueryReport: Codable {
        let generatedAt: Date
        let indexedPhotoCount: Int
        let assignmentCounts: [String: Int]
        let records: [QueryRecord]
    }

    private struct QueryCase: Sendable {
        let query: String
        let expectedEmpty: Bool

        init(_ query: String, expectedEmpty: Bool = false) {
            self.query = query
            self.expectedEmpty = expectedEmpty
        }
    }

    private let places = [
        Place(key: "berlin", latitude: 52.5200, longitude: 13.4050,
              city: "Berlin", state: "Berlin", country: "Germany", name: "Mitte"),
        Place(key: "san-francisco", latitude: 37.7749, longitude: -122.4194,
              city: "San Francisco", state: "CA", country: "United States", name: "San Francisco"),
        Place(key: "los-angeles", latitude: 34.0522, longitude: -118.2437,
              city: "Los Angeles", state: "CA", country: "United States", name: "Los Angeles"),
        Place(key: "san-diego", latitude: 32.7157, longitude: -117.1611,
              city: "San Diego", state: "CA", country: "United States", name: "San Diego"),
        Place(key: "paris", latitude: 48.8566, longitude: 2.3522,
              city: "Paris", state: "Ile-de-France", country: "France", name: "Paris"),
        Place(key: "munich", latitude: 48.1351, longitude: 11.5820,
              city: "Munich", state: "Bavaria", country: "Germany", name: "Munich"),
        Place(key: "new-york", latitude: 40.7128, longitude: -74.0060,
              city: "New York", state: "NY", country: "United States", name: "Manhattan"),
        Place(key: "toronto", latitude: 43.6532, longitude: -79.3832,
              city: "Toronto", state: "Ontario", country: "Canada", name: "Toronto"),
        Place(key: "sydney", latitude: -33.8688, longitude: 151.2093,
              city: "Sydney", state: "NSW", country: "Australia", name: "Sydney"),
        Place(key: "tbilisi", latitude: 41.7151, longitude: 44.8271,
              city: "Tbilisi", state: "Tbilisi", country: "Georgia", name: "Tbilisi"),
        Place(key: "atlanta", latitude: 33.7490, longitude: -84.3880,
              city: "Atlanta", state: "Georgia", country: "United States", name: "Atlanta"),
        Place(key: "istanbul", latitude: 41.0082, longitude: 28.9784,
              city: "Istanbul", state: "Istanbul", country: "Turkey", name: "Istanbul")
    ]

    func testSeedAndEvaluateExistingLibrary() async throws {
        guard ProcessInfo.processInfo.environment["MEMORABLE_DATASET_HARNESS"] == "1" else {
            throw XCTSkip("Set MEMORABLE_DATASET_HARNESS=1 to run the simulator data mutation harness")
        }

        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            XCTFail("The simulator must already grant Memorable full Photos access; status=\(authorization.rawValue)")
            return
        }

        let assets = fetchImageAssets()
        XCTAssertGreaterThanOrEqual(assets.count, 2_000)

        let database = AppDatabase.shared
        let textEncoder = try await TextEncoder()
        let engine = SearchEngine(textEncoder: textEncoder, database: database)
        try engine.loadIndex()
        XCTAssertGreaterThanOrEqual(engine.indexSize, 2_000)

        let assignments = try await makeAssignments(assets: assets, engine: engine)
        try saveOriginalMetadataIfNeeded(assets)
        try saveSeed(assignments)
        try await applyPhotoKitMetadata(assignments, assets: assets)
        try updateDerivedSearchMetadata(assignments, database: database)
        try engine.loadIndex()

        let report = try await evaluateQueries(engine: engine, database: database, assignments: assignments)
        try save(report: report)

        let failures = report.records.flatMap(\.validationFailures)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func fetchImageAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets.sorted { $0.localIdentifier < $1.localIdentifier }
    }

    private func makeAssignments(
        assets: [PHAsset],
        engine: SearchEngine
    ) async throws -> [String: Assignment] {
        var assignments: [String: Assignment] = [:]
        assignments.reserveCapacity(assets.count)
        let calendar = testCalendar

        for (index, asset) in assets.enumerated() {
            // Keep exactly one fifth unlocated while distributing the rest
            // evenly. The simple index modulus avoids a divisor-dependent
            // cycle when the number of seeded places changes.
            let place: Place? = index % 5 == 0 ? nil : places[index % places.count]
            let date: Date
            if index % 97 == 0 {
                date = makeDate(year: 2026, month: 9, day: 1, hour: 10, calendar: calendar)
            } else if index % 89 == 0 {
                date = makeDate(year: 2026, month: 8, day: 29, hour: 16, calendar: calendar)
            } else if index % 83 == 0 {
                date = makeDate(year: 2025, month: 7, day: 12, hour: 14, calendar: calendar)
            } else {
                let year = 2022 + (index % 5)
                let month = 1 + ((index / 5) % 12)
                let day = 2 + ((index / 11) % 25)
                let hour = [7, 9, 12, 15, 19, 23][index % 6]
                date = makeDate(year: year, month: month, day: day, hour: hour, calendar: calendar)
            }
            assignments[asset.localIdentifier] = Assignment(date: date, place: place, source: "distributed")
        }

        var usedIdentifiers = Set<String>()
        let anchorPlans: [(query: String, placeKey: String?, year: Int, month: Int, day: Int, hour: Int)] = [
            ("dog", "berlin", 2023, 6, 15, 16),
            ("beach", "san-francisco", 2022, 7, 12, 14),
            ("beach", "los-angeles", 2025, 7, 18, 14),
            ("food", "paris", 2026, 8, 29, 19),
            ("sunset", "berlin", 2024, 9, 10, 20),
            ("mountains", "munich", 2023, 10, 8, 12),
            ("street art", "berlin", 2024, 5, 14, 15),
            ("coffee", "new-york", 2024, 3, 22, 8),
            ("snow", "munich", 2025, 12, 16, 11),
            ("birthday", nil, 2025, 4, 20, 18),
            ("hiking", "munich", 2023, 8, 17, 10)
        ]

        for plan in anchorPlans {
            let response = try await engine.search(
                query: plan.query,
                featurePolicy: .basic,
                recordsUserTiming: false
            )
            let place = plan.placeKey.flatMap { key in places.first { $0.key == key } }
            let date = makeDate(
                year: plan.year,
                month: plan.month,
                day: plan.day,
                hour: plan.hour,
                calendar: calendar
            )
            var assigned = 0
            for result in response.results where !result.isVideo && !usedIdentifiers.contains(result.localIdentifier) {
                assignments[result.localIdentifier] = Assignment(
                    date: date.addingTimeInterval(TimeInterval(assigned * 90)),
                    place: place,
                    source: "anchor:\(plan.query)"
                )
                usedIdentifiers.insert(result.localIdentifier)
                assigned += 1
                if assigned == 8 { break }
            }
            XCTAssertGreaterThan(assigned, 0, "No existing visual candidates for anchor '\(plan.query)'")
        }

        // Location-and-date-only queries need an intentional intersection;
        // a round-robin seed can otherwise correlate place and year buckets.
        let germany2022Place = places.first { $0.key == "berlin" }!
        let germany2022Date = makeDate(
            year: 2022,
            month: 5,
            day: 18,
            hour: 13,
            calendar: calendar
        )
        var germany2022Count = 0
        for asset in assets where !usedIdentifiers.contains(asset.localIdentifier) {
            assignments[asset.localIdentifier] = Assignment(
                date: germany2022Date.addingTimeInterval(TimeInterval(germany2022Count * 90)),
                place: germany2022Place,
                source: "cohort:Germany 2022"
            )
            usedIdentifiers.insert(asset.localIdentifier)
            germany2022Count += 1
            if germany2022Count == 8 { break }
        }
        XCTAssertEqual(germany2022Count, 8)

        let berlinSummerPlace = places.first { $0.key == "berlin" }!
        let berlinSummerDate = makeDate(
            year: 2025,
            month: 7,
            day: 14,
            hour: 15,
            calendar: calendar
        )
        var berlinSummerCount = 0
        for asset in assets where !usedIdentifiers.contains(asset.localIdentifier) {
            assignments[asset.localIdentifier] = Assignment(
                date: berlinSummerDate.addingTimeInterval(TimeInterval(berlinSummerCount * 90)),
                place: berlinSummerPlace,
                source: "cohort:Berlin last summer"
            )
            usedIdentifiers.insert(asset.localIdentifier)
            berlinSummerCount += 1
            if berlinSummerCount == 8 { break }
        }
        XCTAssertEqual(berlinSummerCount, 8)

        let parisDecemberPlace = places.first { $0.key == "paris" }!
        let parisDecemberDate = makeDate(
            year: 2025,
            month: 12,
            day: 12,
            hour: 18,
            calendar: calendar
        )
        var parisDecemberCount = 0
        for asset in assets where !usedIdentifiers.contains(asset.localIdentifier) {
            assignments[asset.localIdentifier] = Assignment(
                date: parisDecemberDate.addingTimeInterval(TimeInterval(parisDecemberCount * 90)),
                place: parisDecemberPlace,
                source: "cohort:Paris December"
            )
            usedIdentifiers.insert(asset.localIdentifier)
            parisDecemberCount += 1
            if parisDecemberCount == 8 { break }
        }
        XCTAssertEqual(parisDecemberCount, 8)
        return assignments
    }

    private func applyPhotoKitMetadata(
        _ assignments: [String: Assignment],
        assets: [PHAsset]
    ) async throws {
        let editable = assets.filter { $0.canPerform(.properties) }
        XCTAssertEqual(editable.count, assets.count, "Every seeded simulator asset should allow property edits")
        for batchStart in stride(from: 0, to: editable.count, by: 200) {
            let batch = editable[batchStart..<min(batchStart + 200, editable.count)].compactMap { asset in
                assignments[asset.localIdentifier].map { AssetMutation(asset: asset, assignment: $0) }
            }
            try await Self.applyPhotoKitBatch(batch)
        }
    }

    private nonisolated static func applyPhotoKitBatch(_ batch: [AssetMutation]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                for mutation in batch {
                    let request = PHAssetChangeRequest(for: mutation.asset)
                    request.creationDate = mutation.assignment.date
                    request.location = mutation.assignment.place.map {
                        CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    }
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? DatasetHarnessError.photoKitMutationFailed)
                }
            }
        }
    }

    private func updateDerivedSearchMetadata(
        _ assignments: [String: Assignment],
        database: AppDatabase
    ) throws {
        try database.dbQueue.write { db in
            for (identifier, assignment) in assignments {
                try db.execute(
                    sql: """
                        UPDATE indexed_photos
                        SET creationDate = ?, latitude = ?, longitude = ?,
                            locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?
                        WHERE localIdentifier = ?
                    """,
                    arguments: [
                        assignment.date,
                        assignment.place?.latitude,
                        assignment.place?.longitude,
                        assignment.place?.city,
                        assignment.place?.state,
                        assignment.place?.country,
                        assignment.place?.name,
                        identifier
                    ]
                )
            }
        }
    }

    private func evaluateQueries(
        engine: SearchEngine,
        database: AppDatabase,
        assignments: [String: Assignment]
    ) async throws -> QueryReport {
        var records: [QueryRecord] = []
        for queryCase in proQueries {
            records.append(try await evaluate(
                queryCase,
                policy: .pro,
                policyName: "pro",
                engine: engine,
                database: database
            ))
        }
        for queryCase in freeTierQueries {
            records.append(try await evaluate(
                queryCase,
                policy: .basic,
                policyName: "free",
                engine: engine,
                database: database
            ))
        }

        var assignmentCounts: [String: Int] = [:]
        for assignment in assignments.values {
            assignmentCounts[assignment.place?.key ?? "no-location", default: 0] += 1
        }
        return QueryReport(
            generatedAt: Date(),
            indexedPhotoCount: engine.indexSize,
            assignmentCounts: assignmentCounts,
            records: records
        )
    }

    private func evaluate(
        _ queryCase: QueryCase,
        policy: SearchFeaturePolicy,
        policyName: String,
        engine: SearchEngine,
        database: AppDatabase
    ) async throws -> QueryRecord {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let response = try await engine.search(
            query: queryCase.query,
            featurePolicy: policy,
            recordsUserTiming: false
        )
        let latency = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        let surfacedResults = response.results.isEmpty ? response.fallbackResults : response.results
        let topFive = Array(surfacedResults.prefix(5))
        var failures: [String] = []

        if queryCase.expectedEmpty && !surfacedResults.isEmpty {
            failures.append("\(policyName) '\(queryCase.query)' expected zero visible results, got \(surfacedResults.count)")
        } else if !queryCase.expectedEmpty && surfacedResults.isEmpty {
            failures.append("\(policyName) '\(queryCase.query)' expected visible results, got none")
        }
        if surfacedResults.contains(where: { !$0.score.isFinite }) {
            failures.append("\(policyName) '\(queryCase.query)' returned a non-finite score")
        }

        if policy.allowsAdvancedQueryFeatures {
            let hints = await QueryParser.parse(query: queryCase.query, featurePolicy: policy)
            let locationMatcher = hints.locationHint.map {
                LocationMatcher.makeMatcher(
                    queryLower: $0,
                    locality: hints.locationLocality,
                    adminArea: hints.locationAdminArea,
                    country: hints.locationCountryName
                )
            }
            for result in topFive where !result.isVideo {
                guard let index = try database.loadPhotoEmbedding(id: result.id), index.count == 1 else {
                    failures.append("\(policyName) '\(queryCase.query)' could not reload result \(result.id)")
                    continue
                }
                if let locationMatcher,
                   !locationMatcher(
                       index.locationCities[0],
                       index.locationStates[0],
                       index.locationCountries[0],
                       index.locationNames[0]
                   ) {
                    failures.append("\(policyName) '\(queryCase.query)' leaked location-mismatched result \(result.localIdentifier)")
                }
                if let dateRange = hints.dateRange,
                   let date = index.dates[0],
                   !(date >= dateRange.start && date <= dateRange.end) {
                    failures.append("\(policyName) '\(queryCase.query)' leaked out-of-range result \(result.localIdentifier)")
                }
                if hints.dateRange != nil && index.dates[0] == nil {
                    failures.append("\(policyName) '\(queryCase.query)' leaked a result without a date")
                }
            }
        } else {
            let requested = QueryParserFallback.parse(query: queryCase.query)
            let needsRestriction = requested.locationHint != nil
                || requested.dateRange != nil
                || !requested.negativeTerms.isEmpty
                || requested.timeOfDayHours != nil
            if needsRestriction && response.restrictionSummary == nil {
                failures.append("free '\(queryCase.query)' omitted its Pro restriction summary")
            }
            if response.filtersApplied?.dateDescription != nil
                || response.filtersApplied?.locationDescription != nil {
                failures.append("free '\(queryCase.query)' unexpectedly applied a Pro date/location filter")
            }
        }

        return QueryRecord(
            query: queryCase.query,
            policy: policyName,
            resultCount: response.results.count,
            fallbackCount: response.fallbackResults.count,
            surfacedCount: surfacedResults.count,
            topFiveIdentifiers: topFive.map(\.localIdentifier),
            topFiveScores: topFive.map(\.score),
            dateFilter: response.filtersApplied?.dateDescription,
            locationFilter: response.filtersApplied?.locationDescription,
            visualQuery: response.filtersApplied?.visualQuery,
            restrictions: restrictionNames(response.restrictionSummary),
            latencyMilliseconds: latency,
            validationFailures: failures
        )
    }

    private func restrictionNames(_ summary: SearchRestrictionSummary?) -> [String] {
        guard let summary else { return [] }
        return summary.features.map {
            switch $0 {
            case .location: "location"
            case .date: "date"
            case .exclusions: "exclusions"
            case .timeOfDay: "timeOfDay"
            }
        }.sorted()
    }

    private func saveOriginalMetadataIfNeeded(_ assets: [PHAsset]) throws {
        let url = try harnessDirectory().appendingPathComponent("original-metadata-v1.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let stored = assets.map {
            StoredMetadata(
                localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate,
                latitude: $0.location?.coordinate.latitude,
                longitude: $0.location?.coordinate.longitude
            )
        }
        try writeJSON(stored, to: url)
    }

    private func saveSeed(_ assignments: [String: Assignment]) throws {
        let payload = StoredSeed(
            version: 1,
            generatedAt: Date(),
            assignments: assignments.map { identifier, assignment in
                StoredSeedAssignment(
                    localIdentifier: identifier,
                    creationDate: assignment.date,
                    latitude: assignment.place?.latitude,
                    longitude: assignment.place?.longitude,
                    placeKey: assignment.place?.key,
                    source: assignment.source
                )
            }.sorted { $0.localIdentifier < $1.localIdentifier }
        )
        try writeJSON(payload, to: try harnessDirectory().appendingPathComponent("seed-metadata-v1.json"))
    }

    private func save(report: QueryReport) throws {
        try writeJSON(report, to: try harnessDirectory().appendingPathComponent("query-report-v1.json"))
    }

    private func harnessDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimulatorDatasetHarness", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: 15
        ))!
    }

    private var proQueries: [QueryCase] {
        let raw = [
            "dog", "cat", "car", "bicycle", "flowers", "mountains", "beach", "snow", "book", "coffee cup",
            "hiking", "wedding", "party", "sunset", "street at night", "inside a museum", "concert crowd", "swimming pool", "forest trail", "city skyline",
            "selfie", "group photo", "kids playing", "portrait of a woman", "my dog on the sofa", "two cats together", "people laughing", "baby sleeping",
            "lunch", "dinner table", "breakfast", "brunch", "pizza", "cocktail", "coffee shop",
            "Berlin", "California", "Paris", "Germany", "New York", "San Diego", "Bavaria", "CA", "Los Angeles",
            "dog in Berlin", "beach in California", "food in Paris", "sunset in Germany", "mountains in Bavaria", "street art in Berlin", "coffee in New York",
            "2022", "2023", "last year", "last summer", "December", "January 2023", "yesterday", "last week",
            "dog 2022", "beach last summer", "snow in December", "birthday last year", "hiking 2023", "food last week",
            "California 2022", "Berlin last summer", "dog in Berlin 2023", "Paris December", "beach in California last year", "Germany 2022",
            "morning coffee", "sunrise", "afternoon walk", "evening dinner", "night sky", "late night", "midday",
            "-dog", "dog not cat", "beach without people", "food not dessert", "car without snow", "portrait not selfie", "mountains not winter",
            "screenshot", "receipt", "menu", "boarding pass", "whiteboard", "street sign", "text message",
            "california", "berlin", "Hoover Dam", "Golden Gate Bridge", "Sunrise", "Sydney", "Georgia", "Paris Hilton", "May", "Turkey",
            "?????", "🐕 beach", "München", "東京", String(repeating: "very long dog beach query ", count: 30),
            "dog; DROP TABLE indexed_photos; --", "dog     with     many     spaces"
        ]
        var cases = raw.map { QueryCase($0) }
        cases.append(QueryCase("a", expectedEmpty: true))
        cases.append(QueryCase("Antarctica", expectedEmpty: true))
        cases.append(QueryCase("dog in Antarctica", expectedEmpty: true))
        return cases
    }

    private var freeTierQueries: [QueryCase] {
        [
            "Berlin", "California", "Paris", "Germany", "New York", "San Diego", "Bavaria", "Antarctica", "CA", "Los Angeles",
            "dog in Berlin", "beach in California", "food in Paris", "sunset in Germany", "dog in Antarctica", "mountains in Bavaria", "street art in Berlin", "coffee in New York",
            "2022", "2023", "last year", "last summer", "December", "January 2023", "yesterday", "last week",
            "dog 2022", "beach last summer", "snow in December", "birthday last year", "hiking 2023", "food last week",
            "California 2022", "Berlin last summer", "dog in Berlin 2023", "Paris December", "beach in California last year", "Germany 2022",
            "morning coffee", "sunrise", "afternoon walk", "evening dinner", "night sky", "late night", "midday",
            "dog not cat", "beach without people", "food not dessert", "car without snow", "portrait not selfie", "mountains not winter"
        ].map { QueryCase($0) }
    }
}

private enum DatasetHarnessError: Error {
    case photoKitMutationFailed
}
#endif
