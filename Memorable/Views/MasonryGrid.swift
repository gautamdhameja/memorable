import SwiftUI

/// Reusable masonry layout: first item full-width, then pairs, with a feature every 3rd pair.
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
        case single(Item)

        var id: String {
            switch self {
            case .feature(let item): return "f_\(item.id)"
            case .pair(let a, let b): return "p_\(a.id)_\(b.id)"
            case .single(let item): return "s_\(item.id)"
            }
        }
    }

    private var rows: [MasonryRow] {
        guard !items.isEmpty else { return [] }
        var result: [MasonryRow] = []
        var i = 0

        result.append(.feature(items[i]))
        i += 1

        var pairCount = 0
        while i < items.count {
            if i + 1 < items.count {
                result.append(.pair(items[i], items[i + 1]))
                i += 2
                pairCount += 1
                if pairCount % 3 == 0 && i < items.count {
                    result.append(.feature(items[i]))
                    i += 1
                }
            } else {
                result.append(.single(items[i]))
                i += 1
            }
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
