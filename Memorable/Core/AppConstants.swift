import Foundation

// MARK: - Source Types

enum PhotoSourceType: String {
    case photokit = "photokit"
    case folder = "folder"
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

    // Location proximity boost (applied within the filtered radius)
    // These are mild — the hard filter already removed irrelevant locations
    static let locationCloseBoost: Float = 1.15   // Within 10% of radius
    static let locationNearBoost: Float = 1.08     // Within 30% of radius

    // Time-of-day boost (boost only — no penalty for wrong time)
    static let timeOfDayMatchBoost: Float = 1.3

    // Negative term penalty weight
    static let negativeTermWeight: Float = 0.3

    // OCR text boost per matching word (scaled by match ratio)
    static let ocrBoostPerWord: Float = 0.15
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
