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
        case .more: return "line.3.horizontal"
        }
    }
}

enum PrimaryDockMetrics {
    static let itemWidth: CGFloat = 76
    static let surpriseWidth: CGFloat = itemWidth
    static let itemSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 14
    static let height: CGFloat = 68
    static let iconFrame: CGFloat = 32
    static let iconSize: CGFloat = 18

    static var totalWidth: CGFloat {
        (itemWidth * 2) + surpriseWidth + (itemSpacing * 2) + (horizontalPadding * 2)
    }
}

struct MainTabNavigationState {
    var destination: MainTabDestination
    private(set) var surpriseRequestID: Int

    init(
        destination: MainTabDestination = .search,
        surpriseRequestID: Int = 0
    ) {
        self.destination = destination
        self.surpriseRequestID = surpriseRequestID
    }

    @discardableResult
    mutating func requestSurprise(isAvailable: Bool) -> Bool {
        guard isAvailable else { return false }
        destination = .search
        surpriseRequestID &+= 1
        return true
    }
}

struct MainTabView: View {
    var indexingService: IndexingService?
    var searchEngine: SearchEngine?
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let captionService: PhotoCaptionService
    let retrySemanticWarmup: () -> Void

    @State private var navigation = MainTabNavigationState()

    var body: some View {
        TabView(selection: $navigation.destination) {
            if let indexingService, let searchEngine {
                SearchView(
                    indexingService: indexingService,
                    searchEngine: searchEngine,
                    semanticRuntime: semanticRuntime,
                    captionService: captionService,
                    surpriseRequestID: navigation.surpriseRequestID
                )
                .tag(MainTabDestination.search)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tag(MainTabDestination.search)
            }

            if let indexingService, let searchEngine {
                MoreView(
                    indexingService: indexingService,
                    searchEngine: searchEngine,
                    captionService: captionService
                )
                    .tag(MainTabDestination.more)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
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
                            .regular.tint(Celestial.Colors.surfaceContainerLow.opacity(0.34)),
                            in: .rect(cornerRadius: 24)
                        )
                }
            } else {
                dockContents
                    .background(.ultraThinMaterial, in: dockShape)
                    .background(
                        Celestial.Colors.surfaceContainerLow.opacity(0.72),
                        in: dockShape
                    )
                    .overlay(
                        dockShape.stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(
            LinearGradient(
                colors: [Celestial.Colors.background.opacity(0), Celestial.Colors.background.opacity(0.90)],
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
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    private func dockButton(_ tab: MainTabDestination) -> some View {
        let isSelected = navigation.destination == tab
        let hasNewPhotos = tab == .more && (indexingService?.newPhotosAvailable ?? false)

        return Button {
            guard navigation.destination != tab else { return }
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.16)) {
                navigation.destination = tab
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    dockIconLens(isSelected: isSelected)

                    Image(systemName: tab.systemImage)
                        .font(
                            .system(
                                size: PrimaryDockMetrics.iconSize,
                                weight: isSelected ? .semibold : .medium
                            )
                        )
                        .symbolRenderingMode(.monochrome)
                        .offset(y: tab == .more ? 2 : 0)
                        .overlay(alignment: .topTrailing) {
                            if hasNewPhotos {
                                Circle()
                                    .fill(Celestial.Colors.emerald)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .frame(
                    width: PrimaryDockMetrics.iconFrame,
                    height: PrimaryDockMetrics.iconFrame
                )

                Text(tab.title)
                    .font(
                        isSelected
                            ? Celestial.Typography.microStrong
                            : Celestial.Typography.microEmphasized
                    )
            }
            .foregroundStyle(
                isSelected
                    ? Celestial.Colors.primary
                    : Celestial.Colors.onSurfaceVariant
            )
            .frame(width: PrimaryDockMetrics.itemWidth)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(hasNewPhotos ? "New photos are available" : "")
    }

    @ViewBuilder
    private func dockIconLens(isSelected: Bool) -> some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(.clear)
                .frame(width: 32, height: 32)
                .glassEffect(
                    .regular.tint(
                        isSelected
                            ? Celestial.Colors.primaryDim.opacity(0.22)
                            : Celestial.Colors.surfaceContainerHigh.opacity(0.10)
                    ),
                    in: .circle
                )
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .background(
                    isSelected
                        ? Celestial.Colors.primaryDim.opacity(0.18)
                        : Celestial.Colors.surfaceContainerHigh.opacity(0.10),
                    in: Circle()
                )
                .overlay(
                    Circle()
                        .stroke(
                            isSelected
                                ? Celestial.Colors.primary.opacity(0.34)
                                : Color.white.opacity(0.08),
                            lineWidth: 0.75
                        )
                )
                .frame(width: 32, height: 32)
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
            SurpriseDockIcon()
                .frame(
                    width: PrimaryDockMetrics.iconFrame,
                    height: PrimaryDockMetrics.iconFrame
                )
                .modifier(
                    GlassCircleModifier(
                        tint: Celestial.Colors.amber.opacity(0.16)
                    )
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
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

private struct SurpriseDockIcon: View {
    var body: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: PrimaryDockMetrics.iconSize, weight: .semibold))
    }
}

private struct SemanticWarmupView: View {
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let retry: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                CelestialBackdrop()
                VStack(spacing: 16) {
                    if case .failed = semanticRuntime.phase {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32, weight: .thin))
                            .foregroundStyle(Celestial.Colors.error)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .tint(Celestial.Colors.primaryDim)
                    }
                    Text(statusText)
                        .font(Celestial.Typography.supporting)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    if case .failed = semanticRuntime.phase {
                        Button("Try Again", action: retry)
                            .celestialPrimaryButtonStyle()
                    }
                }
                .padding(.horizontal, 24)
            }
            .celestialNavigationTitle("Memorable")
        }
    }

    private var statusText: String {
        switch semanticRuntime.phase {
        case .idle:
            return "Preparing search..."
        case .warmingCore(let promoted):
            return promoted ? "Prioritizing search..." : "Warming search..."
        case .waitingForIndex:
            return "Loading your library…"
        case .ready:
            return "Search is ready"
        case .failed(let message):
            return message
        }
    }
}
