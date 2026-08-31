import Foundation

enum SurpriseQueryCache {
    struct State: Codable, Equatable {
        var validatedQueries: [String]
        var lastValidatedCount: Int
    }

    static func fileURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = appSupport
            .appendingPathComponent("Memorable", isDirectory: true)
            .appendingPathComponent("LocalState", isDirectory: true)
        try LocalOnlyStorage.prepareDirectory(at: directory)
        return directory.appendingPathComponent("surprise-query-cache.json")
    }

    static func load() -> State {
        migrateLegacyDefaults()
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                return State(validatedQueries: [], lastValidatedCount: 0)
            }
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } catch {
            logger.error("[SurpriseQueryCache] Load failed: \(error.safeDiagnosticCode)")
            return State(validatedQueries: [], lastValidatedCount: 0)
        }
    }

    static func save(_ state: State) {
        do {
            let url = try fileURL()
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try LocalOnlyStorage.excludeFromBackup(url)
        } catch {
            logger.error("[SurpriseQueryCache] Save failed: \(error.safeDiagnosticCode)")
        }
    }

    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let queries = defaults.stringArray(forKey: AppKeys.surpriseValidatedQueries)
        let count = defaults.object(forKey: AppKeys.surpriseLastValidatedCount) == nil
            ? nil
            : defaults.integer(forKey: AppKeys.surpriseLastValidatedCount)
        guard queries != nil || count != nil else { return }

        if let queries, let count {
            save(State(validatedQueries: queries, lastValidatedCount: count))
        } else if let queries {
            save(State(validatedQueries: queries, lastValidatedCount: 0))
        } else if let count {
            save(State(validatedQueries: [], lastValidatedCount: count))
        }
        // This cache is derived and rebuildable. Remove backup-eligible legacy
        // values even if local persistence is unavailable.
        defaults.removeObject(forKey: AppKeys.surpriseValidatedQueries)
        defaults.removeObject(forKey: AppKeys.surpriseLastValidatedCount)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: AppKeys.surpriseValidatedQueries)
        UserDefaults.standard.removeObject(forKey: AppKeys.surpriseLastValidatedCount)
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum SurpriseQueryValidationOperation {
    static func run(
        candidates: [String],
        evaluate: (String) async throws -> Bool,
        persist: ([String]) -> Void,
        onError: (Error) -> Void
    ) async throws {
        var valid: [String] = []
        for query in candidates {
            try Task.checkCancellation()
            do {
                if try await evaluate(query) {
                    valid.append(query)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onError(error)
            }
        }
        try Task.checkCancellation()
        persist(valid)
    }
}

class SurpriseQueries {
    static let candidates = [
        "golden hour",
        "laughing together",
        "rainy day",
        "sunset over water",
        "birthday celebration",
        "snow falling",
        "autumn leaves",
        "city lights at night",
        "flowers in bloom",
        "cooking in the kitchen",
        "road trip",
        "best friends",
        "morning coffee",
        "beach waves",
        "mountain view",
        "a cozy evening",
        "playing with a pet",
        "holiday dinner",
        "first day of school",
        "dancing",
        "sleeping peacefully",
        "fireworks",
        "a beautiful sky",
        "hiking trail",
        "street art",
        "a crowded market",
        "a quiet moment",
        "celebrating together",
        "selfie",
        "food on a plate",
        "trees and greenery",
        "group photo",
        "water and reflections",
        "animals",
        "buildings and architecture",
        "night sky",
        "children playing",
        "a sunny day",
        "rain and umbrellas",
        "books and reading",
    ]

    /// Validated queries that are known to match photos in this user's library.
    static func loadValidated() -> [String] {
        SurpriseQueryCache.load().validatedQueries
    }

    /// Pick a random query from validated set, or from candidates if none validated yet.
    static func random() -> String {
        let validated = loadValidated()
        if !validated.isEmpty {
            return validated.randomElement() ?? "a beautiful memory"
        }
        return candidates.randomElement() ?? "a beautiful memory"
    }

    /// Run all candidate queries against the search engine and keep only those
    /// that return at least one result above the score threshold.
    /// Call this after indexing completes.
    static func validateQueries(using searchEngine: SearchEngine) async {
        // Throttle: only re-validate if index grew by >10%
        let currentSize = searchEngine.indexSize
        let lastSize = SurpriseQueryCache.load().lastValidatedCount
        if lastSize > 0 {
            let growth = Double(currentSize - lastSize) / Double(max(lastSize, 1))
            if growth < IndexingConfig.surpriseRevalidationGrowth && currentSize > 0 {
                return // Skip validation, index hasn't changed enough
            }
        }

        do {
            try await SurpriseQueryValidationOperation.run(
                candidates: candidates,
                evaluate: { query in
                    let response = try await searchEngine.search(
                        query: query,
                        recordsUserTiming: false
                    )
                    return !response.results.isEmpty
                },
                persist: { valid in
                    SurpriseQueryCache.save(.init(
                        validatedQueries: valid,
                        lastValidatedCount: currentSize
                    ))
                },
                onError: { error in
                    logger.error("[SurpriseQueries] Validation failed: \(error.safeDiagnosticCode)")
                }
            )
        } catch is CancellationError {
            return
        } catch {
            logger.error("[SurpriseQueries] Validation stopped: \(error.safeDiagnosticCode)")
        }
    }

    /// Clear cached validated queries (e.g. after re-indexing).
    static func clearValidated() {
        SurpriseQueryCache.clear()
    }
}
