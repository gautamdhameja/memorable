import Foundation

// MARK: - Source Types

enum PhotoSourceType: String {
    case photokit = "photokit"
    case folder = "folder"
}

enum PhotoSourcePolicy {
    static let maximumFolderSources = 32

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func pathsOverlap(_ first: String, _ second: String) -> Bool {
        let first = canonicalPath(URL(fileURLWithPath: first))
        let second = canonicalPath(URL(fileURLWithPath: second))
        guard first != second else { return true }
        return isAncestor(first, of: second) || isAncestor(second, of: first)
    }

    private static func isAncestor(_ candidate: String, of path: String) -> Bool {
        if candidate == "/" {
            return path.hasPrefix("/") && path != "/"
        }
        return path.hasPrefix(candidate + "/")
    }
}

enum PhotoSourceRegistrationError: LocalizedError, Equatable {
    case duplicateFolder
    case overlappingFolder
    case sourceLimitReached

    var errorDescription: String? {
        switch self {
        case .duplicateFolder:
            return "This folder is already added."
        case .overlappingFolder:
            return "Choose a folder that is not inside an added folder and does not contain one."
        case .sourceLimitReached:
            return "You can add up to \(PhotoSourcePolicy.maximumFolderSources) folders."
        }
    }
}

// MARK: - Copy

enum AppCopy {
    /// User-facing disclaimer shown wherever search results are displayed.
    /// Keep in sync across SearchView and MoreView.
    static let aiDisclaimer = "Memorable's search uses on-device AI and can make mistakes."
}

// MARK: - UserDefaults Keys

enum AppKeys {
    // Keys must match what was originally shipped — do not rename
    static let onboardingComplete = "onboarding_complete"
    static let startIndexAfterOnboarding = "start_index_after_onboarding"
    static let surpriseValidatedQueries = "memorable_validated_surprise_queries"
    static let surpriseLastValidatedCount = "memorable_surprise_last_validated_count"
    static let persistentStoreReset = "storage.resetPersistentStoreOnNextLaunch"
    static let persistentStoreResetStoreDeleted = "storage.resetPersistentStoreFilesDeleted"
    static let folderBookmarkPrefix = "folder_bookmark_"

    static func folderBookmark(sourceId: String) -> String {
        "\(folderBookmarkPrefix)\(sourceId)"
    }
}

enum MemoryConfig {
    static let maximumOnThisDayYears = 50
    static let maximumOnThisDayPhotosPerYear = 100
}

// MARK: - Search Scoring

enum SearchConfig {
    /// Minimum similarity score to include a result.
    /// SigLIP2 (sigmoid loss) produces lower raw cosine similarities than
    /// softmax-based CLIP models. Matching pairs typically score 0.10-0.25.
    static let minimumScoreThreshold: Float = 0.12

    /// Duplicate detection threshold (cosine similarity for near-identical images)
    static let duplicateThreshold: Float = 0.95

    /// Max results per search
    static let topK = 50

    /// Max results for location-only and sparse CLIP fallback queries
    static let locationResultsCap = 500

    /// Sparse CLIP fallback: minimum result count below which fallback triggers
    static let sparseClipMinResults = 5

    /// Sparse CLIP fallback: max ratio of results to candidates for fallback to trigger
    static let sparseClipMaxRatio = 0.1

    /// Sparse CLIP fallback: minimum top-candidate score to show results in the
    /// main grid. Below this, results are demoted to the "Other X photos" fallback
    /// section. Prevents irrelevant location-filtered photos from filling the grid
    /// when no actual visual matches exist (e.g., "dog in California" with no dog
    /// photos in California).
    static let sparseClipMinScore: Float = 0.07

    // Location proximity boost (additive, applied within the filtered radius)
    // These are mild -- the hard filter already removed irrelevant locations.
    // Scaled for SigLIP2's lower score range.
    static let locationCloseBoost: Float = 0.025   // Within 10% of radius
    static let locationNearBoost: Float = 0.015    // Within 30% of radius

    // Time-of-day boost (boost only, no penalty for wrong time)
    static let timeOfDayMatchBoost: Float = 0.03

    // Negative term penalty weight (multiplier on negative similarity)
    static let negativeTermWeight: Float = 0.3

    // OCR text boost per matching word (scaled by match ratio)
    static let ocrBoostPerWord: Float = 0.08

    // Scene label boost per matching label (additive on top of similarity)
    static let sceneLabelBoostPerMatch: Float = 0.04

    // Video frames lack scene labels, OCR text, and location-name boosts
    // that photos receive. This flat compensation partially offsets the
    // asymmetry so that a genuinely relevant video isn't buried under
    // photos whose scores were inflated by non-similarity boosts.
    static let videoRelevanceCompensation: Float = 0.03

}

// MARK: - Known Single-Word City Names

/// Used by QueryParser Strategy 3 and SmartQueryParser to distinguish
/// genuine city names from pet names, people names, and other proper nouns
/// when the input is a single capitalized word. Multi-word place names
/// ("San Diego", "New York") don't need this list because they're far
/// less ambiguous. NLTagger (Strategy 1) catches most well-known cities,
/// so this is the fallback for cases it misses.
///
/// Loaded from Resources/known_cities.json (9,695 single-word cities with
/// population >= 50,000, sourced from dr5hn/countries-states-cities-database).
enum KnownCities {
    static let singleWord: Set<String> = {
        guard let url = Bundle.main.url(forResource: "known_cities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            logger.error("Failed to load known_cities.json")
            return []
        }
        return Set(names)
    }()
}

/// Single-word country and state/province names for Strategy 3 location
/// detection. Cities are population-filtered in KnownCities; regions don't
/// need population filtering since there are far fewer of them.
///
/// Loaded from Resources/known_regions.json (4,036 single-word countries and
/// states/provinces, sourced from dr5hn/countries-states-cities-database).
enum KnownRegions {
    static let singleWord: Set<String> = {
        guard let url = Bundle.main.url(forResource: "known_regions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            logger.error("Failed to load known_regions.json")
            return []
        }
        return Set(names)
    }()
}

// MARK: - Scene Label Synonyms

enum SceneLabelConfig {
    static let synonyms: [String: Set<String>] = [
        "lunch": ["food", "restaurant", "dining", "meal", "eating"],
        "dinner": ["food", "restaurant", "dining", "meal", "eating"],
        "breakfast": ["food", "restaurant", "dining", "meal", "coffee", "eating"],
        "food": ["food", "restaurant", "dining", "meal", "eating"],
        "brunch": ["food", "restaurant", "dining", "coffee", "eating"],
        "beach": ["beach", "ocean", "water", "sand", "coast"],
        "hiking": ["outdoor", "mountain", "trail", "nature", "hill"],
        "party": ["celebration", "people", "indoor", "crowd"],
        "wedding": ["celebration", "people", "formal", "dress"],
        "selfie": ["selfie", "portrait", "face"],
        "dog": ["dog", "animal", "pet"],
        "cat": ["cat", "animal", "pet"],
        "car": ["car", "vehicle", "road", "driving"],
        "sunset": ["sunset", "sky", "outdoor", "horizon"],
        "snow": ["snow", "winter", "outdoor", "cold"],
        "garden": ["garden", "flower", "plant", "outdoor"],
        "pool": ["pool", "swimming", "water"],
        "coffee": ["coffee", "cafe", "drink", "food"],
        "street": ["street", "urban", "building", "outdoor", "city"],
        "market": ["market", "shopping", "outdoor", "food", "crowd"],
        "mountain": ["mountain", "hill", "outdoor", "nature", "landscape"],
        "forest": ["forest", "tree", "nature", "outdoor", "wood"],
        "rain": ["rain", "weather", "outdoor", "wet"],
        "night": ["night", "dark", "light", "city"],
        "river": ["river", "water", "nature", "outdoor"],
        "lake": ["lake", "water", "nature", "outdoor"],
    ]
}

// MARK: - Time-of-Day Ranges

/// Meal/activity keywords mapped to hour ranges (24h).
/// Used by both SmartQueryParser and QueryParserFallback.
enum TimeOfDayConfig {
    struct Entry {
        let keywords: [String]
        let startHour: Int
        let endHour: Int  // Can wrap past midnight, e.g. (20, 4)
    }

    static let entries: [Entry] = [
        Entry(keywords: ["breakfast", "morning coffee", "morning run", "morning walk", "sunrise"], startHour: 5, endHour: 10),
        Entry(keywords: ["brunch", "mid-morning", "late morning"], startHour: 9, endHour: 12),
        Entry(keywords: ["lunch", "midday", "noon", "afternoon tea"], startHour: 11, endHour: 14),
        Entry(keywords: ["afternoon", "evening walk"], startHour: 14, endHour: 18),
        Entry(keywords: ["dinner", "supper", "evening", "sunset"], startHour: 18, endHour: 22),
        Entry(keywords: ["night", "nighttime", "night out", "night sky", "late night", "midnight"], startHour: 20, endHour: 4),
    ]

    /// Detect time-of-day from a lowercased query string
    static func detect(in text: String) -> (start: Int, end: Int)? {
        for entry in entries {
            if entry.keywords.contains(where: { text.contains($0) }) {
                return (entry.startHour, entry.endHour)
            }
        }
        return nil
    }
}

// MARK: - Indexing

enum IndexingConfig {
    /// Photos per DB transaction
    static let batchInsertSize = 20

    /// Failed enrichment loads are retried by a later pass, not repeatedly in
    /// the same pass while the underlying media is still unavailable.
    static let enrichmentRetryDelaySeconds: TimeInterval = 24 * 60 * 60

    /// Images retained by one indexing batch. Keep this small because model
    /// prediction and decoded image buffers can overlap during cancellation.
    static let batchEncodeSize = 4

    /// First photo count at which a new index should become searchable.
    static let firstSearchableCheckpoint = 500

    /// Subsequent photo count interval for progressive search refreshes.
    static let searchableCheckpointInterval = 500

    /// Minimum number of newly indexed items between full-index reloads for
    /// very large libraries, where each reload scans the full persisted index.
    static let largeLibrarySearchableCheckpointInterval = 5_000

    /// Library size at which progressive reloads switch to the larger interval.
    static let largeLibraryProgressiveReloadThreshold = 20_000

    /// Minimum time between progressive search index reloads.
    static let minSearchReloadIntervalSeconds: TimeInterval = 5

    /// Number of batches allowed to be loaded ahead of the encoder.
    static let prefetchBatchCapacity = 1

    /// Photos processed per enrichment fetch/update batch.
    static let enrichmentBatchSize = 20

    /// Completed items needed before speed/ETA estimates are shown.
    static let progressEstimateMinCompleted = 5

    /// Max photos for duplicate scanning
    static let maxDuplicateScanPhotos = 10_000

    /// Orphan cleanup safety: skip if more than this fraction appear deleted
    static let maxOrphanRatio = 0.2

    /// SurpriseQueries: skip revalidation if index grew less than this fraction
    static let surpriseRevalidationGrowth = 0.1

    /// Library size above which a "large library" warning is shown
    static let largeLibraryThreshold = 100_000

    /// Automatic resume waits until the shell and core search warmup have had
    /// a chance to settle. User-initiated indexing still starts immediately.
    static let postLaunchAutoResumeDelaySeconds: TimeInterval = 8

    /// Surprise validation performs many searches, so it runs only after base
    /// search is usable and other indexing work is no longer in the critical path.
    static let surpriseValidationDelaySeconds: TimeInterval = 5
}

// MARK: - Timeouts

enum TimeoutConfig {
    /// Thumbnail and image loading from PHImageManager
    static let imageLoad: Double = 10

    /// Video asset and Quick Look file loading
    static let videoLoad: Double = 15
}

// MARK: - Video Frame Extraction

enum VideoFrameConfig {
    static func frameCount(forDuration seconds: Double) -> Int {
        if seconds < 10 { return 2 }
        else if seconds <= 60 { return 3 }
        else { return 5 }
    }
}
