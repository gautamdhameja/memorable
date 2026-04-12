import Foundation

// MARK: - Source Types

enum PhotoSourceType: String {
    case photokit = "photokit"
    case folder = "folder"
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
    static let surpriseValidatedQueries = "memorable_validated_surprise_queries"
    static let surpriseLastValidatedCount = "memorable_surprise_last_validated_count"

    static func folderBookmark(sourceId: String) -> String {
        "folder_bookmark_\(sourceId)"
    }
}

// MARK: - Search Scoring

enum SearchConfig {
    /// Minimum similarity score to include a result (both raw CLIP and boosted)
    static let minimumScoreThreshold: Float = 0.20

    /// Duplicate detection threshold
    static let duplicateThreshold: Float = 0.95

    /// Max results per search
    static let topK = 50

    /// Max results for location-only and sparse CLIP fallback queries
    static let locationResultsCap = 500

    /// Sparse CLIP fallback: minimum result count below which fallback triggers
    static let sparseClipMinResults = 5

    /// Sparse CLIP fallback: max ratio of results to candidates for fallback to trigger
    static let sparseClipMaxRatio = 0.1

    // Location proximity boost (additive, applied within the filtered radius)
    // These are mild — the hard filter already removed irrelevant locations
    static let locationCloseBoost: Float = 0.05    // Within 10% of radius
    static let locationNearBoost: Float = 0.03     // Within 30% of radius

    // Time-of-day boost (boost only — no penalty for wrong time)
    static let timeOfDayMatchBoost: Float = 0.06

    // Negative term penalty weight
    static let negativeTermWeight: Float = 0.3

    // OCR text boost per matching word (scaled by match ratio)
    static let ocrBoostPerWord: Float = 0.15

    // Scene label boost per matching label (additive on top of CLIP)
    static let sceneLabelBoostPerMatch: Float = 0.08

    // Video frames lack scene labels, OCR text, and location-name boosts
    // that photos receive. This flat compensation partially offsets the
    // asymmetry so that a genuinely relevant video isn't buried under
    // photos whose scores were inflated by non-CLIP boosts.
    static let videoRelevanceCompensation: Float = 0.08

    // Relevance badge color tiers (applied in PhotoThumbnailView)
    static let strongMatchThreshold: Float = 0.32
    static let marginalMatchThreshold: Float = 0.22
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

    /// Images per Core ML batch prediction
    static let batchEncodeSize = 16

    /// Max photos for duplicate scanning
    static let maxDuplicateScanPhotos = 10_000

    /// Orphan cleanup safety: skip if more than this fraction appear deleted
    static let maxOrphanRatio = 0.2

    /// SurpriseQueries: skip revalidation if index grew less than this fraction
    static let surpriseRevalidationGrowth = 0.1

    /// Library size above which a "large library" warning is shown
    static let largeLibraryThreshold = 100_000
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
