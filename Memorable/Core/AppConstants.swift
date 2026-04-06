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

