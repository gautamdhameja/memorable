import Foundation

class SearchHistory {
    private static var db: DatabaseProtocol { AppDatabase.shared }

    static func add(query: String) {
        do {
            try db.addSearchHistory(QueryInputPolicy.bounded(query))
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
