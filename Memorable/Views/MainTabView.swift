import SwiftUI

enum MainTabDestination: Int {
    case search
    case more

    var title: String {
        switch self {
        case .search: return "Search"
        case .more: return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass"
        case .more: return "ellipsis.circle"
        }
    }
}

enum PrimaryDockMetrics {
    static let itemWidth: CGFloat = 100
    static let surpriseWidth: CGFloat = itemWidth
    static let itemSpacing: CGFloat = 0
    static let horizontalPadding: CGFloat = 16
    static let outerInset: CGFloat = 4
    static let height: CGFloat = 72
    static let iconFrame: CGFloat = 30
    static let iconSize: CGFloat = 20
    static let outerGlassTintOpacity = 0.16
    static let selectionGlassTintOpacity = 0.14
    static let backdropOpacity = 0.52

    static var totalWidth: CGFloat {
        (itemWidth * 2) + surpriseWidth + (itemSpacing * 2) + (horizontalPadding * 2)
    }
}

struct MainTabNavigationState {
    var destination: MainTabDestination
    private(set) var surpriseRequestID: Int
    private(set) var searchHomeRequestID: Int

    init(
        destination: MainTabDestination = .search,
        surpriseRequestID: Int = 0,
        searchHomeRequestID: Int = 0
    ) {
        self.destination = destination
        self.surpriseRequestID = surpriseRequestID
        self.searchHomeRequestID = searchHomeRequestID
    }

    @discardableResult
    mutating func requestSurprise(isAvailable: Bool) -> Bool {
        guard isAvailable else { return false }
        destination = .search
        surpriseRequestID &+= 1
        return true
    }

    @discardableResult
    mutating func requestSearchHome() -> Bool {
        guard destination == .search else { return false }
        searchHomeRequestID &+= 1
        return true
    }
}

struct MainTabView: View {
    var indexingService: IndexingService?
    var searchEngine: SearchEngine?
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let retrySemanticWarmup: () -> Void

    @State private var navigation = MainTabNavigationState()

    var body: some View {
        TabView(selection: $navigation.destination) {
            if let indexingService, let searchEngine, !semanticRuntime.isCheckingIndexAvailability {
                SearchView(
                    indexingService: indexingService,
                    searchEngine: searchEngine,
                    semanticRuntime: semanticRuntime,
                    surpriseRequestID: navigation.surpriseRequestID,
                    searchHomeRequestID: navigation.searchHomeRequestID
                )
                .tag(MainTabDestination.search)
            } else {
                SearchPreparationShell(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tag(MainTabDestination.search)
            }

            if let indexingService, let searchEngine, !semanticRuntime.isCheckingIndexAvailability {
                MoreView(
                    indexingService: indexingService,
                    searchEngine: searchEngine
                )
                    .tag(MainTabDestination.more)
            } else {
                SearchPreparationShell(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tag(MainTabDestination.more)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomDock
        }
        .preferredColorScheme(.dark)
    }

    private var bottomDock: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: PrimaryDockMetrics.itemSpacing) {
                    dockContents
                        .glassEffect(
                            .regular.tint(
                                Celestial.Colors.surfaceContainerLow.opacity(
                                    PrimaryDockMetrics.outerGlassTintOpacity
                                )
                            ),
                            in: .rect(cornerRadius: 30)
                        )
                }
            } else {
                dockContents
                    .background(.ultraThinMaterial, in: dockShape)
                    .background(
                        Celestial.Colors.surfaceContainerLow.opacity(0.42),
                        in: dockShape
                    )
            }
        }
        .overlay { dockSpecularOutline }
        .shadow(color: Color.black.opacity(0.30), radius: 16, y: 8)
        .shadow(color: Celestial.Colors.primary.opacity(0.07), radius: 12, y: -3)
        .padding(.horizontal, PrimaryDockMetrics.outerInset)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(
            LinearGradient(
                colors: [
                    Celestial.Colors.background.opacity(0),
                    Celestial.Colors.background.opacity(PrimaryDockMetrics.backdropOpacity),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var dockContents: some View {
        HStack(spacing: PrimaryDockMetrics.itemSpacing) {
            dockButton(.search)

            if let indexingService {
                SurpriseDockButton(
                    indexingService: indexingService,
                    isSearchAvailable: searchEngine != nil,
                    action: requestSurpriseSearch
                )
            } else {
                SurpriseDockPlaceholder()
            }

            dockButton(.more)
        }
        .frame(height: PrimaryDockMetrics.height)
        .padding(.horizontal, PrimaryDockMetrics.horizontalPadding)
    }

    private func requestSurpriseSearch() {
        let isAvailable = searchEngine != nil
            && indexingService?.canShowValidatedSearchSuggestions == true
        if navigation.destination != .search {
            withAnimation(.easeOut(duration: 0.16)) {
                _ = navigation.requestSurprise(isAvailable: isAvailable)
            }
        } else {
            navigation.requestSurprise(isAvailable: isAvailable)
        }
    }

    private var dockShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
    }

    private var dockSpecularOutline: some View {
        dockShape
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.26),
                        Celestial.Colors.primary.opacity(0.11),
                        Color.white.opacity(0.025),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
    }

    private func dockButton(_ tab: MainTabDestination) -> some View {
        let isSelected = navigation.destination == tab
        let hasNewPhotos = tab == .more && (indexingService?.newPhotosAvailable ?? false)

        return Button {
            if navigation.destination == tab {
                guard tab == .search else { return }
                Haptics.selection()
                withAnimation(.easeOut(duration: 0.16)) {
                    _ = navigation.requestSearchHome()
                }
                return
            }
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.16)) {
                navigation.destination = tab
            }
        } label: {
            VStack(spacing: 4) {
                PrimaryDockGlyph(
                    systemName: tab.systemImage,
                    tint: isSelected
                        ? Celestial.Colors.primary
                        : Celestial.Colors.onSurfaceVariant,
                    showsBadge: hasNewPhotos
                )

                Text(tab.title)
                    .font(
                        isSelected
                            ? Celestial.Typography.microStrong
                            : Celestial.Typography.microEmphasized
                    )
                    .foregroundStyle(
                        isSelected
                            ? Celestial.Colors.primary
                            : Celestial.Colors.onSurfaceVariant
                    )
            }
            .frame(width: PrimaryDockMetrics.itemWidth)
            .frame(height: 60)
            .background {
                PrimaryDockSelectionPill(isSelected: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(hasNewPhotos ? "New photos are available" : "")
    }
}

private struct PrimaryDockGlyph: View {
    let systemName: String
    let tint: Color
    var showsBadge = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: PrimaryDockMetrics.iconSize, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
        .frame(
            width: PrimaryDockMetrics.iconFrame,
            height: PrimaryDockMetrics.iconFrame
        )
        .overlay(alignment: .topTrailing) {
            if showsBadge {
                Circle()
                    .fill(Celestial.Colors.emerald)
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: -1)
            }
        }
    }
}

private struct PrimaryDockSelectionPill: View {
    let isSelected: Bool

    @ViewBuilder
    var body: some View {
        if isSelected {
            Group {
                if #available(iOS 26.0, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(
                                Celestial.Colors.onSurface.opacity(
                                    PrimaryDockMetrics.selectionGlassTintOpacity
                                )
                            ),
                            in: .capsule
                        )
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .background(
                            Celestial.Colors.surfaceContainerHighest.opacity(0.46),
                            in: Capsule()
                        )
                }
            }
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Celestial.Colors.primary.opacity(0.08),
                                Color.white.opacity(0.035),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            }
            .shadow(color: Color.black.opacity(0.18), radius: 7, y: 3)
        }
    }
}

private struct SurpriseDockButton: View {
    @ObservedObject var indexingService: IndexingService
    let isSearchAvailable: Bool
    let action: () -> Void

    private var isAvailable: Bool {
        isSearchAvailable && indexingService.canShowValidatedSearchSuggestions
    }

    var body: some View {
        Button(action: action) {
            SurpriseDockLabel(isAvailable: isAvailable)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel("Surprise me with a photo search")
        .accessibilityValue(isAvailable ? "Available" : "Unavailable")
        .accessibilityHint(
            isAvailable
                ? "Searches your library using a matched suggestion"
                : "Available after indexing and suggestion preparation finish"
        )
    }
}

private struct SurpriseDockPlaceholder: View {
    var body: some View {
        SurpriseDockLabel(isAvailable: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Surprise me with a photo search")
            .accessibilityValue("Unavailable")
            .accessibilityHint("Available after indexing and suggestion preparation finish")
    }
}

private struct SurpriseDockLabel: View {
    let isAvailable: Bool

    var body: some View {
        VStack(spacing: 4) {
            PrimaryDockGlyph(
                systemName: "sparkles",
                tint: Celestial.Colors.amber.opacity(isAvailable ? 1 : 0.38)
            )
            .shadow(
                color: Celestial.Colors.amber.opacity(isAvailable ? 0.38 : 0),
                radius: isAvailable ? 4 : 0
            )

            Text("Surprise me")
                .font(Celestial.Typography.microEmphasized)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(
            Celestial.Colors.amber.opacity(isAvailable ? 1 : 0.38)
        )
        .frame(width: PrimaryDockMetrics.surpriseWidth)
        .frame(height: 60)
        .contentShape(Rectangle())
    }
}

private struct SearchPreparationShell: View {
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let retry: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                CelestialBackdrop()
                VStack(spacing: 0) {
                    HStack {
                        Text("Memorable")
                            .font(Celestial.Typography.brand)
                            .foregroundStyle(Celestial.Colors.onSurface)
                        Spacer()
                    }
                    .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Celestial.Colors.primaryFixedDim)
                            .accessibilityHidden(true)
                        Text("Search your photos...")
                            .font(Celestial.Typography.body)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        Spacer()
                    }
                    .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
                    .frame(minHeight: 52)
                    .modifier(GlassSearchBarModifier(cornerRadius: 13))
                    .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
                    .padding(.top, 20)
                    .disabled(true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Search photos")
                    .accessibilityValue("Unavailable")
                    .accessibilityHint(statusText)

                    if case .failed = semanticRuntime.phase {
                        VStack(alignment: .leading, spacing: Celestial.Spacing.contentGap) {
                            Text("Search setup needs attention")
                                .font(Celestial.Typography.interfaceTitle3)
                                .foregroundStyle(Celestial.Colors.onSurface)
                            Text(statusText)
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            Button("Try Again", action: retry)
                                .celestialPrimaryButtonStyle()
                        }
                        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                        .padding(.top, Celestial.Spacing.sectionGap)
                        Spacer()
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Celestial.Colors.primaryFixedDim)
                                .accessibilityHidden(true)
                            Text(statusText)
                                .font(Celestial.Typography.supporting)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch semanticRuntime.phase {
        case .failed(let message):
            return message
        default:
            return "Preparing search..."
        }
    }
}
