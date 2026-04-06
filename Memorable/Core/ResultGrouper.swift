import Foundation

enum ResultGrouper {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    static func groupByMonth(results: [SearchResult]) -> [SearchResultGroup] {
        var groups: [String: [SearchResult]] = [:]
        var order: [String] = []

        for result in results {
            let key = result.creationDate.map { formatter.string(from: $0) } ?? "Unknown Date"
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append(result)
        }

        return order.map { key in
            SearchResultGroup(id: key, label: key, results: groups[key] ?? [])
        }
    }
}
