import Foundation

struct RecentSearchPreview: Equatable, Sendable {
    let query: String
    let result: SearchResult
    let resultCount: Int

    init(query: String, result: SearchResult, resultCount: Int) {
        self.query = QueryInputPolicy.bounded(query)
        self.result = result
        self.resultCount = max(0, resultCount)
    }
}

struct RecentSearchHomeItem: Identifiable, Equatable {
    let historyIndex: Int
    let query: String
    let preview: RecentSearchPreview?

    var id: Int { historyIndex }
}

enum RecentSearchHomePolicy {
    static let maximumVisibleCount = 3

    static func items(
        history: [String],
        previews: [RecentSearchPreview]
    ) -> [RecentSearchHomeItem] {
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
