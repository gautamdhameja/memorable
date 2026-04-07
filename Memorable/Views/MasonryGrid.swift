import SwiftUI

/// Reusable masonry layout with varied row patterns for a more organic feel.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let content: (Item) -> Content

    init(_ items: [Item], spacing: CGFloat = 10, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    private enum MasonryRow: Identifiable {
        case feature(Item)
        case pair(Item, Item)
        case triple(Item, Item, Item)
        case single(Item)

        var id: String {
            switch self {
            case .feature(let item): return "f_\(item.id)"
            case .pair(let a, let b): return "p_\(a.id)_\(b.id)"
            case .triple(let a, let b, let c): return "t_\(a.id)_\(b.id)_\(c.id)"
            case .single(let item): return "s_\(item.id)"
            }
        }
    }

    // Pattern types with rough probabilities:
    // After a feature: always pairs/triples (2-4 rows) before next feature
    // Varies the count of pairs between features so it doesn't feel repetitive
    private var rows: [MasonryRow] {
        guard !items.isEmpty else { return [] }
        var result: [MasonryRow] = []
        var i = 0

        // First item is always a feature
        result.append(.feature(items[i]))
        i += 1

        // Use item count as seed for deterministic but varied patterns
        let patterns: [Int] = [2, 3, 4, 2, 3, 5, 2, 4, 3, 2]
        var patternIndex = 0
        var rowsSinceFeature = 0
        let featureInterval = { () -> Int in
            let interval = patterns[patternIndex % patterns.count]
            patternIndex += 1
            return interval
        }
        var currentInterval = featureInterval()

        while i < items.count {
            let remaining = items.count - i

            // Time for a feature row?
            if rowsSinceFeature >= currentInterval && remaining >= 3 {
                result.append(.feature(items[i]))
                i += 1
                rowsSinceFeature = 0
                currentInterval = featureInterval()
                continue
            }

            // Alternate between pairs and occasional triples
            let useTriple = rowsSinceFeature > 0 && (rowsSinceFeature % 3 == 0) && remaining >= 3
            if useTriple {
                result.append(.triple(items[i], items[i + 1], items[i + 2]))
                i += 3
            } else if remaining >= 2 {
                result.append(.pair(items[i], items[i + 1]))
                i += 2
            } else {
                result.append(.single(items[i]))
                i += 1
            }
            rowsSinceFeature += 1
        }

        return result
    }

    var body: some View {
        LazyVStack(spacing: spacing) {
            ForEach(rows) { row in
                switch row {
                case .feature(let item):
                    content(item)
                case .pair(let a, let b):
                    HStack(alignment: .top, spacing: spacing) {
                        content(a)
                            .frame(maxWidth: .infinity)
                        content(b)
                            .frame(maxWidth: .infinity)
                    }
                case .triple(let a, let b, let c):
                    HStack(alignment: .top, spacing: spacing) {
                        content(a)
                            .frame(maxWidth: .infinity)
                        content(b)
                            .frame(maxWidth: .infinity)
                        content(c)
                            .frame(maxWidth: .infinity)
                    }
                case .single(let item):
                    content(item)
                }
            }
        }
    }
}

/// Lightweight Identifiable wrapper for raw strings (e.g. PHAsset local identifiers).
struct IdentifiedString: Identifiable {
    let id: String
}
