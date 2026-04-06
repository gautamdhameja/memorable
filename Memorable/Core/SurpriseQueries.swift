import Foundation

class SurpriseQueries {
    private static let storageKey = AppKeys.surpriseValidatedQueries
    private static let lastValidatedCountKey = AppKeys.surpriseLastValidatedCount

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
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
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
        let lastSize = UserDefaults.standard.integer(forKey: lastValidatedCountKey)
        if lastSize > 0 {
            let growth = Double(currentSize - lastSize) / Double(max(lastSize, 1))
            if growth < 0.1 && currentSize > 0 {
                return // Skip validation, index hasn't changed enough
            }
        }

        var valid: [String] = []

        for query in candidates {
            do {
                let results = try await searchEngine.search(query: query, topK: 3)
                if !results.isEmpty {
                    valid.append(query)
                }
            } catch {
                #if DEBUG
                logger.error("[SurpriseQueries] Validation failed for '\(query)': \(error.localizedDescription)")
                #endif
            }
        }

        UserDefaults.standard.set(valid, forKey: storageKey)
        UserDefaults.standard.set(currentSize, forKey: lastValidatedCountKey)
    }

    /// Clear cached validated queries (e.g. after re-indexing).
    static func clearValidated() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: lastValidatedCountKey)
    }
}
