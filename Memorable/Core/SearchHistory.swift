import Foundation

struct RecentSearchPreview: Equatable, Sendable {
    let query: String
    let result: SearchResult
    let resultCount: Int
    let searchedAt: Date?

    init(
        query: String,
        result: SearchResult,
        resultCount: Int,
        searchedAt: Date? = nil
    ) {
        self.query = QueryInputPolicy.bounded(query)
        self.result = result
        self.resultCount = max(0, resultCount)
        self.searchedAt = searchedAt
    }
}

struct RecentSearchHomeItem: Identifiable, Equatable {
    let historyIndex: Int
    let query: String
    let preview: RecentSearchPreview?

    var id: Int { historyIndex }
}

enum SearchHistoryPolicy {
    static let maximumCount = 20
    static let maximumPreviewBackfillCount = 3
}

enum SearchHomePrimarySection: Hashable {
    case todayMemoryLoading
    case todayMemory
    case recentSearches
}

enum SearchHomeLayoutPolicy {
    static func primarySections(
        isTodayMemoryResolved: Bool,
        hasTodayMemory: Bool,
        hasRecentSearches: Bool
    ) -> [SearchHomePrimarySection] {
        var sections: [SearchHomePrimarySection] = []
        if !isTodayMemoryResolved {
            sections.append(.todayMemoryLoading)
        } else if hasTodayMemory {
            sections.append(.todayMemory)
        }
        if hasRecentSearches {
            sections.append(.recentSearches)
        }
        return sections
    }
}

struct TodayMemoryRefreshState: Equatable {
    private(set) var needsRefresh = true
    private(set) var isLoading = false

    mutating func request(canStart: Bool) -> Bool {
        needsRefresh = true
        guard canStart, !isLoading else { return false }
        needsRefresh = false
        isLoading = true
        return true
    }

    mutating func finish(wasCancelled: Bool) -> Bool {
        isLoading = false
        if wasCancelled {
            needsRefresh = true
        }
        return needsRefresh
    }

    mutating func cancel() {
        isLoading = false
        needsRefresh = true
    }
}

enum RecentSearchHomePolicy {
    static let maximumVisibleCount = SearchHistoryPolicy.maximumCount

    static func items<History: Collection>(
        history: History,
        previews: [RecentSearchPreview]
    ) -> [RecentSearchHomeItem] where History.Element == String {
        var previewByQuery: [String: RecentSearchPreview] = [:]
        for preview in previews {
            previewByQuery[key(for: preview.query)] = preview
        }

        return Array(history.prefix(maximumVisibleCount).enumerated()).map { index, query in
            RecentSearchHomeItem(
                historyIndex: index,
                query: query,
                preview: previewByQuery[key(for: query)]
            )
        }
    }

    private static func key(for query: String) -> String {
        QueryInputPolicy.bounded(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func missingPreviewQueries(
        history: [String],
        previews: [RecentSearchPreview]
    ) -> [String] {
        items(
            history: history.prefix(SearchHistoryPolicy.maximumPreviewBackfillCount),
            previews: previews
        ).compactMap { item in
            item.preview == nil ? item.query : nil
        }
    }
}

class SearchHistory {
    private static var db: DatabaseProtocol { AppDatabase.shared }

    static func add(query: String, previewResult: SearchResult, resultCount: Int) {
        do {
            let boundedQuery = QueryInputPolicy.bounded(query)
            try db.addSearchHistory(
                boundedQuery,
                preview: RecentSearchPreview(
                    query: boundedQuery,
                    result: previewResult,
                    resultCount: resultCount
                )
            )
        } catch {
            logger.error("Failed to save search history: \(error.safeDiagnosticCode)")
        }
    }

    static func load() -> [String] {
        do {
            return try db.loadSearchHistory()
        } catch {
            logger.error("Failed to load search history: \(error.safeDiagnosticCode)")
            return []
        }
    }

    static func loadPreviews(limit: Int = RecentSearchHomePolicy.maximumVisibleCount) -> [RecentSearchPreview] {
        do {
            return try db.loadSearchHistoryPreviews(limit: limit)
        } catch {
            logger.error("Failed to load search history previews: \(error.safeDiagnosticCode)")
            return []
        }
    }

    @discardableResult
    static func backfill(previews: [RecentSearchPreview]) -> Bool {
        do {
            try db.backfillSearchHistoryPreviews(previews)
            return true
        } catch {
            logger.error("Failed to backfill search history preview: \(error.safeDiagnosticCode)")
            return false
        }
    }

    static func clear() {
        do {
            try db.clearSearchHistory()
        } catch {
            logger.error("Failed to clear search history: \(error.safeDiagnosticCode)")
        }
    }

    static func remove(at index: Int) {
        do {
            try db.removeSearchHistory(at: index)
        } catch {
            logger.error("Failed to remove search history item: \(error.safeDiagnosticCode)")
        }
    }
}
