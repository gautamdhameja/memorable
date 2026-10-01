import SwiftUI

/// Lays out one row of tiles at a single shared height. Each subview is offered
/// a width proportional to its aspect ratio, so tiles keep their true
/// proportions and the row fills its proposed width without leaving a gap under
/// the shorter tile.
struct JustifiedRow: Layout {
    let aspectRatios: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let ratios = resolvedRatios(count: subviews.count)
        let height = JustifiedRowLayout.rowHeight(
            availableWidth: width,
            aspectRatios: ratios,
            spacing: spacing
        )
        guard height > 0 else {
            // Without a usable width the row cannot be justified; report the
            // tallest subview so the grid still reserves sensible space.
            let fallback = subviews
                .map { $0.sizeThatFits(proposal).height }
                .max() ?? 0
            return CGSize(width: width, height: fallback)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let ratios = resolvedRatios(count: subviews.count)
        let widths = JustifiedRowLayout.widths(
            availableWidth: bounds.width,
            aspectRatios: ratios,
            spacing: spacing
        )
        guard widths.count == subviews.count else { return }
        let height = JustifiedRowLayout.rowHeight(
            availableWidth: bounds.width,
            aspectRatios: ratios,
            spacing: spacing
        )
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = widths[index]
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: width,
                    height: height > 0 ? height : nil
                )
            )
            x += width + spacing
        }
    }

    /// The grid supplies one ratio per tile. Guard anyway so a mismatch falls
    /// back to equal shares instead of dropping tiles.
    private func resolvedRatios(count: Int) -> [CGFloat] {
        guard aspectRatios.count == count else {
            return [CGFloat](repeating: MediaTileAspectRatio.fallback, count: count)
        }
        return aspectRatios
    }
}

/// Reusable masonry layout with varied row patterns for a more organic feel.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let aspectRatio: (Item) -> CGFloat
    let content: (Item) -> Content

    init(
        _ items: [Item],
        spacing: CGFloat = 10,
        aspectRatio: @escaping (Item) -> CGFloat = { _ in MediaTileAspectRatio.fallback },
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.spacing = spacing
        self.aspectRatio = aspectRatio
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

    /// Only landscape tiles span the full width. A full-width square or
    /// portrait tile is taller than most of the screen, so it joins a row
    /// instead and keeps its real proportions there.
    static var featureMinimumAspectRatio: CGFloat { 1.25 }

    private func canFeature(_ item: Item) -> Bool {
        aspectRatio(item) >= Self.featureMinimumAspectRatio
    }

    // After a feature: always pairs/triples (2-5 rows) before the next one.
    // Varies the count of rows between features so it doesn't feel repetitive.
    private var rows: [MasonryRow] {
        guard !items.isEmpty else { return [] }
        var result: [MasonryRow] = []
        var i = 0

        // Lead with the first item when it suits a full-width row.
        if canFeature(items[i]) {
            result.append(.feature(items[i]))
            i += 1
        }

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
            if rowsSinceFeature >= currentInterval && remaining >= 3 && canFeature(items[i]) {
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
            } else if case .pair(let a, let b)? = result.last {
                // A lone last tile would stretch across the whole row.
                result[result.count - 1] = .triple(a, b, items[i])
                i += 1
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
                    justifiedRow([a, b])
                case .triple(let a, let b, let c):
                    justifiedRow([a, b, c])
                case .single(let item):
                    content(item)
                }
            }
        }
    }

    private func justifiedRow(_ rowItems: [Item]) -> some View {
        JustifiedRow(
            aspectRatios: rowItems.map(aspectRatio),
            spacing: spacing
        ) {
            ForEach(rowItems) { item in
                content(item)
            }
        }
    }
}
