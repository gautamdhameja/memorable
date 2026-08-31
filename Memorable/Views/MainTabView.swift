import SwiftUI

struct MainTabView: View {
    private enum Tab: Int, CaseIterable {
        case search
        case memories
        case more

        var title: String {
            switch self {
            case .search: return "Search"
            case .memories: return "Memories"
            case .more: return "More"
            }
        }

        var systemImage: String {
            switch self {
            case .search: return "magnifyingglass"
            case .memories: return "photo.stack"
            case .more: return "square.grid.2x2"
            }
        }
    }

    var indexingService: IndexingService?
    var searchEngine: SearchEngine?
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let captionService: PhotoCaptionService
    let retrySemanticWarmup: () -> Void

    @State private var selectedTab: Tab = .search
    @Namespace private var dockGlassNamespace

    var body: some View {
        TabView(selection: $selectedTab) {
            if let indexingService, let searchEngine {
                SearchView(
                    indexingService: indexingService,
                    searchEngine: searchEngine,
                    semanticRuntime: semanticRuntime,
                    captionService: captionService
                )
                .tag(Tab.search)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tag(Tab.search)
            }

            if indexingService != nil, searchEngine != nil {
                OnThisDayView(captionService: captionService)
                    .tag(Tab.memories)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tag(Tab.memories)
            }

            if let indexingService, let searchEngine {
                MoreView(indexingService: indexingService, searchEngine: searchEngine)
                    .tag(Tab.more)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tag(Tab.more)
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
                GlassEffectContainer(spacing: 12) {
                    dockContents
                        .glassEffect(
                            .regular.tint(Celestial.Colors.surfaceContainerLow.opacity(0.34)),
                            in: .rect(cornerRadius: 20)
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
        .padding(.top, 4)
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
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                dockButton(tab)
            }
        }
        .frame(height: 50)
        .padding(.horizontal, 6)
    }

    private var dockShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private func dockButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        let hasNewPhotos = tab == .more && (indexingService?.newPhotosAvailable ?? false)

        return Button {
            guard selectedTab != tab else { return }
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.16)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    if isSelected {
                        selectedIconLens
                    }

                    Image(systemName: tab.systemImage)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .medium))
                        .symbolRenderingMode(.monochrome)
                        .overlay(alignment: .topTrailing) {
                            if hasNewPhotos {
                                Circle()
                                    .fill(Celestial.Colors.emerald)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .frame(width: 32, height: 32)

                Text(tab.title)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
            }
            .foregroundStyle(
                isSelected
                    ? Celestial.Colors.primary
                    : Celestial.Colors.onSurfaceVariant
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(hasNewPhotos ? "New photos are available" : "")
    }

    @ViewBuilder
    private var selectedIconLens: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(.clear)
                .frame(width: 32, height: 32)
                .glassEffect(
                    .regular.tint(Celestial.Colors.primaryDim.opacity(0.22)).interactive(),
                    in: .circle
                )
                .glassEffectID("selected-tab", in: dockGlassNamespace)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .background(Celestial.Colors.primaryDim.opacity(0.18), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Celestial.Colors.primary.opacity(0.34), lineWidth: 0.75)
                )
                .frame(width: 32, height: 32)
                .matchedGeometryEffect(id: "selected-tab", in: dockGlassNamespace)
        }
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
                        .font(.subheadline)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    if case .failed = semanticRuntime.phase {
                        Button("Try Again", action: retry)
                            .buttonStyle(CelestialButtonStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Memorable")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusText: String {
        switch semanticRuntime.phase {
        case .idle:
            return "Preparing search..."
        case .warmingCore(let promoted):
            return promoted ? "Prioritizing search..." : "Warming search..."
        case .waitingForIndex:
            return "Ready to index your photos"
        case .ready:
            return "Search is ready"
        case .failed(let message):
            return message
        }
    }
}
