import Foundation

enum SurpriseQueryCache {
    struct State: Codable, Equatable {
        var validatedQueries: [String]
        var lastValidatedCount: Int
        var contentRevision: SearchIndexContentRevision?

        init(
            validatedQueries: [String],
            lastValidatedCount: Int,
            contentRevision: SearchIndexContentRevision? = nil
        ) {
            self.validatedQueries = validatedQueries
            self.lastValidatedCount = lastValidatedCount
            self.contentRevision = contentRevision
        }
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
    ) async throws -> [String] {
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
        return valid
    }
}

class SurpriseQueries {
    static let cachedRevalidationLimit = 3

    struct ValidationPlan {
        let candidates: [String]
        let persistedCount: Int
        let revalidatesCachedSubset: Bool
        let reusesUnchangedCache: Bool
    }

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

    /// Recheck a bounded cached shortlist on routine launches, but retain the
    /// full-validation baseline so small index additions accumulate toward the
    /// threshold that refreshes the complete candidate pool.
    static func validationPlan(
        cachedState: SurpriseQueryCache.State,
        currentSize: Int,
        currentRevision: SearchIndexContentRevision? = nil
    ) -> ValidationPlan {
        if let currentRevision,
           cachedState.contentRevision == currentRevision {
            return ValidationPlan(
                candidates: [],
                persistedCount: cachedState.lastValidatedCount,
                revalidatesCachedSubset: false,
                reusesUnchangedCache: true
            )
        }
        let lastSize = cachedState.lastValidatedCount
        let growth = Double(currentSize - lastSize) / Double(max(lastSize, 1))
        let canReuseShortlist = lastSize > 0
            && currentSize >= lastSize
            && growth < IndexingConfig.surpriseRevalidationGrowth
            && currentSize > 0
        if canReuseShortlist {
            return ValidationPlan(
                candidates: Array(
                    cachedState.validatedQueries.shuffled().prefix(cachedRevalidationLimit)
                ),
                persistedCount: lastSize,
                revalidatesCachedSubset: true,
                reusesUnchangedCache: false
            )
        }
        return ValidationPlan(
            candidates: candidates,
            persistedCount: currentSize,
            revalidatesCachedSubset: false,
            reusesUnchangedCache: false
        )
    }

    static func updatedCacheState(
        validatedQueries: [String],
        plan: ValidationPlan,
        previous: SurpriseQueryCache.State,
        currentRevision: SearchIndexContentRevision? = nil
    ) -> SurpriseQueryCache.State {
        let persistedQueries: [String]
        if plan.revalidatesCachedSubset {
            let revalidated = Set(plan.candidates)
            persistedQueries = previous.validatedQueries.filter { !revalidated.contains($0) }
                + validatedQueries
        } else {
            persistedQueries = validatedQueries
        }
        return SurpriseQueryCache.State(
            validatedQueries: persistedQueries,
            lastValidatedCount: plan.persistedCount,
            contentRevision: currentRevision
        )
    }

    /// Run all candidate queries against the search engine and keep only those
    /// that return at least one result above the score threshold.
    /// Call this after indexing completes.
    static func validateQueries(
        using searchEngine: SearchEngine,
        contentRevision: SearchIndexContentRevision
    ) async -> [String] {
        let currentSize = searchEngine.totalSize
        let cachedState = SurpriseQueryCache.load()
        let plan = validationPlan(
            cachedState: cachedState,
            currentSize: currentSize,
            currentRevision: contentRevision
        )
        if plan.reusesUnchangedCache {
            return cachedState.validatedQueries
        }

        do {
            return try await SurpriseQueryValidationOperation.run(
                candidates: plan.candidates,
                evaluate: { query in
                    let response = try await searchEngine.search(
                        query: query,
                        recordsUserTiming: false
                    )
                    return !response.results.isEmpty
                },
                persist: { valid in
                    let state = updatedCacheState(
                        validatedQueries: valid,
                        plan: plan,
                        previous: cachedState,
                        currentRevision: contentRevision
                    )
                    guard state != cachedState else { return }
                    SurpriseQueryCache.save(state)
                },
                onError: { error in
                    logger.error("[SurpriseQueries] Validation failed: \(error.safeDiagnosticCode)")
                }
            )
        } catch is CancellationError {
            return []
        } catch {
            logger.error("[SurpriseQueries] Validation stopped: \(error.safeDiagnosticCode)")
            return []
        }
    }

    /// Clear cached validated queries (e.g. after re-indexing).
    static func clearValidated() {
        SurpriseQueryCache.clear()
    }
}
